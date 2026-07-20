import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import '../models/access_record.dart';
import '../models/pre_auth_record.dart';
import '../models/blacklist_entry.dart';
import 'notification_helper.dart';

class SupabaseSyncManager {
  static final client = Supabase.instance.client;

  static String? activeInstallationName;

  static final ValueNotifier<bool> isOnline = ValueNotifier<bool>(true);
  static final ValueNotifier<bool> isSyncing = ValueNotifier<bool>(false);
  static final ValueNotifier<DateTime?> lastSyncTime = ValueNotifier<DateTime?>(null);

  static late Box _recordsBox;
  static late Box _preAuthBox;
  static late Box _blacklistBox;

  static late Box _pendingRecordsBox;
  static late Box _pendingPreAuthBox;
  static late Box _pendingBlacklistBox;
  static bool _isInitialized = false;
  static bool _isSyncingDown = false;
  static Timer? _syncTimer;

  static bool get isSyncingDown => _isSyncingDown;

  static Future<void> initialize() async {
    if (_isInitialized) return;

    _recordsBox = Hive.box('records_box');
    _preAuthBox = Hive.box('pre_auth_box');
    _blacklistBox = Hive.box('blacklist_box');

    _pendingRecordsBox = await Hive.openBox('pending_records_box');
    _pendingPreAuthBox = await Hive.openBox('pending_pre_auth_box');
    _pendingBlacklistBox = await Hive.openBox('pending_blacklist_box');

    // Load last sync time from sync_metadata_box
    final metaBox = Hive.box('sync_metadata_box');
    final lastSyncString = metaBox.get('last_sync_time') as String?;
    if (lastSyncString != null) {
      lastSyncTime.value = DateTime.parse(lastSyncString);
    }

    _isInitialized = true;

    // Listen to local Box changes to automatically queue them for syncing
    _recordsBox.watch().listen((event) {
      if (_isSyncingDown) return;
      queueAccessRecord(event.key as String);
    });

    _preAuthBox.watch().listen((event) {
      if (_isSyncingDown) return;
      queuePreAuth(event.key as String);
    });

    _blacklistBox.watch().listen((event) {
      if (_isSyncingDown) return;
      queueBlacklist(event.key as String);
    });

    // Subscribe to Supabase Realtime changes
    try {
      client.channel('realtime_access_records')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'access_records',
          callback: (payload) {
            _handleIncomingRealtimeRecord(payload);
            syncAll();
          },
        )
        .subscribe();
    } catch (e, stackTrace) {
      debugPrint('Realtime Subscription Error: $e');
      await Sentry.captureException(e, stackTrace: stackTrace);
    }

    // Start periodic sync every 30 seconds
    _syncTimer = Timer.periodic(const Duration(seconds: 30), (timer) {
      syncAll();
    });

    // Run initial sync
    syncAll();
  }

  static void _handleIncomingRealtimeRecord(dynamic payload) {
    try {
      final recordData = payload.newRecord;
      if (recordData == null || recordData.isEmpty) return;

      final String id = recordData['id']?.toString() ?? '';
      if (id.isEmpty) return;

      // Only notify on new insert events
      if (payload.eventType != PostgresChangeEvent.insert) return;

      // If we already have this record locally, we probably created it or already received it
      if (_recordsBox.containsKey(id)) return;

      final String destination = recordData['destination']?.toString() ?? '';
      final String name = recordData['name']?.toString() ?? 'Persona';

      // Check if it belongs to our active installation name
      if (activeInstallationName != null) {
        final prefix = '$activeInstallationName | ';
        if (!destination.startsWith(prefix)) return;
      }

      // Check if it's a blacklist denial or pre-auth visit
      final isBlacklistAlert = destination.contains('[ACCESO DENEGADO - LISTA NEGRA]') || 
                              destination.contains('[Excepción Lista Negra]') || 
                              destination.contains('[RESTRICCIÓN]');
      
      final isPreauthVisit = destination.contains('[Visita]') || 
                             destination.contains('(Visita Programada)');

      if (isBlacklistAlert) {
        NotificationHelper.showNotification(
          '⚠️ ALERTA DE SEGURIDAD',
          'Intento de acceso denegado para: $name',
          isAlert: true,
        );
      } else if (isPreauthVisit) {
        NotificationHelper.showNotification(
          '📢 Ingreso de Visita',
          '$name ha ingresado a la instalación.',
          isAlert: false,
        );
      }
    } catch (e, stackTrace) {
      debugPrint('Error in _handleIncomingRealtimeRecord: $e');
      Sentry.captureException(e, stackTrace: stackTrace);
    }
  }

  static void dispose() {
    _syncTimer?.cancel();
  }

  // Check if we can connect to the internet
  static Future<bool> checkConnection() async {
    try {
      final result = await InternetAddress.lookup('google.com');
      final connected = result.isNotEmpty && result[0].rawAddress.isNotEmpty;
      isOnline.value = connected;
      return connected;
    } catch (_) {
      isOnline.value = false;
      return false;
    }
  }

  // Queue a record to be synced
  static void queueAccessRecord(String id) {
    _pendingRecordsBox.put(id, true);
    // Try syncing immediately in the background
    syncAll();
  }

  static void queuePreAuth(String id) {
    _pendingPreAuthBox.put(id, true);
    syncAll();
  }

  static void queueBlacklist(String id) {
    _pendingBlacklistBox.put(id, true);
    syncAll();
  }

  // Perform full two-way sync
  static Future<void> syncAll() async {
    if (isSyncing.value) return;
    isSyncing.value = true;

    final online = await checkConnection();
    if (!online) {
      isSyncing.value = false;
      return;
    }

    try {
      // 1. Sync Blacklist Entries
      await _syncBlacklist();

      // 2. Sync Pre-Authorizations
      await _syncPreAuths();

      // 3. Sync Access Records
      await _syncAccessRecords();

      // Update metadata
      isOnline.value = true;
      lastSyncTime.value = DateTime.now();
      final metaBox = Hive.box('sync_metadata_box');
      await metaBox.put('last_sync_time', lastSyncTime.value!.toIso8601String());
    } catch (e, stackTrace) {
      debugPrint('Sync Error: $e');
      if (e is SocketException || e.toString().contains('ClientException')) {
        isOnline.value = false;
      } else {
        await Sentry.captureException(e, stackTrace: stackTrace);
      }
    } finally {
      isSyncing.value = false;
    }
  }

  // --- PRIVATE SYNC IMPLEMENTATIONS ---

  static Future<void> _syncBlacklist() async {
    // A. Upload local pending additions/deletions to Supabase
    final pendingKeys = List<String>.from(_pendingBlacklistBox.keys.cast<String>());
    for (final id in pendingKeys) {
      final localData = _blacklistBox.get(id);
      if (localData != null) {
        final entry = BlacklistEntry.fromMap(localData);
        await client.from('blacklist_entries').upsert(_toSupabaseBlacklist(entry));
      } else {
        await client.from('blacklist_entries').delete().eq('id', id);
      }
      await _pendingBlacklistBox.delete(id);
    }

    // B. Download all blacklist entries from Supabase to local DB
    final response = await client.from('blacklist_entries').select();
    final List<dynamic> remoteList = response as List<dynamic>;

    _isSyncingDown = true;
    try {
      await _blacklistBox.clear();
      for (final row in remoteList) {
        final entry = _fromSupabaseBlacklist(row);
        await _blacklistBox.put(entry.id, entry.toMap());
      }
    } finally {
      _isSyncingDown = false;
    }
  }

  static Future<void> _syncPreAuths() async {
    // A. Upload local pending updates (like isUsed status changes)
    final pendingKeys = List<String>.from(_pendingPreAuthBox.keys.cast<String>());
    for (final id in pendingKeys) {
      final localData = _preAuthBox.get(id);
      if (localData != null) {
        final entry = PreAuthRecord.fromMap(localData);
        await client.from('pre_auth_records').upsert(_toSupabasePreAuth(entry));
      } else {
        await client.from('pre_auth_records').delete().eq('id', id);
      }
      await _pendingPreAuthBox.delete(id);
    }

    // B. Download all pre-auths from Supabase to local DB
    final response = await client.from('pre_auth_records').select();
    final List<dynamic> remoteList = response as List<dynamic>;

    _isSyncingDown = true;
    try {
      await _preAuthBox.clear();
      for (final row in remoteList) {
        final entry = _fromSupabasePreAuth(row);
        await _preAuthBox.put(entry.id, entry.toMap());
      }
    } finally {
      _isSyncingDown = false;
    }
  }

  static Future<void> _syncAccessRecords() async {
    // A. Upload local pending additions/updates to Supabase
    final pendingKeys = List<String>.from(_pendingRecordsBox.keys.cast<String>());
    for (final id in pendingKeys) {
      final localData = _recordsBox.get(id);
      if (localData != null) {
        final record = AccessRecord.fromMap(localData);
        
        // Handle background photo upload if path is local
        if (record.photoPath != null && !record.photoPath!.startsWith('http')) {
          try {
            final file = File(record.photoPath!);
            if (await file.exists()) {
              final fileBytes = await file.readAsBytes();
              final fileName = '${record.id}.jpg';
              
              await client.storage.from('visitor_photos').uploadBinary(
                fileName,
                fileBytes,
                fileOptions: const FileOptions(contentType: 'image/jpeg', upsert: true),
              );
              
              final publicUrl = client.storage.from('visitor_photos').getPublicUrl(fileName);
              record.photoPath = publicUrl;
              
              // Prevent triggering box listener loop by saving silently or checking in listener
              // Since recordsBox listener does not queue if _isSyncingDown is true, but we are inside syncAll() which sets isSyncing, but wait!
              // The listener check is: if (_isSyncingDown) return;
              // To be safe, we temporarily set _isSyncingDown to true while writing the public URL update.
              _isSyncingDown = true;
              try {
                await _recordsBox.put(record.id, record.toMap());
              } finally {
                _isSyncingDown = false;
              }
            }
          } catch (storageError, stackTrace) {
            debugPrint('Storage Upload Warning: $storageError');
            await Sentry.captureException(storageError, stackTrace: stackTrace);
          }
        }

        await client.from('access_records').upsert(_toSupabaseAccessRecord(record));
      }
      await _pendingRecordsBox.delete(id);
    }

    // B. Download any new/updated access records from Supabase
    final response = await client.from('access_records').select();
    final List<dynamic> remoteList = response as List<dynamic>;

    _isSyncingDown = true;
    try {
      for (final row in remoteList) {
        final record = _fromSupabaseAccessRecord(row);
        if (!_pendingRecordsBox.containsKey(record.id)) {
          await _recordsBox.put(record.id, record.toMap());
        }
      }
    } finally {
      _isSyncingDown = false;
    }
  }

  // --- MAPPERS (CamelCase Local <-> SnakeCase Supabase) ---

  static Map<String, dynamic> _toSupabaseAccessRecord(AccessRecord r) {
    String destWithComment = r.destination;
    if (r.comment != null && r.comment!.trim().isNotEmpty) {
      destWithComment = "${r.destination} | Comentario: ${r.comment!.trim()}";
    }
    return {
      'id': r.id,
      'type': r.type,
      'name': r.name,
      'doc_id': r.docId,
      'plate': r.plate,
      'vehicle_type': r.vehicleType,
      'destination': destWithComment,
      'entry_time': r.entryTime.toIso8601String(),
      'exit_time': r.exitTime?.toIso8601String(),
      'is_inside': r.isInside,
      'photo_path': r.photoPath,
    };
  }

  static AccessRecord _fromSupabaseAccessRecord(Map<String, dynamic> map) {
    final rawDest = map['destination'] as String? ?? '';
    String cleanDest = rawDest;
    String? comment;

    final commentIndex = rawDest.indexOf(' | Comentario: ');
    if (commentIndex != -1) {
      cleanDest = rawDest.substring(0, commentIndex);
      comment = rawDest.substring(commentIndex + ' | Comentario: '.length);
    }

    return AccessRecord(
      id: map['id'] as String,
      type: map['type'] as String,
      name: map['name'] as String,
      docId: map['doc_id'] as String,
      plate: map['plate'] as String?,
      vehicleType: map['vehicle_type'] as String?,
      destination: cleanDest,
      entryTime: DateTime.parse(map['entry_time'] as String).toLocal(),
      exitTime: map['exit_time'] != null ? DateTime.parse(map['exit_time'] as String).toLocal() : null,
      isInside: map['is_inside'] as bool,
      photoPath: map['photo_path'] as String?,
      comment: comment,
    );
  }

  static Map<String, dynamic> _toSupabasePreAuth(PreAuthRecord r) {
    return {
      'id': r.id,
      'type': r.type,
      'name': r.name,
      'doc_id': r.docId,
      'plate': r.plate,
      'vehicle_type': r.vehicleType,
      'destination': r.destination,
      'visit_date': r.visitDate.toIso8601String().split('T')[0],
      'is_used': r.isUsed,
    };
  }

  static PreAuthRecord _fromSupabasePreAuth(Map<String, dynamic> map) {
    final parsedDate = DateTime.parse(map['visit_date'] as String);
    return PreAuthRecord(
      id: map['id'] as String,
      type: map['type'] as String,
      name: map['name'] as String,
      docId: map['doc_id'] as String,
      plate: map['plate'] as String?,
      vehicleType: map['vehicle_type'] as String?,
      destination: map['destination'] as String,
      visitDate: DateTime(parsedDate.year, parsedDate.month, parsedDate.day),
      isUsed: map['is_used'] as bool,
    );
  }

  static Map<String, dynamic> _toSupabaseBlacklist(BlacklistEntry r) {
    return {
      'id': r.id,
      'type': r.type,
      'name': r.name,
      'value': r.identifier,
      'reason': r.reason,
      'created_at': r.createdAt.toIso8601String(),
    };
  }

  static BlacklistEntry _fromSupabaseBlacklist(Map<String, dynamic> map) {
    return BlacklistEntry(
      id: map['id'] as String,
      type: map['type'] as String,
      name: map['name'] as String? ?? '',
      identifier: map['value'] as String,
      reason: map['reason'] as String,
      createdAt: DateTime.parse(map['created_at'] as String),
    );
  }

}
