import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/access_record.dart';
import '../models/pre_auth_record.dart';
import '../models/blacklist_entry.dart';

class SupabaseSyncManager {
  static final client = Supabase.instance.client;

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

    // Pre-populate mock entries if boxes are empty
    if (_recordsBox.isEmpty && _preAuthBox.isEmpty && _blacklistBox.isEmpty) {
      await _prepopulateMockData();
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

    // Start periodic sync every 30 seconds
    _syncTimer = Timer.periodic(const Duration(seconds: 30), (timer) {
      syncAll();
    });

    // Run initial sync
    syncAll();
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
    } catch (e) {
      debugPrint('Sync Error: $e');
      if (e is SocketException || e.toString().contains('ClientException')) {
        isOnline.value = false;
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
          } catch (storageError) {
            debugPrint('Storage Upload Warning: $storageError');
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
    return {
      'id': r.id,
      'type': r.type,
      'name': r.name,
      'doc_id': r.docId,
      'plate': r.plate,
      'vehicle_type': r.vehicleType,
      'destination': r.destination,
      'entry_time': r.entryTime.toIso8601String(),
      'exit_time': r.exitTime?.toIso8601String(),
      'is_inside': r.isInside,
      'photo_path': r.photoPath,
    };
  }

  static AccessRecord _fromSupabaseAccessRecord(Map<String, dynamic> map) {
    return AccessRecord(
      id: map['id'] as String,
      type: map['type'] as String,
      name: map['name'] as String,
      docId: map['doc_id'] as String,
      plate: map['plate'] as String?,
      vehicleType: map['vehicle_type'] as String?,
      destination: map['destination'] as String,
      entryTime: DateTime.parse(map['entry_time'] as String),
      exitTime: map['exit_time'] != null ? DateTime.parse(map['exit_time'] as String) : null,
      isInside: map['is_inside'] as bool,
      photoPath: map['photo_path'] as String?,
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
    return PreAuthRecord(
      id: map['id'] as String,
      type: map['type'] as String,
      name: map['name'] as String,
      docId: map['doc_id'] as String,
      plate: map['plate'] as String?,
      vehicleType: map['vehicle_type'] as String?,
      destination: map['destination'] as String,
      visitDate: DateTime.parse(map['visit_date'] as String),
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

  static Future<void> _prepopulateMockData() async {
    // 1. Mock Pre-Auth Records
    final pre1 = PreAuthRecord(
      id: 'pre-1',
      type: 'persona',
      name: 'Juan Pérez',
      docId: '12.345.678-9',
      destination: 'Oficina 402',
      visitDate: DateTime.now(),
      isUsed: false,
    );
    final pre2 = PreAuthRecord(
      id: 'pre-2',
      type: 'vehiculo',
      name: 'María Gómez',
      docId: '9.876.543-2',
      plate: 'ABCD12',
      vehicleType: 'Toyota Yaris, Gris',
      destination: 'Depto 105',
      visitDate: DateTime.now(),
      isUsed: false,
    );
    await _preAuthBox.put(pre1.id, pre1.toMap());
    await _preAuthBox.put(pre2.id, pre2.toMap());

    // 2. Mock Blacklist Entries
    final bl1 = BlacklistEntry(
      id: 'bl-1',
      type: 'persona',
      name: 'Pedro Rojas',
      identifier: '11.111.111-1',
      reason: 'Antecedentes de altercado con personal de portería.',
      createdAt: DateTime.now().subtract(const Duration(days: 30)),
    );
    await _blacklistBox.put(bl1.id, bl1.toMap());

    // 3. Mock Access Records (History)
    final rec1 = AccessRecord(
      id: 'rec-1',
      type: 'persona',
      name: 'Carlos Muñoz',
      docId: '15.555.555-5',
      destination: 'Bodega Central',
      entryTime: DateTime.now().subtract(const Duration(days: 2, hours: 3)),
      exitTime: DateTime.now().subtract(const Duration(days: 2, hours: 1)),
      isInside: false,
    );
    await _recordsBox.put(rec1.id, rec1.toMap());
  }
}
