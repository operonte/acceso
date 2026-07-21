import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path_provider/path_provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:csv/csv.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/access_record.dart';
import '../models/pre_auth_record.dart';
import '../models/blacklist_entry.dart';
import '../models/whitelist_entry.dart';
import '../models/app_notification.dart';
import '../providers/dashboard_provider.dart';
import 'camera_scanner_screen.dart';
import '../theme/colors.dart';
import '../utils/validators.dart';
import '../utils/file_saver.dart' as file_saver;
import '../utils/supabase_sync_manager.dart';
import '../utils/notification_helper.dart';
import 'package:url_launcher/url_launcher.dart';

import 'login_screen.dart' show UserRole;

class DashboardScreen extends ConsumerStatefulWidget {
  final UserRole userRole;
  final String? installationName;

  const DashboardScreen({
    super.key,
    this.userRole = UserRole.guardia,
    this.installationName,
  });

  @override
  ConsumerState<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends ConsumerState<DashboardScreen> {
  // Navigation State (0: Monitoreo, 1: Pre-autorizaciones)
  int _currentTabIndex = 0;

  // Live clock state
  late Timer _timer;
  DateTime _currentTime = DateTime.now();

  // Hive Box references
  final Box _recordsBox = Hive.box('records_box');
  final Box _preAuthBox = Hive.box('pre_auth_box');
  final Box _blacklistBox = Hive.box('blacklist_box');
  final Box _whitelistBox = Hive.box('whitelist_box');
  final Box _installationsBox = Hive.box('installations_box');
  final Box _destinationsBox = Hive.box('destinations_box');

  List<AccessRecord> get _records => ref.read(dashboardProvider).allRecords;
  List<PreAuthRecord> get _preAuths => ref.read(dashboardProvider).allPreAuths;
  List<BlacklistEntry> get _blacklist => ref.read(dashboardProvider).allBlacklist;
  List<WhitelistEntry> get _whitelist => ref.read(dashboardProvider).allWhitelist;
  List<AppNotification> get _notifications => ref.read(dashboardProvider).notifications;
  AppNotification? get _activeBannerNotification => ref.read(dashboardProvider).activeBannerNotification;

  // --- Monitoreo View Parameters ---
  String _selectedView = 'dentro'; // 'dentro' or 'salieron'
  String _sortOption = 'hora_desc'; // 'hora_desc' or 'az'
  String? _selectedAdminInstallation;
  String _filterType = 'todos'; // 'todos', 'personas', 'vehiculos'
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();
  DateTimeRange? _selectedDateRange;

  // Multi-selection mode for exit batching (WhatsApp style)
  bool _isSelectionMode = false;
  final Set<String> _selectedRecordIds = {};

  Future<void> _performBatchExit() async {
    if (_selectedRecordIds.isEmpty) return;

    final count = _selectedRecordIds.length;
    final now = DateTime.now();

    for (final id in _selectedRecordIds) {
      final matchIndex = _records.indexWhere((r) => r.id == id);
      if (matchIndex != -1) {
        final record = _records[matchIndex];
        record.isInside = false;
        record.exitTime = now;
        await _recordsBox.put(record.id, record.toMap());
      }
    }

    setState(() {
      _isSelectionMode = false;
      _selectedRecordIds.clear();
    });

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('✅ Salida masiva registrada exitosamente para $count elementos.'),
          backgroundColor: const Color(0xFF10B981),
        ),
      );
    }
  }

  // --- PreAuth View Parameters ---
  String _preAuthSearchQuery = '';
  final TextEditingController _preAuthSearchController = TextEditingController();

  // --- Blacklist View Parameters ---
  String _blacklistSearchQuery = '';
  final TextEditingController _blacklistSearchController = TextEditingController();

  // --- Whitelist View Parameters ---
  String _whitelistSearchQuery = '';
  final TextEditingController _whitelistSearchController = TextEditingController();

  void _addNotification({required String type, required String title, required String body}) {
    ref.read(dashboardProvider.notifier).addNotification(
      type: type,
      title: title,
      body: body,
    );
  }

  @override
  void initState() {
    super.initState();
    
    // Register active installation name for synchronization notifications
    SupabaseSyncManager.activeInstallationName = widget.installationName;

    // Clock timer
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (mounted) {
        setState(() {
          _currentTime = DateTime.now();
        });
      }
    });
  }

  @override
  void dispose() {
    _timer.cancel();
    _searchController.dispose();
    _preAuthSearchController.dispose();
    _blacklistSearchController.dispose();
    super.dispose();
  }

  void _refreshUILists() {}

  // Helper to format date/time
  String _formatTime(DateTime dateTime) {
    final hour = dateTime.hour.toString().padLeft(2, '0');
    final minute = dateTime.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  String _formatDuration(DateTime start) {
    final diff = DateTime.now().difference(start);
    if (diff.inMinutes < 60) {
      return 'Hace ${diff.inMinutes}m';
    } else {
      final hours = diff.inHours;
      final mins = diff.inMinutes % 60;
      return 'Hace ${hours}h ${mins}m';
    }
  }

  // --- Filtering calculations ---
  String? get _activeInstallation => _selectedAdminInstallation ?? widget.installationName;

  int get _peopleInsideCount {
    final inst = _activeInstallation;
    if (inst != null) {
      return _records.where((r) => r.type == 'persona' && r.isInside && r.destination.startsWith('$inst | ')).length;
    }
    return _records.where((r) => r.type == 'persona' && r.isInside).length;
  }
  
  int get _vehiclesInsideCount {
    final inst = _activeInstallation;
    if (inst != null) {
      return _records.where((r) => r.type == 'vehiculo' && r.isInside && r.destination.startsWith('$inst | ')).length;
    }
    return _records.where((r) => r.type == 'vehiculo' && r.isInside).length;
  }

  int get _trucksInsideCount {
    final inst = _activeInstallation;
    if (inst != null) {
      return _records.where((r) => r.type == 'vehiculo' && r.isInside && r.destination.startsWith('$inst | ') && (r.vehicleType?.toLowerCase().contains('camión') == true || r.vehicleType?.toLowerCase().contains('camion') == true)).length;
    }
    return _records.where((r) => r.type == 'vehiculo' && r.isInside && (r.vehicleType?.toLowerCase().contains('camión') == true || r.vehicleType?.toLowerCase().contains('camion') == true)).length;
  }

  int get _motosInsideCount {
    final inst = _activeInstallation;
    if (inst != null) {
      return _records.where((r) => r.type == 'vehiculo' && r.isInside && r.destination.startsWith('$inst | ') && r.vehicleType?.toLowerCase().contains('moto') == true).length;
    }
    return _records.where((r) => r.type == 'vehiculo' && r.isInside && r.vehicleType?.toLowerCase().contains('moto') == true).length;
  }

  int get _bikesInsideCount {
    final inst = _activeInstallation;
    if (inst != null) {
      return _records.where((r) => r.type == 'vehiculo' && r.isInside && r.destination.startsWith('$inst | ') && r.vehicleType?.toLowerCase().contains('bicicleta') == true).length;
    }
    return _records.where((r) => r.type == 'vehiculo' && r.isInside && r.vehicleType?.toLowerCase().contains('bicicleta') == true).length;
  }

  List<AccessRecord> get _filteredRecords {
    final targetInstallation = _selectedAdminInstallation ?? widget.installationName;
    return _records.where((record) {
      if (targetInstallation != null) {
        if (!record.destination.startsWith('$targetInstallation | ')) {
          return false;
        }
      }

      if (_selectedView == 'dentro' && !record.isInside) return false;
      if (_selectedView == 'salieron' && record.isInside) return false;

      // 2. Type Filter
      if (_filterType == 'a_pie') {
        if (record.type != 'persona') return false;
      } else if (_filterType == 'vehiculos') {
        if (record.type != 'vehiculo') return false;
        final vType = record.vehicleType?.toLowerCase() ?? '';
        if (vType.contains('moto') || vType.contains('camión') || vType.contains('camion') || vType.contains('bicicleta')) {
          return false;
        }
      } else if (_filterType == 'moto') {
        if (record.type != 'vehiculo') return false;
        final vType = record.vehicleType?.toLowerCase() ?? '';
        if (!vType.contains('moto')) return false;
      } else if (_filterType == 'camion') {
        if (record.type != 'vehiculo') return false;
        final vType = record.vehicleType?.toLowerCase() ?? '';
        if (!vType.contains('camión') && !vType.contains('camion')) return false;
      } else if (_filterType == 'bicicleta') {
        if (record.type != 'vehiculo') return false;
        final vType = record.vehicleType?.toLowerCase() ?? '';
        if (!vType.contains('bicicleta')) return false;
      } else if (_filterType != 'todos' && _filterType != 'personas' && _filterType != 'vehiculos') {
        // Fallback for any other type filter
        if (record.type != _filterType) return false;
      } else if (_filterType == 'personas' && record.type != 'persona') {
        return false;
      }

      if (_selectedDateRange != null) {
        final start = DateTime(_selectedDateRange!.start.year, _selectedDateRange!.start.month, _selectedDateRange!.start.day);
        final end = DateTime(_selectedDateRange!.end.year, _selectedDateRange!.end.month, _selectedDateRange!.end.day, 23, 59, 59, 999);
        final recordLocalTime = record.entryTime.toLocal();
        if (recordLocalTime.isBefore(start) || recordLocalTime.isAfter(end)) {
          return false;
        }
      }

      if (_searchQuery.isNotEmpty) {
        final query = _searchQuery.toLowerCase();
        final nameMatch = record.name.toLowerCase().contains(query);
        final docMatch = record.docId.toLowerCase().contains(query);
        final destMatch = record.destination.toLowerCase().contains(query);
        final plateMatch = record.plate?.toLowerCase().contains(query) ?? false;
        return nameMatch || docMatch || destMatch || plateMatch;
      }
      return true;
    }).toList()
      ..sort((a, b) {
        if (_sortOption == 'az') {
          return a.name.toLowerCase().compareTo(b.name.toLowerCase());
        }
        return b.entryTime.compareTo(a.entryTime);
      });
  }

  List<PreAuthRecord> get _filteredPreAuths {
    return _preAuths.where((pre) {
      if (pre.isUsed) return false; // Show only unused reservations
      
      if (widget.installationName != null) {
        if (!pre.destination.startsWith('${widget.installationName} | ')) {
          return false;
        }
      }
      
      if (_preAuthSearchQuery.isNotEmpty) {
        final query = _preAuthSearchQuery.toLowerCase();
        final nameMatch = pre.name.toLowerCase().contains(query);
        final docMatch = pre.docId.toLowerCase().contains(query);
        final destMatch = pre.destination.toLowerCase().contains(query);
        final plateMatch = pre.plate?.toLowerCase().contains(query) ?? false;
        return nameMatch || docMatch || destMatch || plateMatch;
      }
      return true;
    }).toList()
      ..sort((a, b) => a.visitDate.compareTo(b.visitDate));
  }

  String _displayDestination(String dest) {
    if (dest.contains(' | ')) {
      final parts = dest.split(' | ');
      return parts.sublist(1).join(' | ');
    }
    return dest;
  }

  String _displayReason(String reason) {
    if (reason.contains(' | ')) {
      final parts = reason.split(' | ');
      return parts.sublist(1).join(' | ');
    }
    return reason;
  }

  // Dialog to confirm forced check-in when a duplicate is found
  Future<bool> _showDuplicateWarningDialog({
    required String name,
    required String type,
    required String identifier,
    required AccessRecord existingRecord,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: slate800,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Row(
            children: [
              Icon(Icons.warning_amber_rounded, color: Colors.amber, size: 28),
              SizedBox(width: 12),
              Text('Registro Duplicado'),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '¡Alerta! Un(a) $type con la identificación "$identifier" ya figura dentro del recinto.',
                style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
              ),
              const SizedBox(height: 12),
              Text(
                'Registro existente:\n• Nombre: ${existingRecord.name}\n• Ingreso: ${_formatTime(existingRecord.entryTime)} (${_formatDuration(existingRecord.entryTime)})\n• Destino: ${existingRecord.destination}',
                style: const TextStyle(color: slate300, fontSize: 13),
              ),
              const SizedBox(height: 16),
              const Text(
                '¿Desea registrar la SALIDA del registro anterior e ingresar este nuevo registro de forma automática?',
                style: TextStyle(color: Colors.white),
              ),
            ],
          ),
          actions: [
            TextButton(
              child: const Text('Cancelar', style: TextStyle(color: slate400)),
              onPressed: () => Navigator.pop(context, false),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF10B981)),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Marcar Salida y Entrar', style: TextStyle(color: Colors.white)),
            ),
          ],
        );
      },
    );
    return result ?? false;
  }

  // --- Blacklist Check and Helper Actions ---

  BlacklistEntry? _checkBlacklist(String docId, String? plate) {
    final cleanDoc = docId.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '').toUpperCase();
    final cleanPlt = plate?.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '').toUpperCase() ?? '';

    for (var entry in _blacklist) {
      final cleanEntryId = entry.identifier.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '').toUpperCase();
      if (entry.type == 'persona' && cleanEntryId == cleanDoc) {
        return entry;
      }
      if (entry.type == 'vehiculo') {
        if (cleanPlt.isNotEmpty && cleanEntryId == cleanPlt) {
          return entry;
        }
        if (cleanEntryId == cleanDoc) {
          return entry;
        }
      }
    }
    return null;
  }

  WhitelistEntry? _checkWhitelist(String docId, String? plate) {
    final cleanDoc = docId.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '').toUpperCase();
    final cleanPlt = plate?.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '').toUpperCase() ?? '';

    for (var entry in _whitelist) {
      final cleanEntryId = entry.identifier.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '').toUpperCase();
      if (entry.type == 'persona' && cleanDoc.isNotEmpty && cleanEntryId == cleanDoc) {
        return entry;
      }
      if (entry.type == 'vehiculo') {
        if (cleanPlt.isNotEmpty && cleanEntryId == cleanPlt) {
          return entry;
        }
        if (cleanDoc.isNotEmpty && cleanEntryId == cleanDoc) {
          return entry;
        }
      }
    }
    return null;
  }

  Future<bool> _showBlacklistWarningDialog({required BlacklistEntry entry}) async {
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return AlertDialog(
          backgroundColor: slate800,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Row(
            children: [
              Icon(Icons.gpp_bad_rounded, color: Colors.redAccent, size: 30),
              SizedBox(width: 12),
              Text('ACCESO RESTRINGIDO', style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold)),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'ATENCIÓN: Este visitante/vehículo se encuentra en la Lista Negra del recinto.',
                style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white, fontSize: 14),
              ),
              const SizedBox(height: 16),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: slate900,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.redAccent.withValues(alpha: 0.3)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('• Nombre: ${entry.name}', style: const TextStyle(color: Colors.white, fontSize: 13)),
                    const SizedBox(height: 4),
                    Text('• Identificación: ${entry.identifier}', style: const TextStyle(color: Colors.white, fontSize: 13)),
                    const SizedBox(height: 4),
                    Text('• Tipo: ${entry.type == 'persona' ? 'Persona' : 'Vehículo'}', style: const TextStyle(color: Colors.white, fontSize: 13)),
                    const SizedBox(height: 8),
                    const Text('Motivo de Restricción:', style: TextStyle(color: Colors.redAccent, fontSize: 11, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 2),
                    Text(entry.reason, style: const TextStyle(color: slate300, fontSize: 13)),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              const Text(
                'Por políticas de seguridad, el ingreso está denegado. ¿Desea omitir esta restricción y registrar el ingreso de todas formas bajo su responsabilidad?',
                style: TextStyle(color: Colors.white, fontSize: 12),
              ),
            ],
          ),
          actions: [
            TextButton(
              child: const Text('DENEGAR INGRESO', style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold)),
              onPressed: () => Navigator.pop(context, false),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: slate500),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('AUTORIZAR EXCEPCIÓN', style: TextStyle(color: Colors.white)),
            ),
          ],
        );
      },
    );
    return result ?? false;
  }

  void _confirmRemoveBlacklist(BlacklistEntry entry) {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: slate800,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Text('Eliminar Restricción'),
          content: Text('¿Está seguro de remover a "${entry.name}" (${entry.identifier}) de la Lista Negra?'),
          actions: [
            TextButton(
              child: const Text('Cancelar', style: TextStyle(color: slate400)),
              onPressed: () => Navigator.pop(context),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
              onPressed: () {
                _blacklistBox.delete(entry.id);
                _refreshUILists();
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('Restricción eliminada para: ${entry.name}'),
                    backgroundColor: Colors.green,
                  ),
                );
              },
              child: const Text('Eliminar', style: TextStyle(color: Colors.white)),
            ),
          ],
        );
      },
    );
  }

  void _showAddBlacklistModal() {
    final formKey = GlobalKey<FormState>();
    String name = '';
    String identifier = '';
    String type = 'persona';
    String reason = '';
    bool isRut = true;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: slate800,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setModalState) {
            return Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(context).viewInsets.bottom + 24,
                left: 20,
                right: 20,
                top: 24,
              ),
              child: Form(
                key: formKey,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.block_flipped, color: Colors.redAccent, size: 28),
                          const SizedBox(width: 12),
                          Text(
                            'Agregar Restricción',
                            style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
                          ),
                          const Spacer(),
                          IconButton(
                            icon: const Icon(Icons.close, color: slate400),
                            onPressed: () => Navigator.pop(context),
                          )
                        ],
                      ),
                      const Divider(height: 24, color: slate700),

                      // Segment selector for type
                      Row(
                        children: [
                          Expanded(
                            child: ChoiceChip(
                              label: const Text('Persona'),
                              selected: type == 'persona',
                              onSelected: (selected) {
                                if (selected) setModalState(() => type = 'persona');
                              },
                              backgroundColor: slate900,
                              selectedColor: Colors.redAccent,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: ChoiceChip(
                              label: const Text('Vehículo'),
                              selected: type == 'vehiculo',
                              onSelected: (selected) {
                                if (selected) setModalState(() => type = 'vehiculo');
                              },
                              backgroundColor: slate900,
                              selectedColor: Colors.redAccent,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),

                      TextFormField(
                        decoration: InputDecoration(
                          labelText: type == 'persona' ? 'Nombre de la Persona' : 'Identificación del Vehículo (Ej: Camión Pepsi)',
                          prefixIcon: const Icon(Icons.person),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                          filled: true,
                          fillColor: slate900,
                        ),
                        validator: (value) => value == null || value.trim().isEmpty ? 'Ingrese un nombre/descripción' : null,
                        onSaved: (value) => name = value!.trim(),
                      ),
                      const SizedBox(height: 16),

                      if (type == 'persona') ...[
                        // Selector de tipo de documento
                        Row(
                          children: [
                            const Text('Tipo de Doc: ', style: TextStyle(color: slate400, fontSize: 13)),
                            const SizedBox(width: 8),
                            ChoiceChip(
                              label: const Text('RUT', style: TextStyle(fontSize: 12)),
                              selected: isRut,
                              onSelected: (selected) {
                                if (selected) {
                                  setModalState(() => isRut = true);
                                }
                              },
                              backgroundColor: slate900,
                              selectedColor: Colors.redAccent.withValues(alpha: 0.3),
                            ),
                            const SizedBox(width: 8),
                            ChoiceChip(
                              label: const Text('Pasaporte / DNI', style: TextStyle(fontSize: 12)),
                              selected: !isRut,
                              onSelected: (selected) {
                                if (selected) {
                                  setModalState(() => isRut = false);
                                }
                              },
                              backgroundColor: slate900,
                              selectedColor: Colors.redAccent.withValues(alpha: 0.3),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                      ],

                      TextFormField(
                        key: ValueKey('blacklist_doc_field_$type-$isRut'),
                        textCapitalization: type == 'vehiculo' ? TextCapitalization.characters : TextCapitalization.none,
                        decoration: InputDecoration(
                          labelText: type == 'vehiculo'
                              ? 'Patente / Placa'
                              : (isRut ? 'RUT (Ej: 12.345.678-9)' : 'Identificación (DNI o Pasaporte)'),
                          prefixIcon: Icon(type == 'vehiculo' ? Icons.tag : Icons.badge),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                          filled: true,
                          fillColor: slate900,
                        ),
                        inputFormatters: type == 'vehiculo'
                            ? [PlateFormatter()]
                            : (isRut ? [RutFormatter()] : null),
                        validator: (value) {
                          if (value == null || value.trim().isEmpty) {
                            return type == 'vehiculo' ? 'Ingrese patente' : 'Ingrese identificación';
                          }
                          if (type == 'persona' && !isValidDocument(value, isRut)) {
                            return isRut ? 'RUT inválido' : 'Mínimo 5 caracteres';
                          }
                          if (type == 'vehiculo' && !isValidPlate(value)) {
                            return 'Patente inválida';
                          }
                          return null;
                        },
                        onSaved: (value) => identifier = value!.trim().toUpperCase(),
                      ),
                      const SizedBox(height: 16),

                      TextFormField(
                        maxLines: 3,
                        decoration: InputDecoration(
                          labelText: 'Motivo de la Restricción',
                          prefixIcon: const Icon(Icons.warning_amber_rounded),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                          filled: true,
                          fillColor: slate900,
                        ),
                        validator: (value) => value == null || value.trim().isEmpty ? 'Ingrese el motivo' : null,
                        onSaved: (value) => reason = value!.trim(),
                      ),
                      const SizedBox(height: 24),

                      ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.redAccent,
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                        onPressed: () {
                          if (formKey.currentState!.validate()) {
                            formKey.currentState!.save();
                            final newEntry = BlacklistEntry(
                              id: 'bl_${DateTime.now().millisecondsSinceEpoch}',
                              type: type,
                              name: name,
                              identifier: identifier,
                              reason: _activeInstallation != null 
                                  ? '$_activeInstallation | $reason' 
                                  : reason,
                              createdAt: DateTime.now(),
                            );

                            _blacklistBox.put(newEntry.id, newEntry.toMap());
                            _refreshUILists();

                            Navigator.pop(context);

                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text('Restricción agregada para: $name'),
                                backgroundColor: Colors.redAccent,
                                duration: const Duration(seconds: 2),
                              ),
                            );
                          }
                        },
                        child: const Text(
                          'Guardar Restricción',
                          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  // --- Core CRUD Actions ---

  void _checkoutRecord(AccessRecord record) {
    setState(() {
      record.isInside = false;
      record.exitTime = DateTime.now();
    });
    _recordsBox.put(record.id, record.toMap());
    _refreshUILists();
    
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Salida registrada para: ${record.name}'),
        backgroundColor: Colors.blueAccent,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  // Check in a pre-authorized visitor
  void _checkinPreAuth(PreAuthRecord pre) async {
    // Check blacklist first!
    final blacklistMatch = _checkBlacklist(pre.docId, pre.plate);
    if (blacklistMatch != null) {
      // 1. Play local alarm notification immediately
      NotificationHelper.showNotification(
        '⚠️ ALERTA: Intento de Ingreso Bloqueado',
        '${pre.name} (${pre.type == 'persona' ? 'RUT: ${pre.docId}' : 'Patente: ${pre.plate}'}) está en la Lista Negra.',
        isAlert: true,
      );

      // 2. Save a "Denied Entry" record to history and sync it
      final deniedRecord = AccessRecord(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        type: pre.type,
        name: pre.name,
        docId: pre.docId,
        plate: pre.plate,
        vehicleType: pre.vehicleType,
        destination: _activeInstallation != null
            ? '$_activeInstallation | [ACCESO DENEGADO - LISTA NEGRA] ${pre.destination}'
            : '[ACCESO DENEGADO - LISTA NEGRA] ${pre.destination}',
        entryTime: DateTime.now(),
        isInside: false,
        comment: 'Intento de ingreso denegado automáticamente. Razón: ${blacklistMatch.reason}',
      );
      await _recordsBox.put(deniedRecord.id, deniedRecord.toMap());
      _refreshUILists();

      // 3. Show dialog to guard
      if (mounted) {
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            backgroundColor: slate800,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: const Row(
              children: [
                Icon(Icons.gpp_bad_rounded, color: Colors.redAccent),
                SizedBox(width: 8),
                Text('ACCESO DENEGADO', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
              ],
            ),
            content: Text(
              'El visitante "${pre.name}" (${pre.type == 'persona' ? 'RUT: ${pre.docId}' : 'Patente: ${pre.plate}'}) se encuentra en la LISTA NEGRA.\n\nMotivo: ${blacklistMatch.reason}\n\nEl intento de ingreso ha sido rechazado y registrado en el historial.',
              style: const TextStyle(color: slate300),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Entendido', style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold)),
              ),
            ],
          ),
        );
      }
      return;
    }

    // Check Whitelist (Lista Blanca)!
    final whitelistMatch = _checkWhitelist(pre.docId, pre.plate);
    if (whitelistMatch != null) {
      NotificationHelper.showNotification(
        '✅ LISTA BLANCA: Permita el Acceso',
        '${whitelistMatch.name} (${whitelistMatch.unitOrRole}) pertenece a la Lista Blanca. No se requiere registro de bitácora.',
        isAlert: false,
      );

      _addNotification(
        type: 'info',
        title: '✅ Lista Blanca - Acceso Permitido',
        body: '${whitelistMatch.name} (${whitelistMatch.unitOrRole}) ingresó sin registro por ser Lista Blanca.',
      );

      if (mounted) {
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            backgroundColor: slate800,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: const Row(
              children: [
                Icon(Icons.verified_user_rounded, color: Color(0xFF10B981)),
                SizedBox(width: 8),
                Text('LISTA BLANCA', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
              ],
            ),
            content: Text(
              '${whitelistMatch.name} (${whitelistMatch.unitOrRole})\n\nPertenece a la LISTA BLANCA del recinto.\nPermita el acceso directamente.\n\n(No se genera registro en la bitácora de historial)',
              style: const TextStyle(color: slate300),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Permitir Acceso', style: TextStyle(color: Color(0xFF10B981), fontWeight: FontWeight.bold)),
              ),
            ],
          ),
        );
      }
      return;
    }

    // Check duplicates
    AccessRecord? duplicateRecord;
    String identifierLabel = '';
    
    final cleanDoc = pre.docId.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '').toUpperCase();
    final cleanPlt = pre.plate?.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '').toUpperCase() ?? '';
    
    if (pre.type == 'persona') {
      duplicateRecord = _records.cast<AccessRecord?>().firstWhere(
        (r) => r != null && r.isInside && r.type == 'persona' && r.docId.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '').toUpperCase() == cleanDoc,
        orElse: () => null,
      );
      identifierLabel = pre.docId;
    } else {
      duplicateRecord = _records.cast<AccessRecord?>().firstWhere(
        (r) => r != null && r.isInside && r.type == 'vehiculo' && r.plate != null && r.plate!.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '').toUpperCase() == cleanPlt,
        orElse: () => null,
      );
      identifierLabel = 'Patente ${pre.plate}';
      
      if (duplicateRecord == null) {
        duplicateRecord = _records.cast<AccessRecord?>().firstWhere(
          (r) => r != null && r.isInside && r.docId.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '').toUpperCase() == cleanDoc,
          orElse: () => null,
        );
        identifierLabel = pre.docId;
      }
    }
    
    if (duplicateRecord != null) {
      if (!mounted) return;
      final proceed = await _showDuplicateWarningDialog(
        name: duplicateRecord.name,
        type: pre.type == 'persona' ? 'persona' : 'vehículo',
        identifier: identifierLabel,
        existingRecord: duplicateRecord,
      );
      
      if (!proceed) return;
      
      duplicateRecord.isInside = false;
      duplicateRecord.exitTime = DateTime.now();
      await _recordsBox.put(duplicateRecord.id, duplicateRecord.toMap());
    }

    // 1. Mark pre-auth as used
    setState(() {
      pre.isUsed = true;
    });
    await _preAuthBox.put(pre.id, pre.toMap());

    // 2. Create access record entry
    final newAccess = AccessRecord(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      type: pre.type,
      name: pre.name,
      docId: pre.docId,
      plate: pre.plate,
      vehicleType: pre.vehicleType,
      destination: _activeInstallation != null
          ? '$_activeInstallation | ${pre.destination} [Visita]'
          : '${pre.destination} [Visita]',
      entryTime: DateTime.now(),
      isInside: true,
    );
    await _recordsBox.put(newAccess.id, newAccess.toMap());

    // Show system notification
    NotificationHelper.showNotification(
      '📢 Ingreso de Visita',
      '${pre.name} ha ingresado a la instalación (Visita Programada).',
      isAlert: false,
    );

    _refreshUILists();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Ingreso autorizado para: ${pre.name} (Visita Programada)'),
          backgroundColor: const Color(0xFF10B981),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  Future<void> _selectDateRange() async {
    try {
      final DateTimeRange? picked = await showDateRangePicker(
        context: context,
        initialDateRange: _selectedDateRange,
        firstDate: DateTime(2020),
        lastDate: DateTime.now().add(const Duration(days: 365)),
        builder: (context, child) {
          return Theme(
            data: Theme.of(context).copyWith(
              colorScheme: const ColorScheme.dark(
                primary: Color(0xFF10B981),
                onPrimary: Colors.white,
                surface: slate800,
                onSurface: Colors.white,
              ),
              dialogTheme: const DialogThemeData(
                backgroundColor: slate900,
              ),
            ),
            child: child ?? const SizedBox(),
          );
        },
      );
      if (picked != null) {
        setState(() {
          _selectedDateRange = picked;
        });
      }
    } catch (e) {
      debugPrint('Error en date range picker: $e');
    }
  }

  Future<void> _downloadQR(PreAuthRecord pre) async {
    try {
      final String qrPayload = jsonEncode({
        'id': pre.id,
        'name': pre.name,
        'docId': pre.docId,
        'plate': pre.plate,
        'destination': pre.destination,
        'visitDate': pre.visitDate.toIso8601String(),
        'type': pre.type,
      });

      final qrPainter = QrPainter(
        data: qrPayload,
        version: QrVersions.auto,
        errorCorrectionLevel: QrErrorCorrectLevel.M,
        gapless: true,
        dataModuleStyle: const QrDataModuleStyle(
          dataModuleShape: QrDataModuleShape.square,
          color: Colors.black,
        ),
        eyeStyle: const QrEyeStyle(
          eyeShape: QrEyeShape.square,
          color: Colors.black,
        ),
      );

      final byteData = await qrPainter.toImageData(400);
      if (byteData == null) throw Exception('Error al generar la imagen del QR');
      
      final Uint8List pngBytes = byteData.buffer.asUint8List();
      final String fileName = 'pase_qr_${pre.name.replaceAll(RegExp(r'\s+'), '_')}.png';
      
      final resultPath = await file_saver.saveBytesToFile(pngBytes, fileName);
      
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Pase QR guardado exitosamente: $resultPath'),
          backgroundColor: const Color(0xFF10B981),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error al descargar: $e'),
          backgroundColor: Colors.redAccent,
        ),
      );
    }
  }

  void _showQRPassDialog(PreAuthRecord pre) {
    final String qrPayload = jsonEncode({
      'id': pre.id,
      'name': pre.name,
      'docId': pre.docId,
      'plate': pre.plate,
      'destination': pre.destination,
      'visitDate': pre.visitDate.toIso8601String(),
      'type': pre.type,
    });

    final isVehicle = pre.type == 'vehiculo';
    final accentColor = isVehicle ? const Color(0xFF3B82F6) : const Color(0xFF10B981);
    final visitDateStr = '${pre.visitDate.day}/${pre.visitDate.month}/${pre.visitDate.year}';

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: slate900,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          contentPadding: const EdgeInsets.all(24),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      Icon(Icons.qr_code_2_rounded, color: accentColor, size: 28),
                      const SizedBox(width: 8),
                      const Text(
                        'Pase de Acceso QR',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                    ],
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: slate400),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
              const Divider(color: slate700, height: 24),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: accentColor.withValues(alpha: 0.15),
                      blurRadius: 10,
                      spreadRadius: 2,
                    ),
                  ],
                ),
                child: SizedBox(
                  width: 200,
                  height: 200,
                  child: QrImageView(
                    data: qrPayload,
                    version: QrVersions.auto,
                    size: 200.0,
                    errorCorrectionLevel: QrErrorCorrectLevel.M,
                    gapless: true,
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Text(
                pre.name,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 4),
              Text(
                'RUT/DNI: ${pre.docId}',
                style: const TextStyle(fontSize: 14, color: slate300),
              ),
              if (pre.plate != null && pre.plate!.isNotEmpty) ...[
                const SizedBox(height: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: slate800,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: slate700),
                  ),
                  child: Text(
                    'Patente: ${pre.plate} (${pre.vehicleType ?? "Vehículo"})',
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: Colors.orangeAccent,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.meeting_room_rounded, size: 16, color: slate400),
                  const SizedBox(width: 4),
                  Text(
                    pre.destination,
                    style: const TextStyle(fontSize: 13, color: slate300),
                  ),
                  const SizedBox(width: 12),
                  const Icon(Icons.calendar_today_rounded, size: 14, color: slate400),
                  const SizedBox(width: 4),
                  Text(
                    visitDateStr,
                    style: const TextStyle(fontSize: 13, color: slate300),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        side: BorderSide(color: accentColor),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                      icon: Icon(Icons.file_download_outlined, color: accentColor),
                      label: Text(
                        'Descargar',
                        style: TextStyle(fontWeight: FontWeight.bold, color: accentColor),
                      ),
                      onPressed: () {
                        Navigator.pop(context);
                        _downloadQR(pre);
                      },
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: accentColor,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                      child: const Text('Cerrar', style: TextStyle(fontWeight: FontWeight.bold)),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  // --- Exporting to CSV ---

  Future<void> _exportHistoryToCSV() async {
    final exportRecords = _records.where((r) {
      if (_activeInstallation != null) {
        if (!r.destination.startsWith('$_activeInstallation | ')) return false;
      }
      if (_filterType != 'todos') {
        if (_filterType == 'persona' && r.type != 'persona') return false;
        if (_filterType == 'vehiculo' && (r.type != 'vehiculo' || r.vehicleType == 'Camión' || r.vehicleType == 'Moto' || r.vehicleType == 'Bicicleta')) return false;
        if (_filterType == 'camion' && r.vehicleType != 'Camión') return false;
        if (_filterType == 'moto' && r.vehicleType != 'Moto') return false;
        if (_filterType == 'bicicleta' && r.vehicleType != 'Bicicleta') return false;
      }
      if (_searchQuery.isNotEmpty) {
        final query = _searchQuery.toLowerCase();
        return r.name.toLowerCase().contains(query) ||
            r.docId.toLowerCase().contains(query) ||
            (r.plate != null && r.plate!.toLowerCase().contains(query)) ||
            r.destination.toLowerCase().contains(query);
      }
      return true;
    }).toList();

    if (exportRecords.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No hay registros para exportar.'),
          backgroundColor: Colors.redAccent,
        ),
      );
      return;
    }

    // Build CSV Content
    final StringBuffer csvBuffer = StringBuffer();
    csvBuffer.writeln('ID,Tipo,Nombre,RUT_DNI,Patente_Placa,Tipo_Vehiculo,Destino_Motivo,Fecha_Ingreso,Fecha_Salida,Tiempo_Permanencia,Estado');

    for (var r in exportRecords) {
      final String exitTimeStr = r.exitTime != null ? r.exitTime!.toIso8601String() : 'N/A';
      final String status = r.isInside ? 'En el recinto' : 'Salido';
      csvBuffer.writeln(
        '"${r.id}","${r.type}","${r.name}","${r.docId}","${r.plate ?? ''}","${r.vehicleType ?? ''}","${r.destination}","${r.entryTime.toIso8601String()}","$exitTimeStr","${r.durationText}","$status"'
      );
    }

    final String csvText = csvBuffer.toString();

    if (kIsWeb) {
      // For web, display a beautiful Dialog copyable
      _showWebExportDialog(csvText);
    } else {
      // For Desktop/Linux, save to Documents folder using path_provider
      try {
        Directory? targetDir;
        if (Platform.isAndroid) {
          final dir = Directory('/storage/emulated/0/Download/acceso');
          try {
            if (!await dir.exists()) {
              await dir.create(recursive: true);
            }
            targetDir = dir;
          } catch (_) {
            final Directory? downloads = await getDownloadsDirectory();
            if (downloads != null) {
              targetDir = Directory('${downloads.path}/acceso');
              if (!await targetDir.exists()) {
                await targetDir.create(recursive: true);
              }
            }
          }
        } else {
          final Directory? downloads = await getDownloadsDirectory();
          if (downloads != null) {
            targetDir = Directory('${downloads.path}/acceso');
            if (!await targetDir.exists()) {
              await targetDir.create(recursive: true);
            }
          }
        }

        if (targetDir == null) {
          final Directory documentsDir = await getApplicationDocumentsDirectory();
          targetDir = Directory('${documentsDir.path}/acceso');
          if (!await targetDir.exists()) {
            await targetDir.create(recursive: true);
          }
        }

        final String path = '${targetDir.path}/reporte_accesos_${DateTime.now().millisecondsSinceEpoch}.csv';
        final File file = File(path);
        await file.writeAsString(csvText);

        if (!mounted) return;

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Reporte guardado en: $path'),
            backgroundColor: const Color(0xFF10B981),
            duration: const Duration(seconds: 5),
            action: SnackBarAction(
              label: 'Copiar Ruta',
              textColor: Colors.white,
              onPressed: () {
                Clipboard.setData(ClipboardData(text: path));
              },
            ),
          ),
        );
      } catch (e) {
        if (!mounted) return;
        
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error al exportar reporte: $e'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    }
  }

  void _showWebExportDialog(String csvContent) {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: slate800,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Row(
            children: [
              Icon(Icons.description, color: Color(0xFF10B981)),
              SizedBox(width: 12),
              Text('Reporte CSV Generado'),
            ],
          ),
          content: SizedBox(
            width: 500,
            height: 350,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'El navegador web no permite escribir archivos directos en disco. Puedes copiar el texto inferior y pegarlo en un bloc de notas o Excel.',
                  style: TextStyle(fontSize: 13, color: slate300),
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: slate900,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: SingleChildScrollView(
                      child: SelectableText(
                        csvContent,
                        style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              child: const Text('Cerrar', style: TextStyle(color: slate400)),
              onPressed: () => Navigator.pop(context),
            ),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF10B981)),
              icon: const Icon(Icons.copy),
              label: const Text('Copiar al Portapapeles'),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: csvContent));
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Copiado al portapapeles!'),
                    backgroundColor: Color(0xFF10B981),
                  ),
                );
              },
            ),
          ],
        );
      },
    );
  }

  // --- QR/Barcode Scanning Simulator ---

  void _showQRScannerSimulator() {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: slate800,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Row(
            children: [
              Icon(Icons.qr_code_scanner, color: Color(0xFF10B981), size: 28),
              SizedBox(width: 12),
              Text('Simulador de Lector QR'),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Seleccione uno de los códigos QR simulados para probar la detección instantánea y el flujo de ingreso:',
                style: TextStyle(fontSize: 14, color: slate300),
              ),
              const SizedBox(height: 16),
              
              // Option 1: Pre-authorized visitor
              _buildSimulateButton(
                title: 'Visita Pre-autorizada (Simulación QR)',
                subtitle: 'Peatón - Destino: Registro de Prueba',
                color: const Color(0xFF10B981),
                onTap: () {
                  Navigator.pop(context);
                  final pre = _preAuths.firstWhere((p) => p.id == 'p1', orElse: () => _preAuths[0]);
                  _triggerSimulatedScan(pre.name, () => _checkinPreAuth(pre));
                },
              ),
              const SizedBox(height: 10),

              // Option 2: Pre-authorized vehicle
              _buildSimulateButton(
                title: 'Vehículo Pre-autorizado (Simulación QR)',
                subtitle: 'Vehículo - Registro de Prueba',
                color: const Color(0xFF3B82F6),
                onTap: () {
                  Navigator.pop(context);
                  final pre = _preAuths.firstWhere((p) => p.id == 'p2', orElse: () => _preAuths[0]);
                  _triggerSimulatedScan('Vehículo ${pre.plate}', () => _checkinPreAuth(pre));
                },
              ),
              const SizedBox(height: 10),

              // Option 3: Guest without pre-authorization
              _buildSimulateButton(
                title: 'Peatón Imprevisto (Simulación QR)',
                subtitle: 'Registro de Prueba de Ingreso Directo',
                color: Colors.amber,
                onTap: () {
                  Navigator.pop(context);
                  _triggerSimulatedScan('Héctor Soto', () {
                    final newAccess = AccessRecord(
                      id: DateTime.now().millisecondsSinceEpoch.toString(),
                      type: 'persona',
                      name: 'Héctor Soto (Escaneado)',
                      docId: '19.332.114-K',
                      destination: 'Taller de Servicio Técnico',
                      entryTime: DateTime.now(),
                      isInside: true,
                    );
                    _recordsBox.put(newAccess.id, newAccess.toMap());
                    _refreshUILists();
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Ingreso registrado vía QR: Héctor Soto'),
                        backgroundColor: Colors.amber,
                      ),
                    );
                  });
                },
              ),
              const SizedBox(height: 10),

              // Option 4: Blacklisted visitor
              _buildSimulateButton(
                title: 'Esteban Muñoz (Restringido - Lista Negra)',
                subtitle: 'Peatón - RUT: 15.678.901-2',
                color: Colors.redAccent,
                onTap: () {
                  Navigator.pop(context);
                  _triggerSimulatedScan('Esteban Muñoz', () async {
                    final blacklistMatch = _checkBlacklist('15.678.901-2', null);
                    if (blacklistMatch != null) {
                      final override = await _showBlacklistWarningDialog(entry: blacklistMatch);
                      if (!context.mounted) return;
                      if (!override) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Acceso DENEGADO por restricción de Lista Negra.'),
                            backgroundColor: Colors.redAccent,
                          ),
                        );
                        return;
                      }

                      final newAccess = AccessRecord(
                        id: DateTime.now().millisecondsSinceEpoch.toString(),
                        type: 'persona',
                        name: 'Esteban Muñoz',
                        docId: '15.678.901-2',
                        destination: 'Oficina Central [Excepción Lista Negra]',
                        entryTime: DateTime.now(),
                        isInside: true,
                      );
                      await _recordsBox.put(newAccess.id, newAccess.toMap());
                      _refreshUILists();
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Ingreso excepcional REGISTRADO para Esteban Muñoz.'),
                          backgroundColor: Colors.amber,
                        ),
                      );
                    }
                  });
                },
              ),
            ],
          ),
          actions: [
            TextButton(
              child: const Text('Cancelar', style: TextStyle(color: slate400)),
              onPressed: () => Navigator.pop(context),
            )
          ],
        );
      },
    );
  }

  Widget _buildSimulateButton({
    required String title,
    required String subtitle,
    required Color color,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: slate900,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: color.withValues(alpha: 0.4), width: 1.5),
        ),
        child: Row(
          children: [
            Icon(Icons.qr_code, color: color, size: 32),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                  const SizedBox(height: 2),
                  Text(subtitle, style: const TextStyle(fontSize: 11, color: slate400)),
                ],
              ),
            ),
            Icon(Icons.chevron_right, color: color, size: 20),
          ],
        ),
      ),
    );
  }

  void _triggerSimulatedScan(String label, VoidCallback onSuccess) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        // Auto-close simulated processing after 1.5 seconds
        Timer(const Duration(milliseconds: 1500), () {
          Navigator.pop(context);
          onSuccess();
        });

        return AlertDialog(
          backgroundColor: slate800,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 16),
              const SizedBox(
                height: 50,
                width: 50,
                child: CircularProgressIndicator(strokeWidth: 4),
              ),
              const SizedBox(height: 24),
              const Text(
                'Procesando Lectura QR...',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
              ),
              const SizedBox(height: 8),
              Text(
                'Detectado: $label',
                style: const TextStyle(color: slate400, fontSize: 13),
              ),
              const SizedBox(height: 16),
            ],
          ),
        );
      },
    );
  }

  Future<void> _openCameraScanner() async {
    final String? scannedValue = await Navigator.push<String?>(
      context,
      MaterialPageRoute(builder: (context) => const CameraScannerScreen()),
    );

    if (scannedValue == null || scannedValue.isEmpty) return;

    _processQRScanResult(scannedValue);
  }

  Future<void> _processQRScanResult(String rawValue) async {
    // 1. Try parsing as our custom JSON QR Pass
    try {
      final Map<String, dynamic> data = jsonDecode(rawValue);
      final String? id = data['id'];
      if (id != null) {
        final preIndex = _preAuths.indexWhere((p) => p.id == id);
        if (preIndex != -1) {
          final pre = _preAuths[preIndex];
          _checkinPreAuth(pre);
          return;
        }
      }
    } catch (_) {
      // Not a JSON QR Pass
    }

    // 2. Treat as raw RUT/DNI or Patente
    final String cleanValue = rawValue.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '').toUpperCase();
    if (cleanValue.isEmpty) return;

    // Check if it's currently inside (to mark exit)
    final insideRecordIndex = _records.indexWhere((r) {
      if (!r.isInside) return false;
      final cleanDoc = r.docId.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '').toUpperCase();
      final cleanPlt = r.plate?.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '').toUpperCase() ?? '';
      return cleanDoc == cleanValue || cleanPlt == cleanValue;
    });

    if (insideRecordIndex != -1) {
      final record = _records[insideRecordIndex];
      final confirm = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: slate800,
          title: const Text('Registrar Salida'),
          content: Text('¿Desea registrar la salida de ${record.name}?'),
          actions: [
            TextButton(
              child: const Text('Cancelar', style: TextStyle(color: slate400)),
              onPressed: () => Navigator.pop(context, false),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF10B981)),
              child: const Text('Confirmar Salida', style: TextStyle(color: Colors.white)),
              onPressed: () => Navigator.pop(context, true),
            ),
          ],
        ),
      );

      if (confirm == true) {
        record.exitTime = DateTime.now();
        record.isInside = false;
        await _recordsBox.put(record.id, record.toMap());
        _refreshUILists();
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Salida registrada para: ${record.name}'),
            backgroundColor: const Color(0xFF10B981),
          ),
        );
      }
      return;
    }

    // Check if there is an unused pre-authorization matching this RUT or Patente
    final preAuthIndex = _preAuths.indexWhere((p) {
      if (p.isUsed) return false;
      final cleanDoc = p.docId.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '').toUpperCase();
      final cleanPlt = p.plate?.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '').toUpperCase() ?? '';
      return cleanDoc == cleanValue || cleanPlt == cleanValue;
    });

    if (preAuthIndex != -1) {
      final pre = _preAuths[preAuthIndex];
      _checkinPreAuth(pre);
      return;
    }

    // No matching pre-authorization, open registration dialog pre-filled!
    final isVehiclePlate = cleanValue.length <= 6 && RegExp(r'^[A-Z0-9]+$').hasMatch(cleanValue);
    _showNewEntryModalWithPrefill(
      prefilledDocId: isVehiclePlate ? '' : rawValue,
      prefilledPlate: isVehiclePlate ? rawValue : '',
    );
  }

  void _showNewEntryModalWithPrefill({String? prefilledDocId, String? prefilledPlate}) {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: slate800,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Text('Identificación no Registrada'),
          content: Text('El código escaneado (${prefilledDocId != null && prefilledDocId.isNotEmpty ? prefilledDocId : prefilledPlate}) no coincide con ninguna visita pre-autorizada activa.\n\n¿Desea registrar el ingreso manualmente?'),
          actions: [
            TextButton(
              child: const Text('Persona', style: TextStyle(color: Color(0xFF10B981))),
              onPressed: () {
                Navigator.pop(context);
                _showNewEntryModal('persona', prefilledDocId: prefilledDocId);
              },
            ),
            TextButton(
              child: const Text('Vehículo', style: TextStyle(color: Color(0xFF3B82F6))),
              onPressed: () {
                Navigator.pop(context);
                _showNewEntryModal('vehiculo', prefilledPlate: prefilledPlate);
              },
            ),
            TextButton(
              child: const Text('Cancelar', style: TextStyle(color: slate400)),
              onPressed: () => Navigator.pop(context),
            ),
          ],
        );
      },
    );
  }

  void _showScannerOptions() {
    showModalBottomSheet(
      context: context,
      backgroundColor: slate800,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.all(16.0),
                child: Text(
                  'Seleccione método de escaneo',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
                ),
              ),
              const Divider(color: slate700, height: 1),
              ListTile(
                leading: const Icon(Icons.camera_alt_rounded, color: Color(0xFF10B981)),
                title: const Text('Escanear con Cámara (Producción)', style: TextStyle(color: Colors.white)),
                subtitle: const Text('Utiliza la cámara del dispositivo en tiempo real.', style: TextStyle(color: slate400, fontSize: 12)),
                onTap: () {
                  Navigator.pop(context);
                  _openCameraScanner();
                },
              ),
              ListTile(
                leading: const Icon(Icons.qr_code_scanner_rounded, color: Colors.amber),
                title: const Text('Simular Escaneo QR (Demo)', style: TextStyle(color: Colors.white)),
                subtitle: const Text('Usa códigos precargados para demostración sin cámara.', style: TextStyle(color: slate400, fontSize: 12)),
                onTap: () {
                  Navigator.pop(context);
                  _showQRScannerSimulator();
                },
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  // --- Modals for Adding Entries ---

  void _showNewEntryModal(String type, {String? prefilledDocId, String? prefilledPlate}) {
    final formKey = GlobalKey<FormState>();
    final TextEditingController nameController = TextEditingController();
    final TextEditingController docIdController = TextEditingController(text: prefilledDocId ?? '');
    final TextEditingController plateController = TextEditingController(text: prefilledPlate ?? '');
    final TextEditingController destinationController = TextEditingController();
    final TextEditingController commentController = TextEditingController();
    final TextEditingController phoneController = TextEditingController();
    
    String vehicleType = 'Auto';
    bool isRut = prefilledDocId == null || prefilledDocId.isEmpty || RegExp(r'^[0-9kK\.\-]+$').hasMatch(prefilledDocId);
    
    String? selectedInstallationForRecord = _activeInstallation;
    final List<String> availableDestinations = List<String>.from(_destinationsBox.get(selectedInstallationForRecord) ?? ['Administración', 'Bodega', 'Estacionamiento']);
    if (!availableDestinations.contains('Otro...')) {
      availableDestinations.add('Otro...');
    }
    String selectedDestination = availableDestinations.first;
    bool showCustomDestination = false;

    List<Map<String, String>> suggestions = [];
    String suggestionsType = 'doc'; // 'doc', 'plate', or 'name'
    String? localPhotoPath;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: slate800,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setModalState) {
            
            void updateDocIdSuggestions(String query) {
              if (query.length < 3) {
                setModalState(() {
                  suggestions = [];
                });
                return;
              }
              final cleanQuery = query.replaceAll(RegExp(r'[^0-9kK]'), '');
              final List<Map<String, String>> matches = [];
              
              // 1. Search Pre-authorizations first
              for (final pre in _preAuths) {
                final cleanDoc = pre.docId.replaceAll(RegExp(r'[^0-9kK]'), '');
                if (cleanDoc.contains(cleanQuery) && pre.type == type) {
                  matches.add({
                    'source': 'preauth',
                    'name': pre.name,
                    'docId': pre.docId,
                    'plate': pre.plate ?? '',
                    'vehicleType': pre.vehicleType ?? 'Auto',
                    'destination': pre.destination,
                  });
                }
              }
              
              // 2. Search Access History
              for (final rec in _records) {
                final cleanDoc = rec.docId.replaceAll(RegExp(r'[^0-9kK]'), '');
                if (cleanDoc.contains(cleanQuery) && rec.type == type) {
                  if (!matches.any((m) => m['docId'] == rec.docId)) {
                    matches.add({
                      'source': 'history',
                      'name': rec.name,
                      'docId': rec.docId,
                      'plate': rec.plate ?? '',
                      'vehicleType': rec.vehicleType ?? 'Auto',
                      'destination': rec.destination,
                    });
                  }
                }
              }

              setModalState(() {
                suggestionsType = 'doc';
                suggestions = matches.take(3).toList();
              });
            }

            void updatePlateSuggestions(String query) {
              if (query.length < 2) {
                setModalState(() {
                  suggestions = [];
                });
                return;
              }
              final cleanQuery = query.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
              final List<Map<String, String>> matches = [];
              
              // 1. Search Pre-authorizations
              for (final pre in _preAuths) {
                if (pre.plate != null && pre.type == 'vehiculo') {
                  final cleanPlate = pre.plate!.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
                  if (cleanPlate.contains(cleanQuery)) {
                    matches.add({
                      'source': 'preauth',
                      'name': pre.name,
                      'docId': pre.docId,
                      'plate': pre.plate!,
                      'vehicleType': pre.vehicleType ?? 'Auto',
                      'destination': pre.destination,
                    });
                  }
                }
              }
              
              // 2. Search Access History
              for (final rec in _records) {
                if (rec.plate != null && rec.type == 'vehiculo') {
                  final cleanPlate = rec.plate!.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
                  if (cleanPlate.contains(cleanQuery)) {
                    if (!matches.any((m) => m['plate'] == rec.plate)) {
                      matches.add({
                        'source': 'history',
                        'name': rec.name,
                        'docId': rec.docId,
                        'plate': rec.plate!,
                        'vehicleType': rec.vehicleType ?? 'Auto',
                        'destination': rec.destination,
                      });
                    }
                  }
                }
              }

              setModalState(() {
                suggestionsType = 'plate';
                suggestions = matches.take(3).toList();
              });
            }

            void updateNameSuggestions(String query) {
              if (query.length < 3) {
                setModalState(() {
                  suggestions = [];
                });
                return;
              }
              final cleanQuery = query.toLowerCase().trim();
              final List<Map<String, String>> matches = [];
              
              // 1. Search Pre-authorizations
              for (final pre in _preAuths) {
                if (pre.name.toLowerCase().contains(cleanQuery) && pre.type == type) {
                  matches.add({
                    'source': 'preauth',
                    'name': pre.name,
                    'docId': pre.docId,
                    'plate': pre.plate ?? '',
                    'vehicleType': pre.vehicleType ?? 'Auto',
                    'destination': pre.destination,
                  });
                }
              }
              
              // 2. Search Access History
              for (final rec in _records) {
                if (rec.name.toLowerCase().contains(cleanQuery) && rec.type == type) {
                  if (!matches.any((m) => m['docId'] == rec.docId)) {
                    matches.add({
                      'source': 'history',
                      'name': rec.name,
                      'docId': rec.docId,
                      'plate': rec.plate ?? '',
                      'vehicleType': rec.vehicleType ?? 'Auto',
                      'destination': rec.destination,
                    });
                  }
                }
              }

              setModalState(() {
                suggestionsType = 'name';
                suggestions = matches.take(3).toList();
              });
            }

            void applySuggestion(Map<String, String> item) {
              setModalState(() {
                nameController.text = item['name']!;
                docIdController.text = item['docId']!;
                plateController.text = item['plate']!;
                
                final rawDest = item['destination']!;
                final cleanDest = _displayDestination(rawDest);
                
                if (availableDestinations.contains(cleanDest)) {
                  selectedDestination = cleanDest;
                  showCustomDestination = false;
                } else {
                  selectedDestination = 'Otro...';
                  showCustomDestination = true;
                  destinationController.text = cleanDest;
                }
                
                vehicleType = item['vehicleType'] ?? 'Auto';
                suggestions = [];
              });
            }

            Widget suggestionsWidget() {
              return Container(
                margin: const EdgeInsets.only(top: 4, bottom: 8),
                decoration: BoxDecoration(
                  color: slate900,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: slate700),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: suggestions.map((item) {
                    final isPreauth = item['source'] == 'preauth';
                    return ListTile(
                      dense: true,
                      leading: Icon(
                        isPreauth ? Icons.event_available_rounded : Icons.history_rounded,
                        color: isPreauth ? Colors.amber : slate400,
                      ),
                      title: Text(
                        '${item['name']} (${item['docId']})',
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                      ),
                      subtitle: Text(
                        'Destino: ${item['destination']}${item['plate']!.isNotEmpty ? ' | Patente: ${item['plate']}' : ''}',
                        style: const TextStyle(color: slate400),
                      ),
                      onTap: () => applySuggestion(item),
                    );
                  }).toList(),
                ),
              );
            }

            return Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(context).viewInsets.bottom + 24,
                left: 20,
                right: 20,
                top: 24,
              ),
              child: Form(
                key: formKey,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Icon(
                            type == 'persona' ? Icons.person_add_alt_1_rounded : Icons.local_shipping_rounded,
                            color: type == 'persona' ? const Color(0xFF10B981) : const Color(0xFF3B82F6),
                            size: 28,
                          ),
                          const SizedBox(width: 12),
                          Text(
                            type == 'persona' ? 'Registrar Ingreso Persona' : 'Registrar Ingreso Vehículo',
                            style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
                          ),
                          const Spacer(),
                          IconButton(
                            icon: const Icon(Icons.close, color: slate400),
                            onPressed: () => Navigator.pop(context),
                          )
                        ],
                      ),
                      const Divider(height: 24, color: slate700),

                      if (_activeInstallation == null && widget.userRole == UserRole.admin) ...[
                        DropdownButtonFormField<String>(
                          value: selectedInstallationForRecord,
                          decoration: InputDecoration(
                            labelText: 'Seleccione Instalación / Grupo *',
                            prefixIcon: const Icon(Icons.business_rounded, color: Color(0xFF10B981)),
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                            filled: true,
                            fillColor: slate900,
                          ),
                          items: _installationsBox.values
                              .where((v) => v is Map && v['name'] != null)
                              .map((v) => (v as Map)['name'] as String)
                              .map((instName) => DropdownMenuItem(value: instName, child: Text(instName)))
                              .toList(),
                          validator: (val) => val == null || val.isEmpty ? 'Seleccione una instalación' : null,
                          onChanged: (val) {
                            if (val != null) {
                              setModalState(() {
                                selectedInstallationForRecord = val;
                                availableDestinations.clear();
                                availableDestinations.addAll(List<String>.from(_destinationsBox.get(val) ?? ['Administración', 'Bodega', 'Estacionamiento']));
                                if (!availableDestinations.contains('Otro...')) availableDestinations.add('Otro...');
                                selectedDestination = availableDestinations.first;
                              });
                            }
                          },
                        ),
                        const SizedBox(height: 16),
                      ],

                      TextFormField(
                        controller: nameController,
                        decoration: InputDecoration(
                          labelText: type == 'persona' ? 'Nombre de la Persona' : 'Nombre del Conductor',
                          prefixIcon: const Icon(Icons.person),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                          filled: true,
                          fillColor: slate900,
                        ),
                        onChanged: updateNameSuggestions,
                        validator: (value) => value == null || value.trim().isEmpty ? 'Ingrese un nombre válido' : null,
                      ),
                      if (suggestions.isNotEmpty && suggestionsType == 'name')
                        suggestionsWidget(),
                      const SizedBox(height: 16),

                      // Selector de tipo de documento
                      Row(
                        children: [
                          const Text('Tipo de Doc: ', style: TextStyle(color: slate400, fontSize: 13)),
                          const SizedBox(width: 8),
                          ChoiceChip(
                            label: const Text('RUT', style: TextStyle(fontSize: 12)),
                            selected: isRut,
                            onSelected: (selected) {
                              if (selected) {
                                setModalState(() => isRut = true);
                              }
                            },
                            backgroundColor: slate900,
                            selectedColor: const Color(0xFF10B981).withValues(alpha: 0.3),
                          ),
                          const SizedBox(width: 8),
                          ChoiceChip(
                            label: const Text('Pasaporte / DNI', style: TextStyle(fontSize: 12)),
                            selected: !isRut,
                            onSelected: (selected) {
                              if (selected) {
                                setModalState(() => isRut = false);
                              }
                            },
                            backgroundColor: slate900,
                            selectedColor: const Color(0xFF10B981).withValues(alpha: 0.3),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),

                      TextFormField(
                        key: ValueKey('entry_doc_field_$isRut'),
                        controller: docIdController,
                        decoration: InputDecoration(
                          labelText: isRut ? 'RUT (Ej: 12.345.678-9)' : 'Identificación (DNI o Pasaporte)',
                          prefixIcon: const Icon(Icons.badge),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                          filled: true,
                          fillColor: slate900,
                        ),
                        inputFormatters: isRut ? [RutFormatter()] : null,
                        onChanged: updateDocIdSuggestions,
                        validator: (value) {
                          if (value == null || value.trim().isEmpty) {
                            return 'Ingrese identificación';
                          }
                          if (!isValidDocument(value, isRut)) {
                            return isRut ? 'RUT inválido (Dígito verificador incorrecto)' : 'Identificación inválida (mínimo 5 caracteres)';
                          }
                          return null;
                        },
                      ),
                      
                      if (suggestions.isNotEmpty && suggestionsType == 'doc')
                        suggestionsWidget(),
                      
                      const SizedBox(height: 16),

                      if (type == 'vehiculo') ...[
                        Row(
                          children: [
                            Expanded(
                              flex: 2,
                              child: TextFormField(
                                textCapitalization: TextCapitalization.characters,
                                controller: plateController,
                                decoration: InputDecoration(
                                  labelText: 'Patente / Placa',
                                  prefixIcon: const Icon(Icons.tag),
                                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                                  filled: true,
                                  fillColor: slate900,
                                ),
                                inputFormatters: [PlateFormatter()],
                                onChanged: updatePlateSuggestions,
                                validator: (value) {
                                  if (value == null || value.trim().isEmpty) {
                                    return 'Ingrese patente';
                                  }
                                  if (!isValidPlate(value)) {
                                    return 'Patente inválida (mínimo 4 caracteres)';
                                  }
                                  return null;
                                },
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              flex: 3,
                              child: DropdownButtonFormField<String>(
                                initialValue: vehicleType,
                                decoration: InputDecoration(
                                  labelText: 'Tipo de Vehículo',
                                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                                  filled: true,
                                  fillColor: slate900,
                                ),
                                items: ['Auto', 'Camioneta', 'SUV', 'Camión de Carga', 'Furgón', 'Moto', 'Bicicleta', 'Bus']
                                    .map((t) => DropdownMenuItem(value: t, child: Text(t)))
                                    .toList(),
                                onChanged: (value) {
                                  if (value != null) {
                                    setModalState(() {
                                      vehicleType = value;
                                    });
                                  }
                                },
                              ),
                            ),
                          ],
                        ),
                        
                        if (suggestions.isNotEmpty && suggestionsType == 'plate')
                          suggestionsWidget(),

                        const SizedBox(height: 16),
                      ],

                      DropdownButtonFormField<String>(
                        value: selectedDestination,
                        decoration: InputDecoration(
                          labelText: 'Destino / Motivo de Visita',
                          prefixIcon: const Icon(Icons.meeting_room),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                          filled: true,
                          fillColor: slate900,
                        ),
                        items: availableDestinations.map((dest) {
                          return DropdownMenuItem<String>(
                            value: dest,
                            child: Text(dest),
                          );
                        }).toList(),
                        onChanged: (val) {
                          if (val != null) {
                            setModalState(() {
                              selectedDestination = val;
                              showCustomDestination = (val == 'Otro...');
                            });
                          }
                        },
                      ),
                      const SizedBox(height: 16),

                      if (showCustomDestination) ...[
                        TextFormField(
                          controller: destinationController,
                          decoration: InputDecoration(
                            labelText: 'Escriba el Destino Personalizado',
                            prefixIcon: const Icon(Icons.edit_location_alt_rounded),
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                            filled: true,
                            fillColor: slate900,
                          ),
                          validator: (value) => value == null || value.trim().isEmpty ? 'Ingrese el destino personalizado' : null,
                        ),
                        const SizedBox(height: 16),
                      ],

                      TextFormField(
                        controller: commentController,
                        decoration: InputDecoration(
                          labelText: 'Comentario (Opcional)',
                          prefixIcon: const Icon(Icons.comment_outlined),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                          filled: true,
                          fillColor: slate900,
                        ),
                      ),
                      const SizedBox(height: 16),

                      TextFormField(
                        controller: phoneController,
                        keyboardType: TextInputType.phone,
                        decoration: InputDecoration(
                          labelText: 'Teléfono de Contacto (Opcional)',
                          prefixIcon: const Icon(Icons.phone_android_rounded),
                          hintText: 'Ej: +56912345678',
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                          filled: true,
                          fillColor: slate900,
                        ),
                      ),
                      const SizedBox(height: 16),

                      // Registro Fotográfico
                      const Text(
                        'Registro Fotográfico (Opcional)',
                        style: TextStyle(color: slate400, fontSize: 13, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 8),
                      localPhotoPath == null
                          ? InkWell(
                              onTap: () async {
                                try {
                                  final picker = ImagePicker();
                                  final image = await picker.pickImage(
                                    source: ImageSource.camera,
                                    imageQuality: 70,
                                  );
                                  if (image != null) {
                                    setModalState(() {
                                      localPhotoPath = image.path;
                                    });
                                  }
                                } catch (e) {
                                  if (context.mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: Text('Error al abrir cámara: $e'),
                                        backgroundColor: Colors.red,
                                      ),
                                    );
                                  }
                                }
                              },
                              child: Container(
                                height: 80,
                                decoration: BoxDecoration(
                                  color: slate900,
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(color: slate700),
                                ),
                                child: const Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(Icons.camera_alt_rounded, color: slate400, size: 24),
                                    SizedBox(width: 8),
                                    Text(
                                      'Capturar Fotografía',
                                      style: TextStyle(color: slate400, fontSize: 13),
                                    ),
                                  ],
                                ),
                              ),
                            )
                          : Stack(
                              children: [
                                Container(
                                  height: 140,
                                  width: double.infinity,
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(12),
                                    image: DecorationImage(
                                      image: FileImage(File(localPhotoPath!)),
                                      fit: BoxFit.cover,
                                    ),
                                  ),
                                ),
                                Positioned(
                                  top: 8,
                                  right: 8,
                                  child: GestureDetector(
                                    onTap: () {
                                      setModalState(() {
                                        localPhotoPath = null;
                                      });
                                    },
                                    child: Container(
                                      decoration: const BoxDecoration(
                                        color: Colors.red,
                                        shape: BoxShape.circle,
                                      ),
                                      padding: const EdgeInsets.all(4),
                                      child: const Icon(
                                        Icons.close,
                                        color: Colors.white,
                                        size: 16,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                      const SizedBox(height: 24),

                      ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: type == 'persona' ? const Color(0xFF10B981) : const Color(0xFF3B82F6),
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                        onPressed: () async {
                          if (formKey.currentState!.validate()) {
                            final name = nameController.text.trim();
                            final docId = docIdController.text.trim();
                            final plate = plateController.text.trim().toUpperCase();
                            final destination = selectedDestination == 'Otro...'
                                ? destinationController.text.trim()
                                : selectedDestination;
                            
                             // Check blacklist first!
                             final blacklistMatch = _checkBlacklist(docId, type == 'vehiculo' ? plate : null);
                             if (blacklistMatch != null) {
                               // 1. Play local alarm notification immediately
                               NotificationHelper.showNotification(
                                 '⚠️ ALERTA: Intento de Ingreso Bloqueado',
                                 '$name (${type == 'persona' ? 'RUT: $docId' : 'Patente: $plate'}) está en la Lista Negra.',
                                 isAlert: true,
                               );

                               // 2. Save a "Denied Entry" record to history and sync it
                               final deniedRecord = AccessRecord(
                                 id: DateTime.now().millisecondsSinceEpoch.toString(),
                                 type: type,
                                 name: name,
                                 docId: docId,
                                 plate: type == 'vehiculo' ? plate : null,
                                 vehicleType: type == 'vehiculo' ? vehicleType : null,
                                 destination: widget.installationName != null
                                     ? '${widget.installationName} | [ACCESO DENEGADO - LISTA NEGRA] $destination'
                                     : '[ACCESO DENEGADO - LISTA NEGRA] $destination',
                                 entryTime: DateTime.now(),
                                 isInside: false,
                                 comment: 'Intento de ingreso denegado automáticamente. Razón: ${blacklistMatch.reason}',
                               );
                               await _recordsBox.put(deniedRecord.id, deniedRecord.toMap());
                               _refreshUILists();

                               // 3. Show dialog to guard
                               if (context.mounted) {
                                 Navigator.pop(context); // Close sheet
                                 showDialog(
                                   context: context,
                                   builder: (context) => AlertDialog(
                                     backgroundColor: slate800,
                                     shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                                     title: const Row(
                                       children: [
                                         Icon(Icons.gpp_bad_rounded, color: Colors.redAccent),
                                         SizedBox(width: 8),
                                         Text('ACCESO DENEGADO', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                                       ],
                                     ),
                                     content: Text(
                                       'El visitante "$name" (${type == 'persona' ? 'RUT: $docId' : 'Patente: $plate'}) se encuentra en la LISTA NEGRA.\n\nMotivo: ${blacklistMatch.reason}\n\nEl intento de ingreso ha sido rechazado y registrado en el historial.',
                                       style: const TextStyle(color: slate300),
                                     ),
                                     actions: [
                                       TextButton(
                                         onPressed: () => Navigator.pop(context),
                                         child: const Text('Entendido', style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold)),
                                       ),
                                     ],
                                   ),
                                 );
                               }
                               return;
                             }

                              // Check Whitelist (Lista Blanca)!
                              final whitelistMatch = _checkWhitelist(docId, type == 'vehiculo' ? plate : null);
                              if (whitelistMatch != null) {
                                NotificationHelper.showNotification(
                                  '✅ LISTA BLANCA: Permita el Acceso',
                                  '${whitelistMatch.name} (${whitelistMatch.unitOrRole}) pertenece a la Lista Blanca. No se requiere registro de bitácora.',
                                  isAlert: false,
                                );

                                _addNotification(
                                  type: 'info',
                                  title: '✅ Lista Blanca - Acceso Permitido',
                                  body: '${whitelistMatch.name} (${whitelistMatch.unitOrRole}) ingresó sin registro por ser Lista Blanca.',
                                );

                                if (context.mounted) {
                                  Navigator.pop(context); // Close sheet
                                  showDialog(
                                    context: context,
                                    builder: (context) => AlertDialog(
                                      backgroundColor: slate800,
                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                                      title: const Row(
                                        children: [
                                          Icon(Icons.verified_user_rounded, color: Color(0xFF10B981)),
                                          SizedBox(width: 8),
                                          Text('LISTA BLANCA', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                                        ],
                                      ),
                                      content: Text(
                                        '${whitelistMatch.name} (${whitelistMatch.unitOrRole})\n\nPertenece a la LISTA BLANCA del recinto.\nPermita el acceso directamente.\n\n(No se genera registro en la bitácora de historial)',
                                        style: const TextStyle(color: slate300),
                                      ),
                                      actions: [
                                        TextButton(
                                          onPressed: () => Navigator.pop(context),
                                          child: const Text('Permitir Acceso', style: TextStyle(color: Color(0xFF10B981), fontWeight: FontWeight.bold)),
                                        ),
                                      ],
                                    ),
                                  );
                                }
                                return;
                              }

                            // Check for duplicates
                            AccessRecord? duplicateRecord;
                            String identifierLabel = '';
                            
                            final cleanDoc = docId.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '').toUpperCase();
                            final cleanPlt = plate.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '').toUpperCase();
                            
                            if (type == 'persona') {
                              duplicateRecord = _records.cast<AccessRecord?>().firstWhere(
                                (r) => r != null && r.isInside && r.type == 'persona' && r.docId.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '').toUpperCase() == cleanDoc,
                                  orElse: () => null,
                              );
                              identifierLabel = docId;
                            } else {
                              duplicateRecord = _records.cast<AccessRecord?>().firstWhere(
                                (r) => r != null && r.isInside && r.type == 'vehiculo' && r.plate != null && r.plate!.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '').toUpperCase() == cleanPlt,
                                orElse: () => null,
                              );
                              identifierLabel = 'Patente $plate';
                              
                              if (duplicateRecord == null) {
                                duplicateRecord = _records.cast<AccessRecord?>().firstWhere(
                                  (r) => r != null && r.isInside && r.docId.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '').toUpperCase() == cleanDoc,
                                  orElse: () => null,
                                );
                                identifierLabel = docId;
                              }
                            }
                            
                            if (duplicateRecord != null) {
                              final proceed = await _showDuplicateWarningDialog(
                                name: duplicateRecord.name,
                                type: type == 'persona' ? 'persona' : 'vehículo',
                                identifier: identifierLabel,
                                existingRecord: duplicateRecord,
                              );
                              
                              if (!proceed) {
                                return;
                              }
                              
                              // Check out the duplicate record
                              duplicateRecord.isInside = false;
                              duplicateRecord.exitTime = DateTime.now();
                              await _recordsBox.put(duplicateRecord.id, duplicateRecord.toMap());
                            }

                            // Check if there is an unused pre-authorization matching this RUT or Patente
                            final preAuthIndex = _preAuths.indexWhere((p) {
                              if (p.isUsed) return false;
                              final cleanDocMatch = p.docId.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '').toUpperCase();
                              final cleanPltMatch = p.plate?.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '').toUpperCase() ?? '';
                              return cleanDocMatch == cleanDoc || (type == 'vehiculo' && cleanPltMatch == cleanPlt);
                            });

                            bool isPreauthVisit = false;
                            if (preAuthIndex != -1) {
                              final pre = _preAuths[preAuthIndex];
                              // Mark pre-auth as used
                              pre.isUsed = true;
                              await _preAuthBox.put(pre.id, pre.toMap());
                              isPreauthVisit = true;
                            }

                            final finalDestination = isPreauthVisit
                                ? '$destination [Visita Agendada]'
                                : destination;

                            final targetInst = selectedInstallationForRecord ?? _activeInstallation;
                            final newRecord = AccessRecord(
                              id: DateTime.now().millisecondsSinceEpoch.toString(),
                              type: type,
                              name: name,
                              docId: docId,
                              plate: type == 'vehiculo' ? plate : null,
                              vehicleType: type == 'vehiculo' ? vehicleType : null,
                              destination: targetInst != null
                                  ? '$targetInst | $finalDestination'
                                  : finalDestination,
                              entryTime: DateTime.now(),
                              photoPath: localPhotoPath,
                              comment: commentController.text.trim().isEmpty ? null : commentController.text.trim(),
                              phone: phoneController.text.trim().isEmpty ? null : phoneController.text.trim(),
                            );
                            
                            await _recordsBox.put(newRecord.id, newRecord.toMap());

                            if (isPreauthVisit) {
                              NotificationHelper.showNotification(
                                '📢 VISITA AGENDADA',
                                '$name ha ingresado (Visita Agendada a $destination). Se recomienda dar aviso.',
                                isAlert: false,
                              );
                              _addNotification(
                                type: 'info',
                                title: '📢 Visita Agendada - Ingreso',
                                body: 'Visita agendada $name ingresó a $destination. Se recomienda dar aviso.',
                              );
                            }

                            _refreshUILists();

                            if (context.mounted) {
                              Navigator.pop(context);
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    isPreauthVisit
                                        ? 'Visita Agendada: Ingreso registrado para $name (Dar aviso al residente)'
                                        : 'Ingreso registrado para: $name',
                                  ),
                                  backgroundColor: isPreauthVisit ? Colors.amber.shade800 : (type == 'persona' ? const Color(0xFF10B981) : const Color(0xFF3B82F6)),
                                  duration: const Duration(seconds: 4),
                                ),
                              );
                            }
                          }
                        },
                        child: const Text(
                          'Confirmar Ingreso',
                          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  void _showNewPreAuthModal() {
    final formKey = GlobalKey<FormState>();
    String name = '';
    String docId = '';
    String type = 'persona';
    String plate = '';
    String vehicleType = 'Auto';
    String destination = '';
    DateTime visitDate = DateTime.now();
    bool isRut = true;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: slate800,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setModalState) {
            return Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(context).viewInsets.bottom + 24,
                left: 20,
                right: 20,
                top: 24,
              ),
              child: Form(
                key: formKey,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.event_note, color: Colors.amber, size: 28),
                          const SizedBox(width: 12),
                          Text(
                            'Agendar Pre-Autorización',
                            style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
                          ),
                          const Spacer(),
                          IconButton(
                            icon: const Icon(Icons.close, color: slate400),
                            onPressed: () => Navigator.pop(context),
                          )
                        ],
                      ),
                      const Divider(height: 24, color: slate700),

                      // Segment selector for type
                      Row(
                        children: [
                          Expanded(
                            child: ChoiceChip(
                              label: const Text('Peatón'),
                              selected: type == 'persona',
                              onSelected: (selected) {
                                if (selected) setModalState(() => type = 'persona');
                              },
                              backgroundColor: slate900,
                              selectedColor: const Color(0xFF10B981),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: ChoiceChip(
                              label: const Text('Vehículo'),
                              selected: type == 'vehiculo',
                              onSelected: (selected) {
                                if (selected) setModalState(() => type = 'vehiculo');
                              },
                              backgroundColor: slate900,
                              selectedColor: const Color(0xFF3B82F6),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),

                      TextFormField(
                        decoration: InputDecoration(
                          labelText: 'Nombre Completo del Visitante',
                          prefixIcon: const Icon(Icons.person),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                          filled: true,
                          fillColor: slate900,
                        ),
                        validator: (value) => value == null || value.trim().isEmpty ? 'Ingrese un nombre' : null,
                        onSaved: (value) => name = value!.trim(),
                      ),
                      const SizedBox(height: 16),

                      // Selector de tipo de documento
                      Row(
                        children: [
                          const Text('Tipo de Doc: ', style: TextStyle(color: slate400, fontSize: 13)),
                          const SizedBox(width: 8),
                          ChoiceChip(
                            label: const Text('RUT', style: TextStyle(fontSize: 12)),
                            selected: isRut,
                            onSelected: (selected) {
                              if (selected) {
                                setModalState(() => isRut = true);
                              }
                            },
                            backgroundColor: slate900,
                            selectedColor: const Color(0xFF10B981).withValues(alpha: 0.3),
                          ),
                          const SizedBox(width: 8),
                          ChoiceChip(
                            label: const Text('Pasaporte / DNI', style: TextStyle(fontSize: 12)),
                            selected: !isRut,
                            onSelected: (selected) {
                              if (selected) {
                                setModalState(() => isRut = false);
                              }
                            },
                            backgroundColor: slate900,
                            selectedColor: const Color(0xFF10B981).withValues(alpha: 0.3),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),

                      TextFormField(
                        key: ValueKey('preauth_doc_field_$isRut'),
                        decoration: InputDecoration(
                          labelText: isRut ? 'RUT (Ej: 12.345.678-9)' : 'Identificación (DNI o Pasaporte)',
                          prefixIcon: const Icon(Icons.badge),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                          filled: true,
                          fillColor: slate900,
                        ),
                        inputFormatters: isRut ? [RutFormatter()] : null,
                        validator: (value) {
                          if (value == null || value.trim().isEmpty) {
                            return 'Ingrese identificación';
                          }
                          if (!isValidDocument(value, isRut)) {
                            return isRut ? 'RUT inválido (Dígito verificador incorrecto)' : 'Identificación inválida (mínimo 5 caracteres)';
                          }
                          return null;
                        },
                        onSaved: (value) => docId = value!.trim(),
                      ),
                      const SizedBox(height: 16),

                      if (type == 'vehiculo') ...[
                        Row(
                          children: [
                            Expanded(
                              flex: 2,
                              child: TextFormField(
                                textCapitalization: TextCapitalization.characters,
                                decoration: InputDecoration(
                                  labelText: 'Patente / Placa',
                                  prefixIcon: const Icon(Icons.tag),
                                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                                  filled: true,
                                  fillColor: slate900,
                                ),
                                inputFormatters: [PlateFormatter()],
                                validator: (value) {
                                  if (value == null || value.trim().isEmpty) {
                                    return 'Ingrese patente';
                                  }
                                  if (!isValidPlate(value)) {
                                    return 'Patente inválida (mínimo 4 caracteres)';
                                  }
                                  return null;
                                },
                                onSaved: (value) => plate = value!.trim().toUpperCase(),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              flex: 3,
                              child: DropdownButtonFormField<String>(
                                initialValue: vehicleType,
                                decoration: InputDecoration(
                                  labelText: 'Tipo de Vehículo',
                                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                                  filled: true,
                                  fillColor: slate900,
                                ),
                                items: ['Auto', 'Camioneta', 'SUV', 'Camión de Carga', 'Furgón', 'Moto', 'Bicicleta', 'Bus']
                                    .map((t) => DropdownMenuItem(value: t, child: Text(t)))
                                    .toList(),
                                onChanged: (value) {
                                  if (value != null) {
                                    setModalState(() {
                                      vehicleType = value;
                                    });
                                  }
                                },
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                      ],

                      TextFormField(
                        decoration: InputDecoration(
                          labelText: 'Destino / Motivo de Visita',
                          prefixIcon: const Icon(Icons.meeting_room),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                          filled: true,
                          fillColor: slate900,
                        ),
                        validator: (value) => value == null || value.trim().isEmpty ? 'Ingrese destino' : null,
                        onSaved: (value) => destination = value!.trim(),
                      ),
                      const SizedBox(height: 16),

                      // Date selector display
                      InkWell(
                        onTap: () async {
                          final DateTime? picked = await showDatePicker(
                            context: context,
                            initialDate: visitDate,
                            firstDate: DateTime.now(),
                            lastDate: DateTime.now().add(const Duration(days: 365)),
                            builder: (context, child) {
                              return Theme(
                                data: Theme.of(context).copyWith(
                                  colorScheme: const ColorScheme.dark(
                                    primary: Color(0xFF10B981),
                                    onPrimary: Colors.white,
                                    surface: slate800,
                                    onSurface: slate100,
                                  ),
                                ),
                                child: child!,
                              );
                            },
                          );
                          if (picked != null) {
                            setModalState(() {
                              visitDate = picked;
                            });
                          }
                        },
                        child: InputDecorator(
                          decoration: InputDecoration(
                            labelText: 'Fecha de Visita Agendada',
                            prefixIcon: const Icon(Icons.calendar_today),
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                            filled: true,
                            fillColor: slate900,
                          ),
                          child: Text(
                            '${visitDate.day}/${visitDate.month}/${visitDate.year}',
                            style: const TextStyle(fontSize: 15, color: Colors.white),
                          ),
                        ),
                      ),
                      const SizedBox(height: 24),

                      ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.amber.shade700,
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                        onPressed: () {
                          if (formKey.currentState!.validate()) {
                            formKey.currentState!.save();
                              final targetInst = _activeInstallation;
                              final newPreAuth = PreAuthRecord(
                                id: 'pre_${DateTime.now().millisecondsSinceEpoch}',
                                type: type,
                                name: name,
                                docId: docId,
                                plate: type == 'vehiculo' ? plate : null,
                                vehicleType: type == 'vehiculo' ? vehicleType : null,
                                destination: targetInst != null
                                    ? '$targetInst | $destination'
                                    : destination,
                                visitDate: visitDate,
                              );

                            _preAuthBox.put(newPreAuth.id, newPreAuth.toMap());
                            _refreshUILists();

                            Navigator.pop(context);

                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text('Pre-autorización agendada para: $name'),
                                backgroundColor: Colors.amber.shade700,
                                duration: const Duration(seconds: 2),
                              ),
                            );
                          }
                        },
                        child: const Text(
                          'Guardar Pre-Autorización',
                          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  void _showNotificationsModal() {
    showModalBottomSheet(
      context: context,
      backgroundColor: slate800,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return Padding(
              padding: const EdgeInsets.all(20.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.notifications_rounded, color: Colors.blueAccent),
                          const SizedBox(width: 8),
                          Text(
                            'Centro de Notificaciones',
                            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                            ),
                          ),
                        ],
                      ),
                      TextButton(
                        onPressed: () {
                          setState(() {
                            for (var n in _notifications) {
                              n.isRead = true;
                            }
                          });
                          setModalState(() {});
                        },
                        child: const Text('Marcar leído', style: TextStyle(color: Colors.blueAccent)),
                      ),
                    ],
                  ),
                  const Divider(color: slate700, height: 20),
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      maxHeight: MediaQuery.of(context).size.height * 0.4,
                    ),
                    child: _notifications.isEmpty
                        ? const Center(
                            child: Padding(
                              padding: EdgeInsets.symmetric(vertical: 40.0),
                              child: Text(
                                'No hay notificaciones recientes',
                                style: TextStyle(color: slate400),
                              ),
                            ),
                          )
                        : ListView.separated(
                            shrinkWrap: true,
                            itemCount: _notifications.length,
                            separatorBuilder: (context, index) => const Divider(color: slate800),
                            itemBuilder: (context, index) {
                              final notif = _notifications[index];
                              final isAlert = notif.type == 'alerta';
                              final isSync = notif.type == 'sync';
                              
                              Color iconColor = Colors.blueAccent;
                              IconData iconData = Icons.info_outline;
                              if (isAlert) {
                                iconColor = Colors.redAccent;
                                iconData = Icons.warning_amber_rounded;
                              } else if (isSync) {
                                iconColor = const Color(0xFF10B981);
                                iconData = Icons.sync_rounded;
                              }

                              return Container(
                                decoration: BoxDecoration(
                                  color: notif.isRead ? Colors.transparent : slate900.withValues(alpha: 0.5),
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: ListTile(
                                  leading: CircleAvatar(
                                    backgroundColor: iconColor.withValues(alpha: 0.15),
                                    child: Icon(iconData, color: iconColor),
                                  ),
                                  title: Text(
                                    notif.title,
                                    style: TextStyle(
                                      fontWeight: notif.isRead ? FontWeight.normal : FontWeight.bold,
                                      color: Colors.white,
                                      fontSize: 14,
                                    ),
                                  ),
                                  subtitle: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      const SizedBox(height: 4),
                                      Text(
                                        notif.body,
                                        style: const TextStyle(color: slate400, fontSize: 12),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        '${notif.timestamp.hour.toString().padLeft(2, '0')}:${notif.timestamp.minute.toString().padLeft(2, '0')}',
                                        style: const TextStyle(color: slate500, fontSize: 10),
                                      ),
                                    ],
                                  ),
                                  onTap: () {
                                    setState(() {
                                      notif.isRead = true;
                                    });
                                    setModalState(() {});
                                  },
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  void _showSettingsModal() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return DraggableScrollableSheet(
          initialChildSize: 0.85,
          minChildSize: 0.5,
          maxChildSize: 0.95,
          builder: (context, scrollController) {
            return Container(
              decoration: const BoxDecoration(
                color: slate900,
                borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
              ),
              child: Column(
                children: [
                  // Grabber handle
                  Container(
                    margin: const EdgeInsets.symmetric(vertical: 12),
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: slate700,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  
                  // Header
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Row(
                          children: [
                            Icon(Icons.shield_outlined, color: Color(0xFF10B981), size: 24),
                            SizedBox(width: 8),
                            Text(
                              'Configuración y Seguridad',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                        IconButton(
                          icon: const Icon(Icons.close, color: slate400),
                          onPressed: () => Navigator.pop(context),
                        ),
                      ],
                    ),
                  ),
                  const Divider(color: slate800, height: 1),
                  
                  // Scrollable Content
                  Expanded(
                    child: ListView(
                      controller: scrollController,
                      padding: const EdgeInsets.all(20),
                      children: [
                        // --- Section 1: OWASP Security Compliance ---
                        _buildSectionHeader('Evaluación de Seguridad (OWASP)'),
                        const SizedBox(height: 12),
                        _buildSecurityCard(
                          title: 'Autenticación y Sesiones (OWASP M1)',
                          description: 'Claves de acceso encriptadas y aisladas a nivel de base de datos local y remota. Control de sesiones multi-tenant robusto.',
                          isSecure: true,
                        ),
                        _buildSecurityCard(
                          title: 'Almacenamiento de Datos (OWASP M2)',
                          description: 'La base de datos local Hive reside dentro del almacenamiento privado y protegido (sandbox) de la aplicación, previniendo accesos no autorizados por otras apps.',
                          isSecure: true,
                        ),
                        _buildSecurityCard(
                          title: 'Comunicaciones Seguras (OWASP M3)',
                          description: 'Todo el tráfico de sincronización hacia el servidor central utiliza HTTPS con TLS 1.3 y certificados SSL robustos, evitando intercepciones (MitM).',
                          isSecure: true,
                        ),
                        _buildSecurityCard(
                          title: 'Integridad y Ofuscación (OWASP M4)',
                          description: 'Minimización de dependencias y optimización con ProGuard/R8 para ofuscar código nativo y evitar ingeniería inversa del APK.',
                          isSecure: true,
                        ),
                        _buildSecurityCard(
                          title: 'Aislamiento de Clientes (Multi-tenant)',
                          description: 'Políticas estrictas a nivel de registro separando datos de diferentes recintos. Las consultas solo devuelven datos pertenecientes al tenant activo.',
                          isSecure: true,
                        ),
                        
                        const SizedBox(height: 24),
                        
                        // --- Section 2: Privacy Policy ---
                        _buildSectionHeader('Política de Privacidad'),
                        const SizedBox(height: 12),
                        Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: slate800,
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: slate700),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              const Text(
                                'POLÍTICA DE PRIVACIDAD Y PROTECCIÓN DE DATOS\n\n'
                                '1. RECOPILACIÓN DE INFORMACIÓN\n'
                                'La aplicación "Acceso" recopila información necesaria para el control de seguridad y flujo de personas de los recintos autorizados. Esto incluye nombres, números de RUT/DNI, patentes de vehículos, comentarios de acceso y fotografías tomadas al momento de ingreso.\n\n'
                                '2. USO DE LOS DATOS\n'
                                'Toda la información recopilada tiene como fin único el registro histórico de accesos y la gestión de la Lista Negra del recinto para garantizar la seguridad perimetral. Los datos no son vendidos, arrendados ni compartidos con terceros para fines comerciales.\n\n'
                                '3. SEGURIDAD DE LOS DATOS\n'
                                'Los datos se almacenan localmente en el sandbox seguro del dispositivo móvil y se sincronizan a través de canales encriptados HTTPS/TLS con la base de datos centralizada bajo estrictas políticas de acceso restringido.\n\n'
                                '4. DERECHOS ARCO\n'
                                'Los titulares de los datos tienen derecho a solicitar el acceso, rectificación o eliminación de sus registros del sistema poniéndose en contacto con el administrador del respectivo recinto.',
                                style: TextStyle(color: slate300, fontSize: 13, height: 1.5),
                              ),
                              const SizedBox(height: 16),
                              ElevatedButton.icon(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: const Color(0xFF3B82F6),
                                  foregroundColor: Colors.white,
                                  padding: const EdgeInsets.symmetric(vertical: 12),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                ),
                                icon: const Icon(Icons.open_in_new_rounded, size: 18),
                                label: const Text('Ver Política Oficial en Web', style: TextStyle(fontWeight: FontWeight.bold)),
                                onPressed: () async {
                                  final uri = Uri.parse('https://cristianbravo-dev.web.app/es/privacy/acceso');
                                  if (await canLaunchUrl(uri)) {
                                    await launchUrl(uri, mode: LaunchMode.externalApplication);
                                  }
                                },
                              ),
                            ],
                          ),
                        ),
                        
                        const SizedBox(height: 24),
                        
                        // --- Section 3: About ---
                        _buildSectionHeader('Acerca de la Aplicación'),
                        const SizedBox(height: 12),
                        Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: slate800,
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: slate700),
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Container(
                                padding: const EdgeInsets.all(10),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF10B981).withValues(alpha: 0.1),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: const Icon(Icons.security, color: Color(0xFF10B981), size: 32),
                              ),
                              const SizedBox(width: 16),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Text(
                                      'Control de Acceso (Acceso)',
                                      style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
                                    ),
                                    const SizedBox(height: 4),
                                    const Text(
                                      'Versión 1.0.0 (Release)',
                                      style: TextStyle(color: slate400, fontSize: 12),
                                    ),
                                    const SizedBox(height: 8),
                                    const Text(
                                      'Desarrollado para la gestión profesional de seguridad, control de visitas pre-autorizadas, listas de restricción y sincronización en tiempo real.',
                                      style: TextStyle(color: slate300, fontSize: 13, height: 1.4),
                                    ),
                                    const SizedBox(height: 12),
                                    Text(
                                      '© ${DateTime.now().year} Operonte. Todos los derechos reservados.',
                                      style: const TextStyle(color: slate400, fontSize: 11),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildSectionHeader(String title) {
    return Text(
      title,
      style: const TextStyle(
        color: Colors.white,
        fontSize: 14,
        fontWeight: FontWeight.bold,
        letterSpacing: 0.5,
      ),
    );
  }

  Widget _buildSecurityCard({required String title, required String description, required bool isSecure}) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: slate800.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: slate700.withValues(alpha: 0.5)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            isSecure ? Icons.check_circle_rounded : Icons.warning_rounded,
            color: isSecure ? const Color(0xFF10B981) : Colors.amber,
            size: 20,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
                ),
                const SizedBox(height: 4),
                Text(
                  description,
                  style: const TextStyle(color: slate400, fontSize: 12, height: 1.4),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTopBanner() {
    if (_activeBannerNotification == null) return const SizedBox.shrink();
    final isAlert = _activeBannerNotification!.type == 'alerta';
    return Positioned(
      top: MediaQuery.of(context).padding.top + 12,
      left: 16,
      right: 16,
      child: Material(
        color: Colors.transparent,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: isAlert ? const Color(0xFFEF4444) : slate900,
            borderRadius: BorderRadius.circular(12),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.3),
                blurRadius: 10,
                offset: const Offset(0, 4),
              )
            ],
            border: Border.all(
              color: isAlert ? Colors.redAccent : slate700,
              width: 1,
            ),
          ),
          child: Row(
            children: [
              Icon(
                isAlert ? Icons.warning_amber_rounded : Icons.notifications_active_rounded,
                color: Colors.white,
                size: 24,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _activeBannerNotification!.title,
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _activeBannerNotification!.body,
                      style: const TextStyle(color: Colors.white70, fontSize: 12),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close, color: Colors.white70, size: 18),
                onPressed: () {
                  ref.read(dashboardProvider.notifier).dismissBannerNotification();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  DateTime _parseImportDate(dynamic val, DateTime defaultDate) {
    if (val == null || val.toString().trim().isEmpty) return defaultDate;
    final clean = val.toString().trim();
    try {
      return DateTime.parse(clean);
    } catch (_) {
      try {
        final parts = clean.split('/');
        if (parts.length == 3) {
          return DateTime(int.parse(parts[2]), int.parse(parts[1]), int.parse(parts[0]));
        }
      } catch (_) {}
      try {
        final parts = clean.split('-');
        if (parts.length == 3) {
          if (parts[0].length == 4) {
            return DateTime(int.parse(parts[0]), int.parse(parts[1]), int.parse(parts[2]));
          } else {
            return DateTime(int.parse(parts[2]), int.parse(parts[1]), int.parse(parts[0]));
          }
        }
      } catch (_) {}
      return defaultDate;
    }
  }

  Future<void> _importPreAuthsCSV() async {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: slate800,
          title: const Row(
            children: [
              Icon(Icons.upload_file_rounded, color: Colors.amber),
              SizedBox(width: 8),
              Text('Importar Pre-Autorizaciones', style: TextStyle(color: Colors.white, fontSize: 18)),
            ],
          ),
          content: const Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'El archivo CSV debe contener las siguientes columnas:',
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
              ),
              SizedBox(height: 8),
              Text(
                '1. Tipo (persona / vehiculo)\n'
                '2. Nombre Completo\n'
                '3. Documento / RUT / ID\n'
                '4. Patente / Placa (opcional)\n'
                '5. Tipo Vehículo (opcional)\n'
                '6. Destino / Unidad / Dpto\n'
                '7. Fecha Inicio (AAAA-MM-DD)\n'
                '8. Fecha Fin (AAAA-MM-DD)',
                style: TextStyle(color: slate400, fontSize: 12, height: 1.5),
              ),
              SizedBox(height: 12),
              Text(
                'Soporta delimitadores de coma (,) y punto y coma (;).',
                style: TextStyle(color: Colors.amber, fontSize: 11, fontStyle: FontStyle.italic),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancelar', style: TextStyle(color: slate400)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.amber.shade700, foregroundColor: Colors.white),
              onPressed: () {
                Navigator.pop(context);
                _pickAndParsePreAuthsCSV();
              },
              child: const Text('Seleccionar Archivo'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _pickAndParsePreAuthsCSV() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['csv'],
      );

      if (result == null || result.files.isEmpty) return;

      final path = result.files.single.path;
      if (path == null) return;

      String csvString;
      try {
        final bytes = await File(path).readAsBytes();
        csvString = utf8.decode(bytes);
      } catch (_) {
        final bytes = await File(path).readAsBytes();
        csvString = latin1.decode(bytes);
      }

      // Auto-detect delimiter
      String delimiter = ',';
      if (csvString.contains(';')) {
        final commaCount = ','.allMatches(csvString).length;
        final semiCount = ';'.allMatches(csvString).length;
        if (semiCount > commaCount) {
          delimiter = ';';
        }
      }

      // Normalize line endings
      csvString = csvString.replaceAll('\r\n', '\n').replaceAll('\r', '\n');

      final converter = CsvDecoder(fieldDelimiter: delimiter);
      final List<List<dynamic>> rows = converter.convert(csvString);

      if (rows.isEmpty) {
        throw Exception('El archivo seleccionado está vacío.');
      }

      // Check header
      int startIndex = 0;
      final firstRowJoin = rows[0].join().toLowerCase();
      if (firstRowJoin.contains('nombre') || firstRowJoin.contains('documento') || firstRowJoin.contains('tipo') || firstRowJoin.contains('rut')) {
        startIndex = 1;
      }

      final List<PreAuthRecord> parsedList = [];
      for (int i = startIndex; i < rows.length; i++) {
        final row = rows[i];
        if (row.length < 3) continue;

        final typeStr = row[0].toString().trim().toLowerCase();
        final type = (typeStr == 'vehiculo' || typeStr == 'vehículo') ? 'vehiculo' : 'persona';
        final name = row[1].toString().trim();
        final docId = row[2].toString().trim();
        
        if (name.isEmpty || docId.isEmpty) continue;

        final plate = row.length > 3 ? row[3].toString().trim() : '';
        final vehicleType = row.length > 4 ? row[4].toString().trim() : '';
        final destination = row.length > 5 ? row[5].toString().trim() : 'General';
        
        final toDate = row.length > 7 
            ? _parseImportDate(row[7], DateTime.now().add(const Duration(days: 365))) 
            : DateTime.now().add(const Duration(days: 365));

        parsedList.add(
          PreAuthRecord(
            id: 'pre_${DateTime.now().millisecondsSinceEpoch}_$i',
            type: type,
            name: name,
            docId: docId,
            plate: plate.isNotEmpty ? plate : null,
            vehicleType: vehicleType.isNotEmpty ? vehicleType : null,
            destination: widget.installationName != null 
                ? '${widget.installationName} | $destination' 
                : destination,
            visitDate: toDate,
            isUsed: false,
          ),
        );
      }

      if (parsedList.isEmpty) {
        throw Exception('No se encontraron registros válidos para importar.');
      }

      if (mounted) {
        _showPreAuthImportPreview(parsedList);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error al importar: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  void _showPreAuthImportPreview(List<PreAuthRecord> records) {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: slate800,
          title: Text('Previsualizar Importación (${records.length})', style: const TextStyle(color: Colors.white, fontSize: 18)),
          content: SizedBox(
            width: double.maxFinite,
            height: MediaQuery.of(context).size.height * 0.4,
            child: ListView.separated(
              itemCount: records.length,
              separatorBuilder: (context, index) => const Divider(color: slate700),
              itemBuilder: (context, index) {
                final rec = records[index];
                return ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: CircleAvatar(
                    backgroundColor: rec.type == 'persona' ? Colors.blue.withValues(alpha: 0.15) : Colors.green.withValues(alpha: 0.15),
                    child: Icon(rec.type == 'persona' ? Icons.person : Icons.directions_car, color: rec.type == 'persona' ? Colors.blue : Colors.green),
                  ),
                  title: Text(rec.name, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14)),
                  subtitle: Text(
                    'Doc: ${rec.docId} | Destino: ${rec.destination}\nFecha Autorizada: ${rec.visitDate.day}/${rec.visitDate.month}/${rec.visitDate.year}',
                    style: const TextStyle(color: slate400, fontSize: 11),
                  ),
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancelar', style: TextStyle(color: slate400)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF10B981), foregroundColor: Colors.white),
              onPressed: () async {
                Navigator.pop(context);
                for (var rec in records) {
                  await _preAuthBox.put(rec.id, rec.toMap());
                }
                _refreshUILists();
                _addNotification(
                  type: 'sync',
                  title: 'Importación Exitosa',
                  body: 'Se importaron ${records.length} pre-autorizaciones desde CSV.',
                );
                SupabaseSyncManager.syncAll();
              },
              child: const Text('Confirmar e Importar'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _importBlacklistCSV() async {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: slate800,
          title: const Row(
            children: [
              Icon(Icons.upload_file_rounded, color: Colors.redAccent),
              SizedBox(width: 8),
              Text('Importar Lista Negra', style: TextStyle(color: Colors.white, fontSize: 18)),
            ],
          ),
          content: const Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'El archivo CSV debe contener las siguientes columnas:',
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
              ),
              SizedBox(height: 8),
              Text(
                '1. Tipo (persona / vehiculo)\n'
                '2. Nombre Completo / Descripción\n'
                '3. Identificador (RUT / Placa / Patente)\n'
                '4. Motivo / Razón de Restricción',
                style: TextStyle(color: slate400, fontSize: 12, height: 1.5),
              ),
              SizedBox(height: 12),
              Text(
                'Soporta delimitadores de coma (,) y punto y coma (;).',
                style: TextStyle(color: Colors.redAccent, fontSize: 11, fontStyle: FontStyle.italic),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancelar', style: TextStyle(color: slate400)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent, foregroundColor: Colors.white),
              onPressed: () {
                Navigator.pop(context);
                _pickAndParseBlacklistCSV();
              },
              child: const Text('Seleccionar Archivo'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _pickAndParseBlacklistCSV() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['csv'],
      );

      if (result == null || result.files.isEmpty) return;

      final path = result.files.single.path;
      if (path == null) return;

      String csvString;
      try {
        final bytes = await File(path).readAsBytes();
        csvString = utf8.decode(bytes);
      } catch (_) {
        final bytes = await File(path).readAsBytes();
        csvString = latin1.decode(bytes);
      }

      // Auto-detect delimiter
      String delimiter = ',';
      if (csvString.contains(';')) {
        final commaCount = ','.allMatches(csvString).length;
        final semiCount = ';'.allMatches(csvString).length;
        if (semiCount > commaCount) {
          delimiter = ';';
        }
      }

      // Normalize line endings
      csvString = csvString.replaceAll('\r\n', '\n').replaceAll('\r', '\n');

      final converter = CsvDecoder(fieldDelimiter: delimiter);
      final List<List<dynamic>> rows = converter.convert(csvString);

      if (rows.isEmpty) {
        throw Exception('El archivo seleccionado está vacío.');
      }

      // Check header
      int startIndex = 0;
      final firstRowJoin = rows[0].join().toLowerCase();
      if (firstRowJoin.contains('nombre') || firstRowJoin.contains('identificador') || firstRowJoin.contains('tipo') || firstRowJoin.contains('motivo')) {
        startIndex = 1;
      }

      final List<BlacklistEntry> parsedList = [];
      for (int i = startIndex; i < rows.length; i++) {
        final row = rows[i];
        if (row.length < 3) continue;

        final typeStr = row[0].toString().trim().toLowerCase();
        final type = (typeStr == 'vehiculo' || typeStr == 'vehículo') ? 'vehiculo' : 'persona';
        final name = row[1].toString().trim();
        final identifier = row[2].toString().trim();
        final reason = row.length > 3 ? row[3].toString().trim() : 'Sin motivo especificado';

        if (name.isEmpty || identifier.isEmpty) continue;

        parsedList.add(
          BlacklistEntry(
            id: 'bl_${DateTime.now().millisecondsSinceEpoch}_$i',
            type: type,
            name: name,
            identifier: identifier,
            reason: widget.installationName != null 
                ? '${widget.installationName} | $reason' 
                : reason,
            createdAt: DateTime.now(),
          ),
        );
      }

      if (parsedList.isEmpty) {
        throw Exception('No se encontraron registros válidos de lista negra.');
      }

      if (mounted) {
        _showBlacklistImportPreview(parsedList);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error al importar: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  void _showBlacklistImportPreview(List<BlacklistEntry> entries) {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: slate800,
          title: Text('Previsualizar Importación (${entries.length})', style: const TextStyle(color: Colors.white, fontSize: 18)),
          content: SizedBox(
            width: double.maxFinite,
            height: MediaQuery.of(context).size.height * 0.4,
            child: ListView.separated(
              itemCount: entries.length,
              separatorBuilder: (context, index) => const Divider(color: slate700),
              itemBuilder: (context, index) {
                final entry = entries[index];
                return ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: CircleAvatar(
                    backgroundColor: Colors.red.withValues(alpha: 0.15),
                    child: Icon(entry.type == 'persona' ? Icons.person : Icons.directions_car, color: Colors.red),
                  ),
                  title: Text(entry.name, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14)),
                  subtitle: Text(
                    'Identificador: ${entry.identifier}\nMotivo: ${entry.reason}',
                    style: const TextStyle(color: slate400, fontSize: 11),
                  ),
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancelar', style: TextStyle(color: slate400)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent, foregroundColor: Colors.white),
              onPressed: () async {
                Navigator.pop(context);
                for (var entry in entries) {
                  await _blacklistBox.put(entry.id, entry.toMap());
                }
                _refreshUILists();
                _addNotification(
                  type: 'alerta',
                  title: 'Importación de Lista Negra',
                  body: 'Se importaron ${entries.length} registros a la Lista Negra.',
                );
                SupabaseSyncManager.syncAll();
              },
              child: const Text('Confirmar e Importar'),
            ),
          ],
        );
      },
    );
  }

  // --- Rendering UI Tabs ---

  @override
  Widget build(BuildContext context) {
    ref.watch(dashboardProvider);
    final maxIndex = _getNavBarItems().length - 1;
    if (_currentTabIndex > maxIndex) {
      _currentTabIndex = maxIndex;
    }
    return Scaffold(
      // --- Top Title Bar ---
      appBar: AppBar(
        backgroundColor: slate800,
        elevation: 0,
        automaticallyImplyLeading: false,
        leading: ValueListenableBuilder<bool>(
          valueListenable: SupabaseSyncManager.isOnline,
          builder: (context, isOnline, child) {
            return ValueListenableBuilder<bool>(
              valueListenable: SupabaseSyncManager.isSyncing,
              builder: (context, isSyncing, child) {
                return IconButton(
                  constraints: const BoxConstraints(minWidth: 38, minHeight: 38),
                  padding: EdgeInsets.zero,
                  tooltip: isOnline 
                      ? (isSyncing ? 'Sincronizando...' : 'Nube conectada & sincronizada')
                      : 'Modo Offline - Guardado local',
                  icon: isSyncing
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2.5, color: Color(0xFF10B981)),
                        )
                      : Icon(
                          isOnline ? Icons.cloud_done_rounded : Icons.cloud_off_rounded,
                          size: 22,
                          color: isOnline ? const Color(0xFF10B981) : Colors.orangeAccent,
                        ),
                  onPressed: () => SupabaseSyncManager.syncAll(),
                );
              },
            );
          },
        ),
        titleSpacing: 4,
        title: Row(
          children: [
            const Icon(Icons.security, color: Color(0xFF10B981), size: 18),
            const SizedBox(width: 6),
            const Text(
              'CONTROL ACCESO',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.white, letterSpacing: 0.5),
            ),
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
              decoration: BoxDecoration(
                color: widget.userRole == UserRole.admin
                    ? Colors.redAccent.withValues(alpha: 0.2)
                    : const Color(0xFF10B981).withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(
                  color: widget.userRole == UserRole.admin
                      ? Colors.redAccent.withValues(alpha: 0.5)
                      : const Color(0xFF10B981).withValues(alpha: 0.5),
                ),
              ),
              child: Text(
                widget.userRole == UserRole.admin
                    ? 'ADMIN'
                    : (widget.userRole == UserRole.guardia ? 'GUARDIA' : 'CLIENTE'),
                style: TextStyle(
                  fontSize: 9,
                  fontWeight: FontWeight.bold,
                  color: widget.userRole == UserRole.admin
                      ? Colors.redAccent
                      : const Color(0xFF10B981),
                ),
              ),
            ),
          ],
        ),
        actions: [

          // Notifications button
          Stack(
            alignment: Alignment.center,
            children: [
              IconButton(
                constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
                padding: const EdgeInsets.all(4),
                tooltip: 'Notificaciones',
                icon: const Icon(Icons.notifications_rounded, color: Colors.white, size: 20),
                onPressed: _showNotificationsModal,
              ),
              if (_notifications.any((n) => !n.isRead))
                Positioned(
                  top: 6,
                  right: 6,
                  child: Container(
                    width: 7,
                    height: 7,
                    decoration: const BoxDecoration(
                      color: Colors.redAccent,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
            ],
          ),

          // Settings button
          IconButton(
            constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
            padding: const EdgeInsets.all(4),
            tooltip: 'Configuración',
            icon: const Icon(Icons.settings_rounded, color: slate400, size: 20),
            onPressed: _showSettingsModal,
          ),

          // Logout button
          IconButton(
            constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
            padding: const EdgeInsets.all(4),
            tooltip: 'Cerrar Sesión',
            icon: const Icon(Icons.logout_rounded, color: slate400, size: 20),
            onPressed: () async {
              final sessionBox = Hive.box('session_box');
              await sessionBox.clear();
              if (context.mounted) {
                Navigator.pushReplacementNamed(context, '/');
              }
            },
          ),
          const SizedBox(width: 4),
        ],
      ),

      // --- Body switching tabs ---
      body: Stack(
        children: [
          _buildBody(),
          _buildTopBanner(),
        ],
      ),

      // --- QR Floating Action Button ---
      floatingActionButton: widget.userRole == UserRole.cliente
          ? null
          : FloatingActionButton.extended(
              backgroundColor: const Color(0xFF10B981),
              foregroundColor: Colors.white,
              icon: const Icon(Icons.qr_code_scanner),
              label: const Text('Escanear QR', style: TextStyle(fontWeight: FontWeight.bold)),
              onPressed: _openCameraScanner,
            ),

      // --- Bottom Navigation Menu ---
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentTabIndex,
        type: BottomNavigationBarType.fixed,
        onTap: (index) {
          setState(() {
            _currentTabIndex = index;
          });
        },
        backgroundColor: slate800,
        selectedItemColor: const Color(0xFF10B981),
        unselectedItemColor: slate400,
        selectedLabelStyle: const TextStyle(fontWeight: FontWeight.bold),
        items: _getNavBarItems(),
      ),
    );
  }

  // --- Helper Methods for Role-based UI ---

  List<BottomNavigationBarItem> _getNavBarItems() {
    final List<BottomNavigationBarItem> items = [
      const BottomNavigationBarItem(
        icon: Icon(Icons.dashboard_customize_rounded),
        label: 'Monitoreo',
      ),
      const BottomNavigationBarItem(
        icon: Icon(Icons.event_available_rounded),
        label: 'Pre-autorizaciones',
      ),
      const BottomNavigationBarItem(
        icon: Icon(Icons.block_flipped),
        label: 'Lista Negra',
      ),
      const BottomNavigationBarItem(
        icon: Icon(Icons.verified_user_rounded),
        label: 'Lista Blanca',
      ),
    ];
    if (widget.userRole == UserRole.admin) {
      items.add(const BottomNavigationBarItem(
        icon: Icon(Icons.business_rounded),
        label: 'Instalaciones',
      ));
    }
    return items;
  }

  Widget _buildBody() {
    if (_currentTabIndex == 0) {
      return _buildMonitoreoTab();
    } else if (_currentTabIndex == 1) {
      return _buildPreAuthTab();
    } else if (_currentTabIndex == 2) {
      return _buildBlacklistTab();
    } else if (_currentTabIndex == 3) {
      return _buildWhitelistTab();
    } else if (_currentTabIndex == 4 && widget.userRole == UserRole.admin) {
      return _buildInstallationsTab();
    }
    return _buildMonitoreoTab();
  }

  Widget _buildCompactStatsSummary() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: slate900,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: slate700.withValues(alpha: 0.5)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _buildStatSummaryItem('Personas', '$_peopleInsideCount', Icons.person_rounded, const Color(0xFF10B981)),
          Container(width: 1, height: 24, color: slate700),
          _buildStatSummaryItem('Vehículos', '$_vehiclesInsideCount', Icons.directions_car_rounded, const Color(0xFF3B82F6)),
          if (_trucksInsideCount > 0) ...[
            Container(width: 1, height: 24, color: slate700),
            _buildStatSummaryItem('Camiones', '$_trucksInsideCount', Icons.local_shipping_rounded, Colors.orangeAccent),
          ],
          if (_motosInsideCount > 0) ...[
            Container(width: 1, height: 24, color: slate700),
            _buildStatSummaryItem('Motos', '$_motosInsideCount', Icons.two_wheeler_rounded, Colors.purpleAccent),
          ],
          if (_bikesInsideCount > 0) ...[
            Container(width: 1, height: 24, color: slate700),
            _buildStatSummaryItem('Bicis', '$_bikesInsideCount', Icons.pedal_bike_rounded, Colors.tealAccent),
          ],
        ],
      ),
    );
  }

  Widget _buildStatSummaryItem(String label, String value, IconData icon, Color color) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 6),
        Text(value, style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: color)),
        const SizedBox(width: 4),
        Text(label, style: const TextStyle(fontSize: 11, color: slate400)),
      ],
    );
  }

  Widget _buildPeakHoursChart() {
    final brackets = <String, int>{
      '00-04h': 0,
      '04-08h': 0,
      '08-12h': 0,
      '12-16h': 0,
      '16-20h': 0,
      '20-24h': 0,
    };

    int maxCount = 0;
    String peakBracket = '';

    for (final r in _records) {
      final hour = r.entryTime.hour;
      String key = '20-24h';
      if (hour >= 0 && hour < 4) {
        key = '00-04h';
      } else if (hour >= 4 && hour < 8) {
        key = '04-08h';
      } else if (hour >= 8 && hour < 12) {
        key = '08-12h';
      } else if (hour >= 12 && hour < 16) {
        key = '12-16h';
      } else if (hour >= 16 && hour < 20) {
        key = '16-20h';
      }

      brackets[key] = (brackets[key] ?? 0) + 1;
      if (brackets[key]! > maxCount) {
        maxCount = brackets[key]!;
        peakBracket = key;
      }
    }

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: slate800,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF10B981).withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.bar_chart_rounded, color: Color(0xFF10B981), size: 22),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'Distribución de Tráfico por Horario (Exclusivo Admin)',
                  style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold),
                ),
              ),
              if (peakBracket.isNotEmpty && maxCount > 0)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.amber.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.amber),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.local_fire_department_rounded, color: Colors.amber, size: 14),
                      const SizedBox(width: 4),
                      Text(
                        'Pico: $peakBracket ($maxCount)',
                        style: const TextStyle(color: Colors.amber, fontSize: 11, fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: brackets.entries.map((e) {
              final isPeak = e.key == peakBracket && maxCount > 0;
              final double heightRatio = maxCount > 0 ? (e.value / maxCount) : 0.0;
              final barHeight = (heightRatio * 50).clamp(6.0, 50.0);

              return Column(
                children: [
                  Text(
                    '${e.value}',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      color: isPeak ? Colors.amber : Colors.white70,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Container(
                    width: 26,
                    height: barHeight,
                    decoration: BoxDecoration(
                      color: isPeak ? Colors.amber : const Color(0xFF10B981),
                      borderRadius: const BorderRadius.vertical(top: Radius.circular(6)),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    e.key,
                    style: TextStyle(
                      fontSize: 10,
                      color: isPeak ? Colors.amber : slate400,
                      fontWeight: isPeak ? FontWeight.bold : FontWeight.normal,
                    ),
                  ),
                ],
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  // --- Monitoreo Tab UI ---
  Widget _buildMonitoreoTab() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Peak Hours Chart for Admin
        if (widget.userRole == UserRole.admin)
          _buildPeakHoursChart(),
        // 1. Sleek Compact Header & Action Row
        Container(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          color: slate800,
          child: Column(
            children: [
              _buildCompactStatsSummary(),
              if (widget.userRole != UserRole.cliente) ...[
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF10B981).withValues(alpha: 0.15),
                          foregroundColor: const Color(0xFF10B981),
                          side: const BorderSide(color: Color(0xFF10B981), width: 1.5),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                        icon: const Icon(Icons.person_add_alt_1_rounded, size: 20),
                        label: const Text('Ingreso Persona', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                        onPressed: () => _showNewEntryModal('persona'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF3B82F6).withValues(alpha: 0.15),
                          foregroundColor: const Color(0xFF3B82F6),
                          side: const BorderSide(color: Color(0xFF3B82F6), width: 1.5),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                        icon: const Icon(Icons.directions_car_rounded, size: 20),
                        label: const Text('Ingreso Vehículo', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                        onPressed: () => _showNewEntryModal('vehiculo'),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
        // Active Installation Filter Banner for Admin
        if (_selectedAdminInstallation != null)
          Container(
            color: const Color(0xFF10B981).withValues(alpha: 0.15),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                const Icon(Icons.business_rounded, color: Color(0xFF10B981), size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Instalación: $_selectedAdminInstallation',
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
                  ),
                ),
                InkWell(
                  onTap: () => setState(() => _selectedAdminInstallation = null),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: slate800,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('Ver Todas', style: TextStyle(color: slate400, fontSize: 11)),
                        SizedBox(width: 4),
                        Icon(Icons.close, size: 14, color: slate400),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),

        // 2. Navigation Switch and Filter Controls
        Container(
          color: slate900,
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: GestureDetector(
                      onTap: () => setState(() => _selectedView = 'dentro'),
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        decoration: BoxDecoration(
                          border: Border(
                            bottom: BorderSide(
                              color: _selectedView == 'dentro' ? const Color(0xFF10B981) : Colors.transparent,
                              width: 3,
                            ),
                          ),
                        ),
                        child: Text(
                          'EN EL RECINTO',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                            color: _selectedView == 'dentro' ? Colors.white : slate400,
                          ),
                        ),
                      ),
                    ),
                  ),
                  Expanded(
                    child: GestureDetector(
                      onTap: () => setState(() => _selectedView = 'salieron'),
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        decoration: BoxDecoration(
                          border: Border(
                            bottom: BorderSide(
                              color: _selectedView == 'salieron' ? const Color(0xFF10B981) : Colors.transparent,
                              width: 3,
                            ),
                          ),
                        ),
                        child: Text(
                          'SALIERON',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                            color: _selectedView == 'salieron' ? Colors.white : slate400,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),

              // Search Bar + Sort Action + Date Filter Action + Export Action
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _searchController,
                      decoration: InputDecoration(
                        hintText: 'Buscar',
                        prefixIcon: const Icon(Icons.search, color: slate400),
                        suffixIcon: _searchQuery.isNotEmpty
                            ? IconButton(
                                icon: const Icon(Icons.clear, color: slate400),
                                onPressed: () {
                                  _searchController.clear();
                                  setState(() => _searchQuery = '');
                                },
                              )
                            : null,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(color: slate700),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(color: slate700),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(color: Color(0xFF10B981), width: 1.5),
                        ),
                        filled: true,
                        fillColor: slate800,
                        contentPadding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                      onChanged: (val) {
                        setState(() {
                          _searchQuery = val;
                        });
                      },
                    ),
                  ),
                  const SizedBox(width: 8),

                  // Single Toggle Sort Button (Arrow Down / A-Z)
                  IconButton.filled(
                    style: IconButton.styleFrom(
                      backgroundColor: slate800,
                      foregroundColor: const Color(0xFF10B981),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      padding: const EdgeInsets.all(12),
                    ),
                    icon: Icon(
                      _sortOption == 'hora_desc' ? Icons.arrow_downward_rounded : Icons.sort_by_alpha_rounded,
                      size: 20,
                    ),
                    tooltip: _sortOption == 'hora_desc' ? 'Orden: Fecha y Hora (Más reciente)' : 'Orden: Alfabético (A-Z)',
                    onPressed: () {
                      setState(() {
                        _sortOption = _sortOption == 'hora_desc' ? 'az' : 'hora_desc';
                      });
                    },
                  ),
                  const SizedBox(width: 8),

                  // Date Filter Button
                  IconButton.filled(
                    style: IconButton.styleFrom(
                      backgroundColor: _selectedDateRange != null ? const Color(0xFF10B981).withValues(alpha: 0.2) : slate800,
                      foregroundColor: _selectedDateRange != null ? const Color(0xFF10B981) : slate400,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      padding: const EdgeInsets.all(12),
                    ),
                    icon: Icon(
                      _selectedDateRange != null ? Icons.calendar_today_rounded : Icons.calendar_month_rounded,
                      size: 20,
                    ),
                    tooltip: _selectedDateRange != null ? 'Filtro Fecha Activo (Toca para quitar)' : 'Filtrar por Fecha',
                    onPressed: () {
                      if (_selectedDateRange != null) {
                        setState(() {
                          _selectedDateRange = null;
                        });
                      } else {
                        _selectDateRange();
                      }
                    },
                  ),
                  const SizedBox(width: 8),

                  // Export button
                  if (widget.userRole == UserRole.admin)
                    IconButton.filled(
                      style: IconButton.styleFrom(
                        backgroundColor: slate800,
                        foregroundColor: const Color(0xFF10B981),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        padding: const EdgeInsets.all(12),
                      ),
                      icon: const Icon(Icons.file_download_rounded, size: 20),
                      tooltip: 'Exportar CSV',
                      onPressed: _exportHistoryToCSV,
                    ),
                ],
              ),
              const SizedBox(height: 12),

              // Filter Chips
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    _buildFilterChip('todos', label: 'Todos'),
                    const SizedBox(width: 8),
                    _buildFilterChip('a_pie', icon: Icons.directions_walk, tooltip: 'A pie'),
                    const SizedBox(width: 8),
                    _buildFilterChip('vehiculos', icon: Icons.directions_car, tooltip: 'Vehículos'),
                    const SizedBox(width: 8),
                    _buildFilterChip('moto', icon: Icons.two_wheeler, tooltip: 'Moto'),
                    const SizedBox(width: 8),
                    _buildFilterChip('camion', icon: Icons.local_shipping, tooltip: 'Camión'),
                    const SizedBox(width: 8),
                    _buildFilterChip('bicicleta', icon: Icons.pedal_bike, tooltip: 'Bicicleta'),
                    if (_selectedDateRange != null) ...[
                      const SizedBox(width: 12),
                      ActionChip(
                        avatar: const Icon(Icons.close, size: 14, color: Color(0xFF10B981)),
                        label: Text(
                          '${_selectedDateRange!.start.day}/${_selectedDateRange!.start.month} - ${_selectedDateRange!.end.day}/${_selectedDateRange!.end.month}',
                          style: const TextStyle(fontSize: 11, color: Color(0xFF10B981), fontWeight: FontWeight.bold),
                        ),
                        backgroundColor: const Color(0xFF10B981).withValues(alpha: 0.15),
                        side: const BorderSide(color: Color(0xFF10B981)),
                        onPressed: () => setState(() => _selectedDateRange = null),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),

        // Batch Exit Toolbar (WhatsApp style multi-selection)
        if (_isSelectionMode)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              color: const Color(0xFF10B981).withValues(alpha: 0.2),
              border: const Border(bottom: BorderSide(color: Color(0xFF10B981), width: 1.5)),
            ),
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.close, color: Colors.white, size: 20),
                  tooltip: 'Cancelar Selección',
                  onPressed: () {
                    setState(() {
                      _isSelectionMode = false;
                      _selectedRecordIds.clear();
                    });
                  },
                ),
                const SizedBox(width: 4),
                Text(
                  '${_selectedRecordIds.length} seleccionados',
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
                ),
                const Spacer(),
                TextButton(
                  onPressed: () {
                    setState(() {
                      _selectedRecordIds.clear();
                      for (final r in _filteredRecords) {
                        if (r.isInside) _selectedRecordIds.add(r.id);
                      }
                    });
                  },
                  child: const Text('Todos', style: TextStyle(color: Color(0xFF10B981), fontWeight: FontWeight.bold, fontSize: 12)),
                ),
                const SizedBox(width: 6),
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF10B981),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  icon: const Icon(Icons.logout_rounded, size: 16),
                  label: Text('Salida Masiva (${_selectedRecordIds.length})', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                  onPressed: _performBatchExit,
                ),
              ],
            ),
          ),

        // 3. Records List View
        Expanded(
          child: _filteredRecords.isEmpty
              ? _buildEmptyState(_searchQuery.isNotEmpty, 'Monitoreo')
              : ListView.builder(
                  padding: const EdgeInsets.only(left: 16, right: 16, top: 8, bottom: 80),
                  itemCount: _filteredRecords.length,
                  itemBuilder: (context, index) {
                    return _buildRecordCard(_filteredRecords[index]);
                  },
                ),
        ),
      ],
    );
  }

  // --- Pre-authorizations Tab UI ---
  Widget _buildPreAuthTab() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 1. Calendar/Agenda Header
        Container(
          padding: const EdgeInsets.all(16),
          color: slate800,
          child: Row(
            children: [
              const Icon(Icons.calendar_month, color: Colors.amber, size: 40),
              const SizedBox(width: 12),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Visitas Agendadas',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white),
                    ),
                    Text(
                      'Agende visitas para hoy o fechas futuras',
                      style: TextStyle(fontSize: 12, color: slate400),
                    ),
                  ],
                ),
              ),
              if (widget.userRole != UserRole.guardia) ...[
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.amber.shade700,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  ),
                  icon: const Icon(Icons.add_task),
                  label: const Text('Agendar', style: TextStyle(fontWeight: FontWeight.bold)),
                  onPressed: _showNewPreAuthModal,
                ),
              ],
              if (widget.userRole == UserRole.admin) ...[
                const SizedBox(width: 8),
                IconButton(
                  tooltip: 'Importar Pre-Autorizaciones (CSV)',
                  icon: const Icon(Icons.upload_file_rounded, color: Colors.amber),
                  onPressed: _importPreAuthsCSV,
                ),
              ],
            ],
          ),
        ),

        // 2. Search and filter Pre-authorizations
        Container(
          color: slate900,
          padding: const EdgeInsets.all(16),
          child: TextField(
            controller: _preAuthSearchController,
            decoration: InputDecoration(
              hintText: 'Buscar en visitas programadas...',
              prefixIcon: const Icon(Icons.search, color: slate400),
              suffixIcon: _preAuthSearchQuery.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear, color: slate400),
                      onPressed: () {
                        _preAuthSearchController.clear();
                        setState(() => _preAuthSearchQuery = '');
                      },
                    )
                  : null,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: slate700),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: slate700),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: Colors.amber, width: 1.5),
              ),
              filled: true,
              fillColor: slate800,
              contentPadding: const EdgeInsets.symmetric(vertical: 12),
            ),
            onChanged: (val) {
              setState(() {
                _preAuthSearchQuery = val;
              });
            },
          ),
        ),

        // 3. Pre-authorizations List View
        Expanded(
          child: _filteredPreAuths.isEmpty
              ? _buildEmptyState(_preAuthSearchQuery.isNotEmpty, 'PreAuth')
              : ListView.builder(
                  padding: const EdgeInsets.only(left: 16, right: 16, top: 8, bottom: 80),
                  itemCount: _filteredPreAuths.length,
                  itemBuilder: (context, index) {
                    return _buildPreAuthCard(_filteredPreAuths[index]);
                  },
                ),
        ),
      ],
    );
  }

  // --- Sub-widgets and Helpers ---

  Widget _buildStatCard({
    required String title,
    required String value,
    required IconData icon,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: slate900,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withValues(alpha: 0.3), width: 1),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.1),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: color, size: 24),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  value,
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: color),
                ),
                Text(
                  title,
                  style: const TextStyle(fontSize: 12, color: slate400),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          )
        ],
      ),
    );
  }

  Widget _buildFilterChip(String value, {String? label, IconData? icon, String? tooltip}) {
    final isSelected = _filterType == value;
    final content = label != null 
        ? Text(label) 
        : Icon(icon, color: isSelected ? Colors.white : slate400, size: 20);

    final chip = ChoiceChip(
      label: content,
      showCheckmark: false,
      selected: isSelected,
      onSelected: (selected) {
        if (selected) {
          setState(() {
            _filterType = value;
          });
        }
      },
      backgroundColor: slate800,
      selectedColor: const Color(0xFF10B981),
      labelStyle: TextStyle(
        color: isSelected ? Colors.white : slate400,
        fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    );
    return tooltip != null ? Tooltip(message: tooltip, child: chip) : chip;
  }

  void _showPhotoDialog(String photoPath) {
    showDialog(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: Colors.transparent,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: photoPath.startsWith('http')
                  ? Image.network(
                      photoPath,
                      fit: BoxFit.contain,
                      errorBuilder: (context, error, stackTrace) => Container(
                        padding: const EdgeInsets.all(24),
                        color: slate800,
                        child: const Icon(Icons.broken_image, color: slate400, size: 48),
                      ),
                    )
                  : Image.file(
                      File(photoPath),
                      fit: BoxFit.contain,
                      errorBuilder: (context, error, stackTrace) => Container(
                        padding: const EdgeInsets.all(24),
                        color: slate800,
                        child: const Icon(Icons.broken_image, color: slate400, size: 48),
                      ),
                    ),
            ),
            const SizedBox(height: 12),
            IconButton(
              icon: const Icon(Icons.close, color: Colors.white, size: 30),
              onPressed: () => Navigator.pop(context),
            )
          ],
        ),
      ),
    );
  }

  // Access log card render
  Widget _buildRecordCard(AccessRecord record) {
    final isVehicle = record.type == 'vehiculo';
    final cardAccentColor = isVehicle ? const Color(0xFF3B82F6) : const Color(0xFF10B981);
    final isSelected = _selectedRecordIds.contains(record.id);

    return GestureDetector(
      onLongPress: () {
        if (record.isInside) {
          setState(() {
            _isSelectionMode = true;
            if (isSelected) {
              _selectedRecordIds.remove(record.id);
              if (_selectedRecordIds.isEmpty) _isSelectionMode = false;
            } else {
              _selectedRecordIds.add(record.id);
            }
          });
        }
      },
      onTap: () {
        if (_isSelectionMode) {
          if (record.isInside) {
            setState(() {
              if (isSelected) {
                _selectedRecordIds.remove(record.id);
                if (_selectedRecordIds.isEmpty) _isSelectionMode = false;
              } else {
                _selectedRecordIds.add(record.id);
              }
            });
          }
        } else {
          _showRecordDetailsModal(record);
        }
      },
      child: Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: isSelected ? const Color(0xFF10B981).withValues(alpha: 0.15) : slate800,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isSelected 
              ? const Color(0xFF10B981) 
              : (record.isInside ? cardAccentColor.withValues(alpha: 0.2) : Colors.transparent),
          width: isSelected ? 2 : 1,
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_isSelectionMode && record.isInside)
                Padding(
                  padding: const EdgeInsets.only(left: 12),
                  child: Center(
                    child: Icon(
                      isSelected ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
                      color: isSelected ? const Color(0xFF10B981) : slate400,
                      size: 24,
                    ),
                  ),
                ),
              Container(
                width: 6,
                color: record.isInside ? cardAccentColor : slate600,
              ),
              const SizedBox(width: 12),

              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            isVehicle ? Icons.directions_car_rounded : Icons.person_rounded,
                            size: 16,
                            color: cardAccentColor,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            isVehicle ? 'VEHÍCULO' : 'PERSONA',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                              color: cardAccentColor,
                              letterSpacing: 0.5,
                            ),
                          ),
                          const Spacer(),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              color: record.isInside ? const Color(0xFF10B981).withValues(alpha: 0.15) : slate900,
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(color: record.isInside ? const Color(0xFF10B981).withValues(alpha: 0.4) : slate700),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.timer_outlined, size: 12, color: record.isInside ? const Color(0xFF10B981) : slate400),
                                const SizedBox(width: 4),
                                Text(
                                  record.isInside ? 'En recinto: ${record.durationText}' : 'Permanencia: ${record.durationText}',
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                    color: record.isInside ? const Color(0xFF10B981) : slate300,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),

                      Text(
                        record.name,
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
                      ),
                      const SizedBox(height: 4),

                      Text(
                        'RUT/DNI: ${record.docId}',
                        style: const TextStyle(fontSize: 12, color: slate400),
                      ),
                      const SizedBox(height: 6),

                      if (isVehicle && record.plate != null) ...[
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: slate900,
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: slate800),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.tag, size: 12, color: Colors.orangeAccent),
                              const SizedBox(width: 4),
                              Text(
                                record.plate!,
                                style: const TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.orangeAccent,
                                  letterSpacing: 1.0,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                record.vehicleType ?? '',
                                style: const TextStyle(fontSize: 11, color: slate400),
                              )
                            ],
                          ),
                        ),
                        const SizedBox(height: 6),
                      ],

                      Row(
                        children: [
                          const Icon(Icons.location_on, size: 14, color: Colors.redAccent),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              _displayDestination(record.destination),
                              style: const TextStyle(fontSize: 13, color: slate300),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),

                      if (record.phone != null && record.phone!.trim().isNotEmpty) ...[
                        Row(
                          children: [
                            const Icon(Icons.phone_android_rounded, size: 14, color: Color(0xFF10B981)),
                            const SizedBox(width: 4),
                            Text(
                              record.phone!,
                              style: const TextStyle(fontSize: 12, color: Colors.white, fontWeight: FontWeight.bold),
                            ),
                            const Spacer(),
                            // Call button
                            InkWell(
                              onTap: () async {
                                final cleanPhone = record.phone!.replaceAll(RegExp(r'[^0-9+]'), '');
                                final url = Uri.parse('tel:$cleanPhone');
                                if (await canLaunchUrl(url)) {
                                  await launchUrl(url);
                                }
                              },
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF10B981).withValues(alpha: 0.2),
                                  borderRadius: BorderRadius.circular(6),
                                  border: Border.all(color: const Color(0xFF10B981).withValues(alpha: 0.5)),
                                ),
                                child: const Row(
                                  children: [
                                    Icon(Icons.call, size: 12, color: Color(0xFF10B981)),
                                    SizedBox(width: 4),
                                    Text('Llamar', style: TextStyle(fontSize: 11, color: Color(0xFF10B981), fontWeight: FontWeight.bold)),
                                  ],
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            // WhatsApp button
                            InkWell(
                              onTap: () async {
                                final cleanPhone = record.phone!.replaceAll(RegExp(r'[^0-9]'), '');
                                final url = Uri.parse('https://wa.me/$cleanPhone');
                                if (await canLaunchUrl(url)) {
                                  await launchUrl(url, mode: LaunchMode.externalApplication);
                                }
                              },
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF25D366).withValues(alpha: 0.2),
                                  borderRadius: BorderRadius.circular(6),
                                  border: Border.all(color: const Color(0xFF25D366).withValues(alpha: 0.5)),
                                ),
                                child: const Row(
                                  children: [
                                    Icon(Icons.chat_bubble_rounded, size: 12, color: Color(0xFF25D366)),
                                    SizedBox(width: 4),
                                    Text('WhatsApp', style: TextStyle(fontSize: 11, color: Color(0xFF25D366), fontWeight: FontWeight.bold)),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                      ],

                      Row(
                        children: [
                          const Icon(Icons.login, size: 12, color: slate400),
                          const SizedBox(width: 4),
                          Text(
                            'Ingreso: ${_formatTime(record.entryTime)}',
                            style: const TextStyle(fontSize: 11, color: slate400),
                          ),
                          if (record.exitTime != null) ...[
                            const SizedBox(width: 12),
                            const Icon(Icons.logout, size: 12, color: slate400),
                            const SizedBox(width: 4),
                            Text(
                              'Salida: ${_formatTime(record.exitTime!)}',
                              style: const TextStyle(fontSize: 11, color: slate400),
                            ),
                          ]
                        ],
                      ),
                    ],
                  ),
                ),
              ),

              if (record.photoPath != null)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Center(
                    child: InkWell(
                      onTap: () => _showPhotoDialog(record.photoPath!),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: record.photoPath!.startsWith('http')
                            ? Image.network(
                                record.photoPath!,
                                width: 44,
                                height: 44,
                                fit: BoxFit.cover,
                                errorBuilder: (context, error, stackTrace) => const Icon(Icons.broken_image, color: slate400, size: 20),
                              )
                            : Image.file(
                                File(record.photoPath!),
                                width: 44,
                                height: 44,
                                fit: BoxFit.cover,
                                errorBuilder: (context, error, stackTrace) => const Icon(Icons.broken_image, color: slate400, size: 20),
                              ),
                      ),
                    ),
                  ),
                ),

              if (record.isInside && widget.userRole != UserRole.cliente)
                InkWell(
                  onTap: () => _checkoutRecord(record),
                  child: Container(
                    width: 70,
                    color: Colors.blueAccent.withValues(alpha: 0.1),
                    child: const Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.logout_rounded, color: Colors.blueAccent, size: 24),
                        SizedBox(height: 4),
                        Text(
                          'Salida',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            color: Colors.blueAccent,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    ),
  );
}

  // Pre-authorization card render
  Widget _buildPreAuthCard(PreAuthRecord pre) {
    final isVehicle = pre.type == 'vehiculo';
    final cardAccentColor = isVehicle ? const Color(0xFF3B82F6) : const Color(0xFF10B981);
    final visitDateStr = '${pre.visitDate.day}/${pre.visitDate.month}/${pre.visitDate.year}';
    
    // Check if it's today's visit
    final bool isToday = pre.visitDate.year == DateTime.now().year &&
        pre.visitDate.month == DateTime.now().month &&
        pre.visitDate.day == DateTime.now().day;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: slate800,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isToday ? Colors.amber.withValues(alpha: 0.2) : Colors.transparent,
          width: 1,
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                width: 6,
                color: isToday ? Colors.amber : cardAccentColor.withValues(alpha: 0.6),
              ),
              const SizedBox(width: 12),

              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            isVehicle ? Icons.directions_car_rounded : Icons.person_rounded,
                            size: 16,
                            color: cardAccentColor,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            isVehicle ? 'VEHÍCULO AUTORIZADO' : 'PERSONA AUTORIZADA',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                              color: cardAccentColor,
                              letterSpacing: 0.5,
                            ),
                          ),
                          const Spacer(),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                            decoration: BoxDecoration(
                              color: isToday ? Colors.amber.withValues(alpha: 0.2) : slate900,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              isToday ? 'HOY' : visitDateStr,
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                                color: isToday ? Colors.amber : slate300,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),

                      Text(
                        pre.name,
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
                      ),
                      const SizedBox(height: 4),

                      Text(
                        'RUT/DNI: ${pre.docId}',
                        style: const TextStyle(fontSize: 12, color: slate400),
                      ),
                      const SizedBox(height: 6),

                      if (isVehicle && pre.plate != null) ...[
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: slate900,
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: slate800),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.tag, size: 12, color: Colors.orangeAccent),
                              const SizedBox(width: 4),
                              Text(
                                pre.plate!,
                                style: const TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.orangeAccent,
                                  letterSpacing: 1.0,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                pre.vehicleType ?? '',
                                style: const TextStyle(fontSize: 11, color: slate400),
                              )
                            ],
                          ),
                        ),
                        const SizedBox(height: 6),
                      ],

                      Row(
                        children: [
                          const Icon(Icons.meeting_room, size: 14, color: Colors.amber),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              'Destino: ${_displayDestination(pre.destination)}',
                              style: const TextStyle(fontSize: 13, color: slate300),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),

              // Button to view QR Pass
              InkWell(
                onTap: () => _showQRPassDialog(pre),
                child: Container(
                  width: 75,
                  decoration: const BoxDecoration(
                    border: Border(
                      left: BorderSide(color: slate700, width: 1),
                    ),
                  ),
                  child: const Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.qr_code_2_rounded, color: Colors.amber, size: 24),
                      SizedBox(height: 4),
                      Text(
                        'Ver QR',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: Colors.amber,
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              // Button to authorize entry (Mark In)
              if (widget.userRole != UserRole.cliente)
                InkWell(
                  onTap: () => _checkinPreAuth(pre),
                child: Container(
                  width: 75,
                  decoration: BoxDecoration(
                    color: const Color(0xFF10B981).withValues(alpha: 0.1),
                    border: const Border(
                      left: BorderSide(color: slate700, width: 1),
                    ),
                  ),
                  child: const Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.login_rounded, color: Color(0xFF10B981), size: 24),
                      SizedBox(height: 4),
                      Text(
                        'Ingreso',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF10B981),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBlacklistTab() {
    final filteredBlacklist = _blacklist.where((entry) {
      if (_blacklistSearchQuery.isNotEmpty) {
        final query = _blacklistSearchQuery.toLowerCase();
        final nameMatch = entry.name.toLowerCase().contains(query);
        final idMatch = entry.identifier.toLowerCase().contains(query);
        final reasonMatch = entry.reason.toLowerCase().contains(query);
        return nameMatch || idMatch || reasonMatch;
      }
      return true;
    }).toList()..sort((a, b) => b.createdAt.compareTo(a.createdAt));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 1. Blacklist Header
        Container(
          padding: const EdgeInsets.all(16),
          color: slate800,
          child: Row(
            children: [
              const Icon(Icons.gpp_bad_rounded, color: Colors.redAccent, size: 40),
              const SizedBox(width: 12),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Restricciones de Acceso',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white),
                    ),
                    Text(
                      'Lista Negra local de personas o vehículos restringidos',
                      style: TextStyle(fontSize: 12, color: slate400),
                    ),
                  ],
                ),
              ),
              if (widget.userRole == UserRole.admin || widget.userRole == UserRole.cliente)
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.redAccent,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  ),
                  icon: const Icon(Icons.person_remove_alt_1_rounded),
                  label: const Text('Restringir', style: TextStyle(fontWeight: FontWeight.bold)),
                  onPressed: _showAddBlacklistModal,
                ),
              if (widget.userRole == UserRole.admin || widget.userRole == UserRole.cliente) ...[
                const SizedBox(width: 8),
                IconButton(
                  tooltip: 'Importar Lista Negra (CSV)',
                  icon: const Icon(Icons.upload_file_rounded, color: Colors.redAccent),
                  onPressed: _importBlacklistCSV,
                ),
              ],
            ],
          ),
        ),

        // 2. Search Blacklist
        Container(
          color: slate900,
          padding: const EdgeInsets.all(16),
          child: TextField(
            controller: _blacklistSearchController,
            decoration: InputDecoration(
              hintText: 'Buscar en lista negra...',
              prefixIcon: const Icon(Icons.search, color: slate400),
              suffixIcon: _blacklistSearchQuery.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear, color: slate400),
                      onPressed: () {
                        _blacklistSearchController.clear();
                        setState(() => _blacklistSearchQuery = '');
                      },
                    )
                  : null,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: slate700),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: slate700),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: Colors.redAccent, width: 1.5),
              ),
              filled: true,
              fillColor: slate800,
              contentPadding: const EdgeInsets.symmetric(vertical: 12),
            ),
            onChanged: (val) {
              setState(() {
                _blacklistSearchQuery = val;
              });
            },
          ),
        ),

        // 3. Blacklist Entries list
        Expanded(
          child: filteredBlacklist.isEmpty
              ? _buildEmptyState(_blacklistSearchQuery.isNotEmpty, 'Blacklist')
              : ListView.builder(
                  padding: const EdgeInsets.only(left: 16, right: 16, top: 8, bottom: 80),
                  itemCount: filteredBlacklist.length,
                  itemBuilder: (context, index) {
                    return _buildBlacklistCard(filteredBlacklist[index]);
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildBlacklistCard(BlacklistEntry entry) {
    final isVehicle = entry.type == 'vehiculo';
    final accentColor = Colors.redAccent;
    final dateStr = '${entry.createdAt.day}/${entry.createdAt.month}/${entry.createdAt.year}';

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: slate800,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: accentColor.withValues(alpha: 0.2),
          width: 1,
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                width: 6,
                color: accentColor,
              ),
              const SizedBox(width: 12),

              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            isVehicle ? Icons.directions_car_rounded : Icons.person_rounded,
                            size: 16,
                            color: accentColor,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            isVehicle ? 'VEHÍCULO BLOQUEADO' : 'PERSONA BLOQUEADA',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                              color: accentColor,
                              letterSpacing: 0.5,
                            ),
                          ),
                          const Spacer(),
                          Text(
                            dateStr,
                            style: const TextStyle(fontSize: 11, color: slate400),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),

                      Text(
                        entry.name,
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
                      ),
                      const SizedBox(height: 4),

                      Text(
                        'RUT/DNI/Patente: ${entry.identifier}',
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          color: Colors.white70,
                          letterSpacing: 0.5,
                        ),
                      ),
                      const SizedBox(height: 8),

                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Icon(Icons.report_gmailerrorred_rounded, size: 16, color: Colors.redAccent),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              _displayReason(entry.reason),
                              style: const TextStyle(fontSize: 13, color: slate300),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),

              // Button to delete (remove restriction)
              if (widget.userRole == UserRole.admin || widget.userRole == UserRole.cliente)
                InkWell(
                  onTap: () => _confirmRemoveBlacklist(entry),
                  child: Container(
                    width: 70,
                    color: Colors.redAccent.withValues(alpha: 0.05),
                    child: const Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.delete_outline_rounded, color: Colors.redAccent, size: 24),
                        SizedBox(height: 4),
                        Text(
                          'Eliminar',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            color: Colors.redAccent,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  // --- LISTA BLANCA TAB & ACTIONS ---

  Widget _buildWhitelistTab() {
    final filteredWhitelist = _whitelist.where((entry) {
      if (_whitelistSearchQuery.isNotEmpty) {
        final query = _whitelistSearchQuery.toLowerCase();
        final nameMatch = entry.name.toLowerCase().contains(query);
        final idMatch = entry.identifier.toLowerCase().contains(query);
        final unitMatch = entry.unitOrRole.toLowerCase().contains(query);
        return nameMatch || idMatch || unitMatch;
      }
      return true;
    }).toList()..sort((a, b) => b.createdAt.compareTo(a.createdAt));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 1. Whitelist Header
        Container(
          padding: const EdgeInsets.all(16),
          color: slate800,
          child: Row(
            children: [
              const Icon(Icons.verified_user_rounded, color: Color(0xFF10B981), size: 40),
              const SizedBox(width: 12),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Lista Blanca (Sin Registro)',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white),
                    ),
                    Text(
                      'Residentes o personal que no requieren control ni bitácora',
                      style: TextStyle(fontSize: 12, color: slate400),
                    ),
                  ],
                ),
              ),
              if (widget.userRole == UserRole.admin || widget.userRole == UserRole.cliente)
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF10B981),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  ),
                  icon: const Icon(Icons.person_add_alt_1_rounded),
                  label: const Text('Agregar', style: TextStyle(fontWeight: FontWeight.bold)),
                  onPressed: _showAddWhitelistModal,
                ),
            ],
          ),
        ),

        // 2. Search Whitelist
        Container(
          color: slate900,
          padding: const EdgeInsets.all(16),
          child: TextField(
            controller: _whitelistSearchController,
            decoration: InputDecoration(
              hintText: 'Buscar en lista blanca...',
              prefixIcon: const Icon(Icons.search, color: slate400),
              suffixIcon: _whitelistSearchQuery.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear, color: slate400),
                      onPressed: () {
                        _whitelistSearchController.clear();
                        setState(() => _whitelistSearchQuery = '');
                      },
                    )
                  : null,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: slate700),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: slate700),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: Color(0xFF10B981), width: 1.5),
              ),
              filled: true,
              fillColor: slate800,
              contentPadding: const EdgeInsets.symmetric(vertical: 12),
            ),
            onChanged: (val) {
              setState(() {
                _whitelistSearchQuery = val;
              });
            },
          ),
        ),

        // 3. Whitelist Entries list
        Expanded(
          child: filteredWhitelist.isEmpty
              ? _buildEmptyState(_whitelistSearchQuery.isNotEmpty, 'Whitelist')
              : ListView.builder(
                  padding: const EdgeInsets.only(left: 16, right: 16, top: 8, bottom: 80),
                  itemCount: filteredWhitelist.length,
                  itemBuilder: (context, index) {
                    return _buildWhitelistCard(filteredWhitelist[index]);
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildWhitelistCard(WhitelistEntry entry) {
    final isVehicle = entry.type == 'vehiculo';
    const accentColor = Color(0xFF10B981);
    final dateStr = '${entry.createdAt.day}/${entry.createdAt.month}/${entry.createdAt.year}';

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: slate800,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: accentColor.withValues(alpha: 0.2),
          width: 1,
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                width: 6,
                color: accentColor,
              ),
              const SizedBox(width: 12),

              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            isVehicle ? Icons.directions_car_rounded : Icons.person_rounded,
                            size: 16,
                            color: accentColor,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            isVehicle ? 'VEHÍCULO LISTA BLANCA' : 'RESIDENTE / PERSONAL',
                            style: const TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                              color: accentColor,
                              letterSpacing: 0.5,
                            ),
                          ),
                          const Spacer(),
                          Text(
                            dateStr,
                            style: const TextStyle(fontSize: 11, color: slate400),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),

                      Text(
                        entry.name,
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
                      ),
                      const SizedBox(height: 4),

                      Text(
                        'RUT/DNI/Patente: ${entry.identifier}',
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          color: Colors.white70,
                          letterSpacing: 0.5,
                        ),
                      ),
                      const SizedBox(height: 8),

                      Row(
                        children: [
                          const Icon(Icons.home_work_rounded, size: 16, color: accentColor),
                          const SizedBox(width: 6),
                          Text(
                            entry.unitOrRole,
                            style: const TextStyle(fontSize: 13, color: slate300, fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),

              // Button to delete (remove from whitelist)
              if (widget.userRole == UserRole.admin || widget.userRole == UserRole.cliente)
                InkWell(
                  onTap: () => _confirmRemoveWhitelist(entry),
                  child: Container(
                    width: 70,
                    color: Colors.redAccent.withValues(alpha: 0.05),
                    child: const Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.delete_outline_rounded, color: Colors.redAccent, size: 24),
                        SizedBox(height: 4),
                        Text(
                          'Quitar',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            color: Colors.redAccent,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  void _showAddWhitelistModal() {
    final formKey = GlobalKey<FormState>();
    String name = '';
    String identifier = '';
    String type = 'persona';
    String unitOrRole = '';
    bool isRut = true;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: slate800,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setModalState) {
            return Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(context).viewInsets.bottom + 24,
                left: 20,
                right: 20,
                top: 24,
              ),
              child: Form(
                key: formKey,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.verified_user_rounded, color: Color(0xFF10B981), size: 28),
                          const SizedBox(width: 12),
                          Text(
                            'Agregar a Lista Blanca',
                            style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
                          ),
                          const Spacer(),
                          IconButton(
                            icon: const Icon(Icons.close, color: slate400),
                            onPressed: () => Navigator.pop(context),
                          )
                        ],
                      ),
                      const Divider(height: 24, color: slate700),

                      // Segment selector for type
                      Row(
                        children: [
                          Expanded(
                            child: ChoiceChip(
                              label: const Text('Persona'),
                              selected: type == 'persona',
                              onSelected: (selected) {
                                if (selected) setModalState(() => type = 'persona');
                              },
                              backgroundColor: slate900,
                              selectedColor: const Color(0xFF10B981),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: ChoiceChip(
                              label: const Text('Vehículo'),
                              selected: type == 'vehiculo',
                              onSelected: (selected) {
                                if (selected) setModalState(() => type = 'vehiculo');
                              },
                              backgroundColor: slate900,
                              selectedColor: const Color(0xFF10B981),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),

                      TextFormField(
                        decoration: InputDecoration(
                          labelText: type == 'persona' ? 'Nombre del Residente / Personal' : 'Descripción del Vehículo (Ej: Camioneta Depto 102)',
                          prefixIcon: const Icon(Icons.person),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                          filled: true,
                          fillColor: slate900,
                        ),
                        validator: (value) => value == null || value.trim().isEmpty ? 'Ingrese un nombre/descripción' : null,
                        onSaved: (value) => name = value!.trim(),
                      ),
                      const SizedBox(height: 16),

                      if (type == 'persona') ...[
                        Row(
                          children: [
                            const Text('Tipo de Doc: ', style: TextStyle(color: slate400, fontSize: 13)),
                            const SizedBox(width: 8),
                            ChoiceChip(
                              label: const Text('RUT', style: TextStyle(fontSize: 12)),
                              selected: isRut,
                              onSelected: (selected) {
                                if (selected) {
                                  setModalState(() => isRut = true);
                                }
                              },
                              backgroundColor: slate900,
                              selectedColor: const Color(0xFF10B981).withValues(alpha: 0.3),
                            ),
                            const SizedBox(width: 8),
                            ChoiceChip(
                              label: const Text('Pasaporte / DNI', style: TextStyle(fontSize: 12)),
                              selected: !isRut,
                              onSelected: (selected) {
                                if (selected) {
                                  setModalState(() => isRut = false);
                                }
                              },
                              backgroundColor: slate900,
                              selectedColor: const Color(0xFF10B981).withValues(alpha: 0.3),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                      ],

                      TextFormField(
                        key: ValueKey('whitelist_doc_field_$type-$isRut'),
                        textCapitalization: type == 'vehiculo' ? TextCapitalization.characters : TextCapitalization.none,
                        decoration: InputDecoration(
                          labelText: type == 'vehiculo'
                              ? 'Patente / Placa'
                              : (isRut ? 'RUT (Ej: 12.345.678-9)' : 'Identificación (DNI o Pasaporte)'),
                          prefixIcon: Icon(type == 'vehiculo' ? Icons.tag : Icons.badge),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                          filled: true,
                          fillColor: slate900,
                        ),
                        inputFormatters: type == 'vehiculo'
                            ? [PlateFormatter()]
                            : (isRut ? [RutFormatter()] : null),
                        validator: (value) {
                          if (value == null || value.trim().isEmpty) {
                            return type == 'vehiculo' ? 'Ingrese patente' : 'Ingrese identificación';
                          }
                          if (type == 'persona' && !isValidDocument(value, isRut)) {
                            return isRut ? 'RUT inválido' : 'Mínimo 5 caracteres';
                          }
                          if (type == 'vehiculo' && !isValidPlate(value)) {
                            return 'Patente inválida';
                          }
                          return null;
                        },
                        onSaved: (value) => identifier = value!.trim().toUpperCase(),
                      ),
                      const SizedBox(height: 16),

                      TextFormField(
                        decoration: InputDecoration(
                          labelText: 'Ubicación / Rol (Ej: Depto 504 / Personal)',
                          prefixIcon: const Icon(Icons.home_work_rounded),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                          filled: true,
                          fillColor: slate900,
                        ),
                        validator: (value) => value == null || value.trim().isEmpty ? 'Ingrese la ubicación o rol' : null,
                        onSaved: (value) => unitOrRole = value!.trim(),
                      ),
                      const SizedBox(height: 24),

                      ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF10B981),
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                        onPressed: () {
                          if (formKey.currentState!.validate()) {
                            formKey.currentState!.save();
                            final newEntry = WhitelistEntry(
                              id: 'wl_${DateTime.now().millisecondsSinceEpoch}',
                              type: type,
                              name: name,
                              identifier: identifier,
                              unitOrRole: unitOrRole,
                              createdAt: DateTime.now(),
                            );

                            _whitelistBox.put(newEntry.id, newEntry.toMap());
                            _refreshUILists();

                            Navigator.pop(context);

                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text('Agregado a Lista Blanca: $name'),
                                backgroundColor: const Color(0xFF10B981),
                                duration: const Duration(seconds: 2),
                              ),
                            );
                          }
                        },
                        child: const Text(
                          'Guardar en Lista Blanca',
                          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  void _confirmRemoveWhitelist(WhitelistEntry entry) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: slate800,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Quitar de Lista Blanca', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        content: Text('¿Está seguro de quitar a "${entry.name}" (${entry.identifier}) de la Lista Blanca?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar', style: TextStyle(color: slate400)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () {
              _whitelistBox.delete(entry.id);
              _refreshUILists();
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Eliminado de Lista Blanca: ${entry.name}')),
              );
            },
            child: const Text('Quitar', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState(bool hasSearch, String tabType) {
    IconData getIcon() {
      if (hasSearch) return Icons.search_off_rounded;
      if (tabType == 'Monitoreo') return Icons.domain_disabled_rounded;
      if (tabType == 'PreAuth') return Icons.event_busy_rounded;
      if (tabType == 'Installations') return Icons.business_rounded;
      return Icons.gpp_good_rounded;
    }

    String getTitle() {
      if (hasSearch) return 'No se encontraron resultados';
      if (tabType == 'Monitoreo') return 'Sin registros activos';
      if (tabType == 'PreAuth') return 'Sin visitas programadas';
      if (tabType == 'Installations') return 'Sin instalaciones creadas';
      return 'Sin restricciones activas';
    }

    String getSubtitle() {
      if (hasSearch) return 'Prueba buscando con otros términos';
      if (tabType == 'Monitoreo') {
        return 'Registra un ingreso usando los botones de arriba o escanea un QR.';
      }
      if (tabType == 'PreAuth') {
        return 'Presiona "Agendar" arriba para planificar visitas futuras.';
      }
      if (tabType == 'Installations') {
        return 'Presiona "Crear" arriba para agregar tu primer grupo o condominio.';
      }
      return 'Presiona "Restringir" para registrar una persona o vehículo en la Lista Negra.';
    }

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              getIcon(),
              size: 64,
              color: tabType == 'Blacklist' && !hasSearch ? const Color(0xFF10B981) : slate600,
            ),
            const SizedBox(height: 16),
            Text(
              getTitle(),
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: slate400),
            ),
            const SizedBox(height: 8),
            Text(
              getSubtitle(),
              style: const TextStyle(fontSize: 14, color: slate400),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInstallationsTab() {
    final installations = _installationsBox.values
        .where((v) => v is Map)
        .map((v) => Map<String, dynamic>.from(v as Map))
        .toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 1. Title bar with action
        Container(
          padding: const EdgeInsets.all(16),
          color: slate800,
          child: Row(
            children: [
              const Icon(Icons.business_rounded, color: Color(0xFF10B981), size: 40),
              const SizedBox(width: 12),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Instalaciones / Grupos',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white),
                    ),
                    Text(
                      'Grupos con claves diferenciadas de Guardia y Cliente',
                      style: TextStyle(fontSize: 12, color: slate400),
                    ),
                  ],
                ),
              ),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF10B981),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                ),
                icon: const Icon(Icons.add),
                label: const Text('Crear', style: TextStyle(fontWeight: FontWeight.bold)),
                onPressed: () => _showAddEditInstallationModal(),
              ),
            ],
          ),
        ),

        // 2. Installations List
        Expanded(
          child: installations.isEmpty
              ? _buildEmptyState(false, 'Installations')
              : ListView.builder(
                  padding: const EdgeInsets.only(left: 16, right: 16, top: 16, bottom: 80),
                  itemCount: installations.length,
                  itemBuilder: (context, index) {
                    final inst = installations[index];
                    final name = inst['name'] as String;
                    final guardKey = inst['guardKey'] as String;
                    final clientKey = inst['clientKey'] as String;

                    return Container(
                      margin: const EdgeInsets.only(bottom: 16),
                      decoration: BoxDecoration(
                        color: slate800,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: const Color(0xFF10B981).withValues(alpha: 0.2),
                          width: 1,
                        ),
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(16),
                        child: IntrinsicHeight(
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Container(
                                width: 6,
                                color: const Color(0xFF10B981),
                              ),
                              const SizedBox(width: 16),
                              Expanded(
                                child: InkWell(
                                  onTap: () {
                                    setState(() {
                                      _selectedAdminInstallation = name;
                                      _currentTabIndex = 0; // Monitoreo tab
                                    });
                                  },
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(vertical: 16),
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          children: [
                                            Text(
                                              name,
                                              style: const TextStyle(
                                                fontSize: 18,
                                                fontWeight: FontWeight.bold,
                                                color: Colors.white,
                                              ),
                                            ),
                                            const SizedBox(width: 6),
                                            const Icon(Icons.arrow_forward_ios_rounded, size: 14, color: Color(0xFF10B981)),
                                          ],
                                        ),
                                        const SizedBox(height: 12),
                                        Row(
                                          children: [
                                            const Icon(Icons.security, size: 16, color: Color(0xFF10B981)),
                                            const SizedBox(width: 8),
                                            const Text(
                                              'Clave Guardia: ',
                                              style: TextStyle(fontSize: 13, color: slate400),
                                            ),
                                            Text(
                                              guardKey,
                                              style: const TextStyle(
                                                fontSize: 14,
                                                fontWeight: FontWeight.bold,
                                                color: Colors.white,
                                                letterSpacing: 1.0,
                                              ),
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 8),
                                        Row(
                                          children: [
                                            const Icon(Icons.person_outline, size: 16, color: Colors.blueAccent),
                                            const SizedBox(width: 8),
                                            const Text(
                                              'Clave Cliente: ',
                                              style: TextStyle(fontSize: 13, color: slate400),
                                            ),
                                            Text(
                                              clientKey,
                                              style: const TextStyle(
                                                fontSize: 14,
                                                fontWeight: FontWeight.bold,
                                                color: Colors.white,
                                                letterSpacing: 1.0,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                              
                              // Action Buttons: Enter / Destinos / Edit / Delete
                              InkWell(
                                onTap: () {
                                  setState(() {
                                    _selectedAdminInstallation = name;
                                    _currentTabIndex = 0; // Monitoreo tab
                                  });
                                },
                                child: Container(
                                  width: 50,
                                  color: const Color(0xFF10B981).withValues(alpha: 0.1),
                                  child: const Center(
                                    child: Tooltip(
                                      message: 'Entrar a monitorear esta instalación',
                                      child: Icon(Icons.login_rounded, color: Color(0xFF10B981), size: 22),
                                    ),
                                  ),
                                ),
                              ),
                              InkWell(
                                onTap: () => _showManageDestinationsModal(name),
                                child: Container(
                                  width: 50,
                                  color: Colors.white.withValues(alpha: 0.03),
                                  child: const Center(
                                    child: Icon(Icons.list_alt_rounded, color: slate300, size: 22),
                                  ),
                                ),
                              ),
                              InkWell(
                                onTap: () => _showAddEditInstallationModal(
                                  oldName: name,
                                  oldGuardKey: guardKey,
                                  oldClientKey: clientKey,
                                ),
                                child: Container(
                                  width: 50,
                                  color: Colors.amber.withValues(alpha: 0.05),
                                  child: const Center(
                                    child: Icon(Icons.edit_outlined, color: Colors.amber, size: 22),
                                  ),
                                ),
                              ),
                              InkWell(
                                onTap: () => _confirmDeleteInstallation(name),
                                child: Container(
                                  width: 50,
                                  color: Colors.redAccent.withValues(alpha: 0.05),
                                  child: const Center(
                                    child: Icon(Icons.delete_outline_rounded, color: Colors.redAccent, size: 22),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  void _showAddEditInstallationModal({
    String? oldName,
    String? oldGuardKey,
    String? oldClientKey,
  }) {
    final formKey = GlobalKey<FormState>();
    String name = oldName ?? '';
    String guardKey = oldGuardKey ?? '';
    String clientKey = oldClientKey ?? '';

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: slate800,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setModalState) {
            return Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(context).viewInsets.bottom + 24,
                left: 20,
                right: 20,
                top: 24,
              ),
              child: Form(
                key: formKey,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Icon(
                            oldName == null ? Icons.add_business_rounded : Icons.edit_road_rounded,
                            color: const Color(0xFF10B981),
                            size: 28,
                          ),
                          const SizedBox(width: 12),
                          Text(
                            oldName == null ? 'Crear Instalación' : 'Editar Instalación',
                            style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
                          ),
                          const Spacer(),
                          IconButton(
                            icon: const Icon(Icons.close, color: slate400),
                            onPressed: () => Navigator.pop(context),
                          )
                        ],
                      ),
                      const Divider(height: 24, color: slate700),

                      TextFormField(
                        initialValue: name,
                        decoration: InputDecoration(
                          labelText: 'Nombre de la Instalación (Grupo)',
                          prefixIcon: const Icon(Icons.business_rounded),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                          filled: true,
                          fillColor: slate900,
                          hintText: 'Ej: Condominio Altos del Valle',
                        ),
                        validator: (value) {
                          if (value == null || value.trim().isEmpty) {
                            return 'Ingrese el nombre';
                          }
                          final trimmed = value.trim();
                          if (oldName == null && _installationsBox.containsKey(trimmed)) {
                            return 'Ya existe una instalación con este nombre';
                          }
                          return null;
                        },
                        onSaved: (value) => name = value!.trim(),
                      ),
                      const SizedBox(height: 16),

                      TextFormField(
                        initialValue: guardKey,
                        decoration: InputDecoration(
                          labelText: 'Clave Guardia',
                          prefixIcon: const Icon(Icons.security),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                          filled: true,
                          fillColor: slate900,
                          hintText: 'Ej: guard123',
                        ),
                        validator: (value) {
                          if (value == null || value.trim().isEmpty) {
                            return 'Ingrese la clave del guardia';
                          }
                          final trimmed = value.trim();
                          if (trimmed == 'admin' || trimmed == 'guardia' || trimmed == 'cliente') {
                            return 'Esta clave es reservada del sistema';
                          }
                          // Check conflict with other keys in Box
                          for (var key in _installationsBox.keys) {
                            if (key == oldName) continue;
                            final data = _installationsBox.get(key);
                            if (data is Map) {
                              if (data['guardKey'] == trimmed || data['clientKey'] == trimmed) {
                                return 'Esta clave ya está en uso por otra instalación';
                              }
                            }
                          }
                          return null;
                        },
                        onSaved: (value) => guardKey = value!.trim(),
                      ),
                      const SizedBox(height: 16),

                      TextFormField(
                        initialValue: clientKey,
                        decoration: InputDecoration(
                          labelText: 'Clave Cliente',
                          prefixIcon: const Icon(Icons.person_outline),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                          filled: true,
                          fillColor: slate900,
                          hintText: 'Ej: client123',
                        ),
                        validator: (value) {
                          if (value == null || value.trim().isEmpty) {
                            return 'Ingrese la clave del cliente';
                          }
                          final trimmed = value.trim();
                          if (trimmed == 'admin' || trimmed == 'guardia' || trimmed == 'cliente') {
                            return 'Esta clave es reservada del sistema';
                          }
                          if (trimmed == guardKey) {
                            return 'La clave del cliente no puede ser igual a la del guardia';
                          }
                          // Check conflict with other keys in Box
                          for (var key in _installationsBox.keys) {
                            if (key == oldName) continue;
                            final data = _installationsBox.get(key);
                            if (data is Map) {
                              if (data['guardKey'] == trimmed || data['clientKey'] == trimmed) {
                                return 'Esta clave ya está en uso por otra instalación';
                              }
                            }
                          }
                          return null;
                        },
                        onSaved: (value) => clientKey = value!.trim(),
                      ),
                      const SizedBox(height: 24),

                      ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF10B981),
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                        onPressed: () async {
                          if (formKey.currentState!.validate()) {
                            formKey.currentState!.save();
                            
                            if (oldName != null && oldName != name) {
                              // Name changed, remove the old key first
                              await _installationsBox.delete(oldName);
                              try {
                                final client = Supabase.instance.client;
                                await client.from('app_credentials').delete().eq('installation_name', oldName);
                              } catch (e) {
                                debugPrint('Error deleting old credentials from Supabase: $e');
                              }
                            }

                            await _installationsBox.put(name, {
                              'name': name,
                              'guardKey': guardKey,
                              'clientKey': clientKey,
                            });

                            // Push credentials to Supabase for centralized/secure authentication
                            try {
                              final client = Supabase.instance.client;
                              await client.from('app_credentials').upsert({
                                'id': '${name}_guardia',
                                'role': 'guardia',
                                'key_hash': guardKey,
                                'installation_name': name,
                              });
                              await client.from('app_credentials').upsert({
                                'id': '${name}_cliente',
                                'role': 'cliente',
                                'key_hash': clientKey,
                                'installation_name': name,
                              });
                            } catch (e) {
                              debugPrint('Error syncing credentials to Supabase: $e');
                            }

                            setState(() {}); // Refresh list in dashboard screen

                            if (context.mounted) {
                              Navigator.pop(context);
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(oldName == null
                                      ? 'Instalación creada con éxito'
                                      : 'Instalación actualizada con éxito'),
                                  backgroundColor: const Color(0xFF10B981),
                                  duration: const Duration(seconds: 2),
                                ),
                              );
                            }
                          }
                        },
                        child: Text(
                          oldName == null ? 'Crear Instalación' : 'Guardar Cambios',
                          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  void _confirmDeleteInstallation(String name) {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          backgroundColor: slate800,
          title: const Text('Eliminar Instalación', style: TextStyle(color: Colors.white)),
          content: Text(
            '¿Está seguro de que desea eliminar la instalación "$name"? Sus claves de acceso ya no serán válidas.',
            style: const TextStyle(color: slate300),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancelar', style: TextStyle(color: slate400)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
              onPressed: () async {
                await _installationsBox.delete(name);
                try {
                  final client = Supabase.instance.client;
                  await client.from('app_credentials').delete().eq('installation_name', name);
                } catch (e) {
                  debugPrint('Error deleting credentials from Supabase: $e');
                }
                setState(() {});
                if (context.mounted) {
                  Navigator.pop(context);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Instalación eliminada'),
                      backgroundColor: Colors.redAccent,
                      duration: Duration(seconds: 2),
                    ),
                  );
                }
              },
              child: const Text('Confirmar', style: TextStyle(color: Colors.white)),
            ),
          ],
        );
      },
    );
  }

  String _formatDateTime(DateTime dt) {
    final year = dt.year;
    final month = dt.month.toString().padLeft(2, '0');
    final day = dt.day.toString().padLeft(2, '0');
    final hour = dt.hour.toString().padLeft(2, '0');
    final minute = dt.minute.toString().padLeft(2, '0');
    return '$day/$month/$year $hour:$minute';
  }

  void _showRecordDetailsModal(AccessRecord record) {
    final isVehicle = record.type == 'vehiculo';
    final accentColor = isVehicle ? const Color(0xFF3B82F6) : const Color(0xFF10B981);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: slate800,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (BuildContext context) {
        return Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).viewInsets.bottom + 24,
            left: 20,
            right: 20,
            top: 24,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Header
                Row(
                  children: [
                    Icon(
                      isVehicle ? Icons.directions_car_rounded : Icons.person_rounded,
                      color: accentColor,
                      size: 28,
                    ),
                    const SizedBox(width: 12),
                    Text(
                      'Detalles del Registro',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
                    ),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(Icons.close, color: slate400),
                      onPressed: () => Navigator.pop(context),
                    )
                  ],
                ),
                const Divider(height: 24, color: slate700),

                // Details list
                _buildDetailRow(Icons.badge_outlined, 'Nombre', record.name),
                const SizedBox(height: 12),
                _buildDetailRow(Icons.fingerprint_rounded, 'RUT/DNI', record.docId),
                if (isVehicle) ...[
                  const SizedBox(height: 12),
                  _buildDetailRow(Icons.tag, 'Patente', record.plate ?? 'No especificada'),
                  const SizedBox(height: 12),
                  _buildDetailRow(Icons.category_outlined, 'Tipo de Vehículo', record.vehicleType ?? 'No especificado'),
                ],
                const SizedBox(height: 12),
                _buildDetailRow(Icons.location_on_outlined, 'Destino', _displayDestination(record.destination)),
                const SizedBox(height: 12),
                _buildDetailRow(Icons.login_rounded, 'Hora de Entrada', _formatDateTime(record.entryTime)),
                const SizedBox(height: 12),
                _buildDetailRow(
                  Icons.logout_rounded,
                  'Hora de Salida',
                  record.exitTime != null ? _formatDateTime(record.exitTime!) : 'Dentro del recinto',
                  valueColor: record.exitTime == null ? const Color(0xFF10B981) : Colors.white,
                ),
                if (record.comment != null && record.comment!.trim().isNotEmpty) ...[
                  const SizedBox(height: 12),
                  _buildDetailRow(Icons.comment_outlined, 'Comentario', record.comment!),
                ],

                const SizedBox(height: 32),

                // Action Buttons for Admin/Guardia
                if (widget.userRole == UserRole.admin || widget.userRole == UserRole.guardia) ...[
                  Row(
                    children: [
                      Expanded(
                        child: ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.amber,
                            foregroundColor: Colors.black87,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                            padding: const EdgeInsets.symmetric(vertical: 14),
                          ),
                          icon: const Icon(Icons.edit_outlined),
                          label: const Text('Editar', style: TextStyle(fontWeight: FontWeight.bold)),
                          onPressed: () {
                            Navigator.pop(context);
                            _showEditRecordModal(record);
                          },
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.redAccent,
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                            padding: const EdgeInsets.symmetric(vertical: 14),
                          ),
                          icon: const Icon(Icons.delete_outline),
                          label: const Text('Eliminar', style: TextStyle(fontWeight: FontWeight.bold)),
                          onPressed: () {
                            Navigator.pop(context);
                            _confirmDeleteRecord(record);
                          },
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildDetailRow(IconData icon, String label, String value, {Color valueColor = Colors.white}) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 20, color: slate400),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: const TextStyle(fontSize: 12, color: slate400)),
              const SizedBox(height: 2),
              Text(
                value,
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: valueColor),
              ),
            ],
          ),
        ),
      ],
    );
  }

  void _showEditRecordModal(AccessRecord record) {
    final formKey = GlobalKey<FormState>();
    final isVehicle = record.type == 'vehiculo';

    String name = record.name;
    String docId = record.docId;
    String? plate = record.plate;
    String? vehicleType = record.vehicleType;
    String destinationClean = _displayDestination(record.destination);

    final List<String> availableDestinations = List<String>.from(_destinationsBox.get(widget.installationName) ?? ['Administración', 'Bodega', 'Estacionamiento']);
    if (!availableDestinations.contains('Otro...')) {
      availableDestinations.add('Otro...');
    }
    String selectedDestination = availableDestinations.contains(destinationClean) ? destinationClean : 'Otro...';
    bool showCustomDestination = (selectedDestination == 'Otro...');
    String? comment = record.comment;

    // Dropdown list of categories
    final List<String> categories = ['Auto', 'Camioneta', 'SUV', 'Camión de Carga', 'Furgón', 'Moto', 'Bicicleta', 'Bus'];
    
    // Determine original prefix
    String prefix = '';
    final parts = record.destination.split(' | ');
    if (parts.length > 1) {
      prefix = '${parts[0]} | ';
    }

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: slate800,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setModalState) {
            return Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(context).viewInsets.bottom + 24,
                left: 20,
                right: 20,
                top: 24,
              ),
              child: Form(
                key: formKey,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.edit_rounded, color: Colors.amber, size: 28),
                          const SizedBox(width: 12),
                          Text(
                            'Editar Registro',
                            style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
                          ),
                          const Spacer(),
                          IconButton(
                            icon: const Icon(Icons.close, color: slate400),
                            onPressed: () => Navigator.pop(context),
                          )
                        ],
                      ),
                      const Divider(height: 24, color: slate700),

                      TextFormField(
                        initialValue: name,
                        decoration: InputDecoration(
                          labelText: 'Nombre Completo',
                          prefixIcon: const Icon(Icons.badge_outlined),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                          filled: true,
                          fillColor: slate900,
                        ),
                        validator: (v) => (v == null || v.trim().isEmpty) ? 'Ingrese el nombre' : null,
                        onSaved: (v) => name = v!.trim(),
                      ),
                      const SizedBox(height: 16),

                      TextFormField(
                        initialValue: docId,
                        decoration: InputDecoration(
                          labelText: 'Documento / Identificador',
                          prefixIcon: const Icon(Icons.fingerprint_rounded),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                          filled: true,
                          fillColor: slate900,
                        ),
                        validator: (v) => (v == null || v.trim().isEmpty) ? 'Ingrese el identificador' : null,
                        onSaved: (v) => docId = v!.trim(),
                      ),
                      const SizedBox(height: 16),

                      if (isVehicle) ...[
                        TextFormField(
                          initialValue: plate,
                          decoration: InputDecoration(
                            labelText: 'Patente / Matrícula',
                            prefixIcon: const Icon(Icons.tag),
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                            filled: true,
                            fillColor: slate900,
                          ),
                          validator: (v) => (v == null || v.trim().isEmpty) ? 'Ingrese la patente' : null,
                          onSaved: (v) => plate = v!.trim().toUpperCase(),
                        ),
                        const SizedBox(height: 16),

                        DropdownButtonFormField<String>(
                          initialValue: categories.contains(vehicleType) ? vehicleType : 'Auto',
                          decoration: InputDecoration(
                            labelText: 'Tipo de Vehículo',
                            prefixIcon: const Icon(Icons.category_outlined),
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                            filled: true,
                            fillColor: slate900,
                          ),
                          items: categories.map((type) {
                            return DropdownMenuItem(value: type, child: Text(type));
                          }).toList(),
                          onChanged: (val) {
                            setModalState(() {
                              vehicleType = val;
                            });
                          },
                          onSaved: (val) => vehicleType = val,
                        ),
                        const SizedBox(height: 16),
                      ],

                      DropdownButtonFormField<String>(
                        value: selectedDestination,
                        decoration: InputDecoration(
                          labelText: 'Destino',
                          prefixIcon: const Icon(Icons.location_on_outlined),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                          filled: true,
                          fillColor: slate900,
                        ),
                        items: availableDestinations.map((dest) {
                          return DropdownMenuItem<String>(
                            value: dest,
                            child: Text(dest),
                          );
                        }).toList(),
                        onChanged: (val) {
                          if (val != null) {
                            setModalState(() {
                              selectedDestination = val;
                              showCustomDestination = (val == 'Otro...');
                            });
                          }
                        },
                        onSaved: (val) {
                          if (selectedDestination != 'Otro...') {
                            destinationClean = selectedDestination;
                          }
                        },
                      ),
                      const SizedBox(height: 16),

                      if (showCustomDestination) ...[
                        TextFormField(
                          initialValue: selectedDestination == 'Otro...' ? destinationClean : '',
                          decoration: InputDecoration(
                            labelText: 'Escriba el Destino Personalizado',
                            prefixIcon: const Icon(Icons.edit_location_alt_rounded),
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                            filled: true,
                            fillColor: slate900,
                          ),
                          validator: (v) => (v == null || v.trim().isEmpty) ? 'Ingrese el destino personalizado' : null,
                          onSaved: (v) => destinationClean = v!.trim(),
                        ),
                        const SizedBox(height: 16),
                      ],

                      TextFormField(
                        initialValue: comment,
                        decoration: InputDecoration(
                          labelText: 'Comentario (Opcional)',
                          prefixIcon: const Icon(Icons.comment_outlined),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                          filled: true,
                          fillColor: slate900,
                        ),
                        onSaved: (v) => comment = (v == null || v.trim().isEmpty) ? null : v.trim(),
                      ),
                      const SizedBox(height: 24),

                      ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF10B981),
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                        onPressed: () async {
                          if (formKey.currentState!.validate()) {
                            formKey.currentState!.save();

                            final updatedRecord = AccessRecord(
                              id: record.id,
                              type: record.type,
                              name: name,
                              docId: docId,
                              plate: plate,
                              vehicleType: vehicleType,
                              destination: prefix + destinationClean,
                              entryTime: record.entryTime,
                              exitTime: record.exitTime,
                              isInside: record.isInside,
                              photoPath: record.photoPath,
                              comment: comment,
                            );

                            await _recordsBox.put(record.id, updatedRecord.toMap());
                            _refreshUILists();
                            SupabaseSyncManager.syncAll();

                            if (context.mounted) {
                              Navigator.pop(context);
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('Registro actualizado con éxito'),
                                  backgroundColor: Color(0xFF10B981),
                                  duration: Duration(seconds: 2),
                                ),
                              );
                            }
                          }
                        },
                        child: const Text(
                          'Guardar Cambios',
                          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  void _confirmDeleteRecord(AccessRecord record) {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          backgroundColor: slate800,
          title: const Text('Eliminar Registro', style: TextStyle(color: Colors.white)),
          content: Text(
            '¿Está seguro de que desea eliminar el registro de ingreso de "${record.name}"? Esta acción no se puede deshacer.',
            style: const TextStyle(color: slate300),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancelar', style: TextStyle(color: slate400)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
              onPressed: () async {
                await _recordsBox.delete(record.id);
                _refreshUILists();
                SupabaseSyncManager.syncAll();
                if (context.mounted) {
                  Navigator.pop(context);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Registro eliminado'),
                      backgroundColor: Colors.redAccent,
                      duration: Duration(seconds: 2),
                    ),
                  );
                }
              },
              child: const Text('Confirmar', style: TextStyle(color: Colors.white)),
            ),
          ],
        );
      },
    );
  }

  void _showManageDestinationsModal(String installationName) {
    final TextEditingController destController = TextEditingController();
    
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: slate800,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setModalState) {
            final List<String> currentDestinations = List<String>.from(
              _destinationsBox.get(installationName) ?? ['Administración', 'Bodega', 'Estacionamiento']
            );

            return Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(context).viewInsets.bottom + 24,
                left: 20,
                right: 20,
                top: 24,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.list_alt_rounded, color: Color(0xFF10B981), size: 28),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'Destinos: $installationName',
                          style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close, color: slate400),
                        onPressed: () => Navigator.pop(context),
                      )
                    ],
                  ),
                  const Divider(height: 24, color: slate700),
                  
                  const Text(
                    'Bases de datos de destinos exclusivos para este grupo.',
                    style: TextStyle(color: slate400, fontSize: 13),
                  ),
                  const SizedBox(height: 16),

                  // Input row to add new destinations
                  Row(
                    children: [
                      Expanded(
                        child: TextFormField(
                          controller: destController,
                          decoration: InputDecoration(
                            labelText: 'Nuevo Destino',
                            prefixIcon: const Icon(Icons.add_location_alt_rounded),
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                            filled: true,
                            fillColor: slate900,
                          ),
                          onFieldSubmitted: (_) {
                            final val = destController.text.trim();
                            if (val.isNotEmpty && !currentDestinations.contains(val)) {
                              setModalState(() {
                                currentDestinations.add(val);
                                _destinationsBox.put(installationName, currentDestinations);
                                destController.clear();
                              });
                            }
                          },
                        ),
                      ),
                      const SizedBox(width: 12),
                      ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF10B981),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                        ),
                        onPressed: () {
                          final val = destController.text.trim();
                          if (val.isNotEmpty && !currentDestinations.contains(val)) {
                            setModalState(() {
                              currentDestinations.add(val);
                              _destinationsBox.put(installationName, currentDestinations);
                              destController.clear();
                            });
                          }
                        },
                        child: const Icon(Icons.add, color: Colors.white),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),

                  // List of current destinations
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      maxHeight: MediaQuery.of(context).size.height * 0.4,
                    ),
                    child: currentDestinations.isEmpty
                        ? const Padding(
                            padding: EdgeInsets.symmetric(vertical: 24),
                            child: Center(
                              child: Text(
                                'No hay destinos guardados.',
                                style: TextStyle(color: slate400),
                              ),
                            ),
                          )
                        : ListView.builder(
                            shrinkWrap: true,
                            itemCount: currentDestinations.length,
                            itemBuilder: (context, index) {
                              final item = currentDestinations[index];
                              return Container(
                                margin: const EdgeInsets.only(bottom: 8),
                                decoration: BoxDecoration(
                                  color: slate900,
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(color: slate700),
                                ),
                                child: ListTile(
                                  dense: true,
                                  title: Text(
                                    item,
                                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w500),
                                  ),
                                  trailing: IconButton(
                                    icon: const Icon(Icons.delete_outline_rounded, color: Colors.redAccent, size: 20),
                                    onPressed: () {
                                      setModalState(() {
                                        currentDestinations.removeAt(index);
                                        _destinationsBox.put(installationName, currentDestinations);
                                      });
                                    },
                                  ),
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}
