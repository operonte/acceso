import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../models/access_record.dart';
import '../models/pre_auth_record.dart';
import '../models/blacklist_entry.dart';
import '../models/whitelist_entry.dart';
import '../models/app_notification.dart';
import '../utils/supabase_sync_manager.dart';

class DashboardState {
  final List<AccessRecord> allRecords;
  final List<PreAuthRecord> allPreAuths;
  final List<BlacklistEntry> allBlacklist;
  final List<WhitelistEntry> allWhitelist;
  
  final List<AppNotification> notifications;
  final AppNotification? activeBannerNotification;
  
  final int activeTabIndex;
  
  final String searchQuery;
  final String filterType; // 'todos', 'persona', 'vehiculo'
  final String statusFilter; // 'todos', 'adentro', 'fuera'
  final DateTimeRange? selectedDateRange;
  
  final String preAuthSearchQuery;
  final String blacklistSearchQuery;
  final String whitelistSearchQuery;

  DashboardState({
    required this.allRecords,
    required this.allPreAuths,
    required this.allBlacklist,
    required this.allWhitelist,
    required this.notifications,
    this.activeBannerNotification,
    this.activeTabIndex = 0,
    this.searchQuery = '',
    this.filterType = 'todos',
    this.statusFilter = 'todos',
    this.selectedDateRange,
    this.preAuthSearchQuery = '',
    this.blacklistSearchQuery = '',
    this.whitelistSearchQuery = '',
  });

  DashboardState copyWith({
    List<AccessRecord>? allRecords,
    List<PreAuthRecord>? allPreAuths,
    List<BlacklistEntry>? allBlacklist,
    List<WhitelistEntry>? allWhitelist,
    List<AppNotification>? notifications,
    AppNotification? Function()? activeBannerNotification,
    int? activeTabIndex,
    String? searchQuery,
    String? filterType,
    String? statusFilter,
    DateTimeRange? Function()? selectedDateRange,
    String? preAuthSearchQuery,
    String? blacklistSearchQuery,
    String? whitelistSearchQuery,
  }) {
    return DashboardState(
      allRecords: allRecords ?? this.allRecords,
      allPreAuths: allPreAuths ?? this.allPreAuths,
      allBlacklist: allBlacklist ?? this.allBlacklist,
      allWhitelist: allWhitelist ?? this.allWhitelist,
      notifications: notifications ?? this.notifications,
      activeBannerNotification: activeBannerNotification != null ? activeBannerNotification() : this.activeBannerNotification,
      activeTabIndex: activeTabIndex ?? this.activeTabIndex,
      searchQuery: searchQuery ?? this.searchQuery,
      filterType: filterType ?? this.filterType,
      statusFilter: statusFilter ?? this.statusFilter,
      selectedDateRange: selectedDateRange != null ? selectedDateRange() : this.selectedDateRange,
      preAuthSearchQuery: preAuthSearchQuery ?? this.preAuthSearchQuery,
      blacklistSearchQuery: blacklistSearchQuery ?? this.blacklistSearchQuery,
      whitelistSearchQuery: whitelistSearchQuery ?? this.whitelistSearchQuery,
    );
  }

  // Filtered lists
  List<AccessRecord> get filteredRecords {
    return allRecords.where((rec) {
      // 1. Search Query
      if (searchQuery.isNotEmpty) {
        final query = searchQuery.toLowerCase();
        final nameMatch = rec.name.toLowerCase().contains(query);
        final docMatch = rec.docId.toLowerCase().contains(query);
        final plateMatch = rec.plate?.toLowerCase().contains(query) ?? false;
        final destMatch = rec.destination.toLowerCase().contains(query);
        if (!nameMatch && !docMatch && !plateMatch && !destMatch) return false;
      }
      // 2. Type Filter
      if (filterType == 'a_pie') {
        if (rec.type != 'persona') return false;
      } else if (filterType == 'vehiculos') {
        if (rec.type != 'vehiculo') return false;
        final vType = rec.vehicleType?.toLowerCase() ?? '';
        if (vType.contains('moto') || vType.contains('camión') || vType.contains('camion') || vType.contains('bicicleta')) {
          return false;
        }
      } else if (filterType == 'moto') {
        if (rec.type != 'vehiculo') return false;
        final vType = rec.vehicleType?.toLowerCase() ?? '';
        if (!vType.contains('moto')) return false;
      } else if (filterType == 'camion') {
        if (rec.type != 'vehiculo') return false;
        final vType = rec.vehicleType?.toLowerCase() ?? '';
        if (!vType.contains('camión') && !vType.contains('camion')) return false;
      } else if (filterType == 'bicicleta') {
        if (rec.type != 'vehiculo') return false;
        final vType = rec.vehicleType?.toLowerCase() ?? '';
        if (!vType.contains('bicicleta')) return false;
      } else if (filterType != 'todos' && rec.type != filterType) {
        return false;
      }
      
      // 3. Status Filter
      if (statusFilter == 'adentro' && !rec.isInside) return false;
      if (statusFilter == 'fuera' && rec.isInside) return false;
      
      // 4. Date Range Filter
      if (selectedDateRange != null) {
        final entryDate = rec.entryTime.toLocal();
        final start = DateTime(selectedDateRange!.start.year, selectedDateRange!.start.month, selectedDateRange!.start.day);
        final end = DateTime(selectedDateRange!.end.year, selectedDateRange!.end.month, selectedDateRange!.end.day, 23, 59, 59, 999);
        if (entryDate.isBefore(start) || entryDate.isAfter(end)) return false;
      }
      return true;
    }).toList();
  }

  List<PreAuthRecord> get filteredPreAuths {
    if (preAuthSearchQuery.isEmpty) return allPreAuths;
    final query = preAuthSearchQuery.toLowerCase();
    return allPreAuths.where((rec) {
      return rec.name.toLowerCase().contains(query) ||
             rec.docId.toLowerCase().contains(query) ||
             (rec.plate?.toLowerCase().contains(query) ?? false) ||
             rec.destination.toLowerCase().contains(query);
    }).toList();
  }

  List<BlacklistEntry> get filteredBlacklist {
    if (blacklistSearchQuery.isEmpty) return allBlacklist;
    final query = blacklistSearchQuery.toLowerCase();
    return allBlacklist.where((entry) {
      return entry.name.toLowerCase().contains(query) ||
             entry.identifier.toLowerCase().contains(query) ||
             entry.reason.toLowerCase().contains(query);
    }).toList();
  }

  List<WhitelistEntry> get filteredWhitelist {
    if (whitelistSearchQuery.isEmpty) return allWhitelist;
    final query = whitelistSearchQuery.toLowerCase();
    return allWhitelist.where((entry) {
      return entry.name.toLowerCase().contains(query) ||
             entry.identifier.toLowerCase().contains(query) ||
             entry.unitOrRole.toLowerCase().contains(query);
    }).toList();
  }

  // Stats
  int get peopleInside => allRecords.where((r) => r.type == 'persona' && r.isInside).length;
  int get vehiclesInside => allRecords.where((r) => r.type == 'vehiculo' && r.isInside).length;
  int get trucksInside => allRecords.where((r) => r.type == 'vehiculo' && r.isInside && (r.vehicleType?.toLowerCase().contains('camión') == true || r.vehicleType?.toLowerCase().contains('camion') == true)).length;
  int get motosInside => allRecords.where((r) => r.type == 'vehiculo' && r.isInside && r.vehicleType?.toLowerCase().contains('moto') == true).length;
  int get bikesInside => allRecords.where((r) => r.type == 'vehiculo' && r.isInside && r.vehicleType?.toLowerCase().contains('bicicleta') == true).length;
  int get totalInside => allRecords.where((r) => r.isInside).length;
}

class DashboardNotifier extends Notifier<DashboardState> {
  late Box _recordsBox;
  late Box _preAuthBox;
  late Box _blacklistBox;
  late Box _whitelistBox;

  StreamSubscription? _recordsSubscription;
  StreamSubscription? _preAuthSubscription;
  StreamSubscription? _blacklistSubscription;
  StreamSubscription? _whitelistSubscription;

  @override
  DashboardState build() {
    _recordsBox = Hive.box('records_box');
    _preAuthBox = Hive.box('pre_auth_box');
    _blacklistBox = Hive.box('blacklist_box');
    _whitelistBox = Hive.box('whitelist_box');

    // Subscribe to Hive box changes
    _recordsSubscription?.cancel();
    _recordsSubscription = _recordsBox.watch().listen((event) {
      _reloadRecords();
      
      // Handle real-time notifications
      if (SupabaseSyncManager.isSyncingDown) return;

      if (!event.deleted && event.value != null) {
        final map = event.value as Map;
        final name = map['name'] as String? ?? 'Desconocido';
        final type = map['type'] as String? ?? 'persona';
        final isInside = map['isInside'] as bool? ?? true;
        final destination = map['destination'] as String? ?? '';
        
        if (isInside) {
          if (destination.contains('[Excepción Lista Negra]')) {
            addNotification(
              type: 'alerta',
              title: '⚠️ Excepción de Lista Negra',
              body: '$name ingresó a $destination',
            );
          } else {
            addNotification(
              type: 'sync',
              title: type == 'persona' ? 'Ingreso Registrado' : 'Vehículo Registrado',
              body: '$name ingresó a $destination',
            );
          }
        } else {
          addNotification(
            type: 'info',
            title: 'Salida Registrada',
            body: 'Salida de $name registrada.',
          );
        }
      }
    });

    _preAuthSubscription?.cancel();
    _preAuthSubscription = _preAuthBox.watch().listen((_) => _reloadPreAuths());

    _blacklistSubscription?.cancel();
    _blacklistSubscription = _blacklistBox.watch().listen((_) => _reloadBlacklist());

    _whitelistSubscription?.cancel();
    _whitelistSubscription = _whitelistBox.watch().listen((_) => _reloadWhitelist());

    ref.onDispose(() {
      _recordsSubscription?.cancel();
      _preAuthSubscription?.cancel();
      _blacklistSubscription?.cancel();
      _whitelistSubscription?.cancel();
    });

    return DashboardState(
      allRecords: _fetchRecords(),
      allPreAuths: _fetchPreAuths(),
      allBlacklist: _fetchBlacklist(),
      allWhitelist: _fetchWhitelist(),
      notifications: [],
    );
  }

  // --- Read helpers ---
  List<AccessRecord> _fetchRecords() {
    return _recordsBox.values.map((item) {
      return AccessRecord.fromMap(Map<dynamic, dynamic>.from(item as Map));
    }).toList()..sort((a, b) => b.entryTime.compareTo(a.entryTime));
  }

  List<PreAuthRecord> _fetchPreAuths() {
    return _preAuthBox.values.map((item) {
      return PreAuthRecord.fromMap(Map<dynamic, dynamic>.from(item as Map));
    }).toList()..sort((a, b) => b.visitDate.compareTo(a.visitDate));
  }

  List<BlacklistEntry> _fetchBlacklist() {
    return _blacklistBox.values.map((item) {
      return BlacklistEntry.fromMap(Map<dynamic, dynamic>.from(item as Map));
    }).toList()..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  List<WhitelistEntry> _fetchWhitelist() {
    return _whitelistBox.values.map((item) {
      return WhitelistEntry.fromMap(Map<dynamic, dynamic>.from(item as Map));
    }).toList()..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  // --- Reload state ---
  void _reloadRecords() {
    state = state.copyWith(allRecords: _fetchRecords());
  }

  void _reloadPreAuths() {
    state = state.copyWith(allPreAuths: _fetchPreAuths());
  }

  void _reloadBlacklist() {
    state = state.copyWith(allBlacklist: _fetchBlacklist());
  }

  void _reloadWhitelist() {
    state = state.copyWith(allWhitelist: _fetchWhitelist());
  }

  // --- Actions/State Mutators ---
  void setActiveTabIndex(int index) {
    state = state.copyWith(activeTabIndex: index);
  }

  void setSearchQuery(String query) {
    state = state.copyWith(searchQuery: query);
  }

  void setFilterType(String type) {
    state = state.copyWith(filterType: type);
  }

  void setStatusFilter(String status) {
    state = state.copyWith(statusFilter: status);
  }

  void setSelectedDateRange(DateTimeRange? range) {
    state = state.copyWith(selectedDateRange: () => range);
  }

  void setPreAuthSearchQuery(String query) {
    state = state.copyWith(preAuthSearchQuery: query);
  }

  void setBlacklistSearchQuery(String query) {
    state = state.copyWith(blacklistSearchQuery: query);
  }

  void setWhitelistSearchQuery(String query) {
    state = state.copyWith(whitelistSearchQuery: query);
  }

  void addNotification({required String type, required String title, required String body}) {
    SystemSound.play(SystemSoundType.alert);
    final newNotif = AppNotification(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      type: type,
      title: title,
      body: body,
      timestamp: DateTime.now(),
    );
    
    final updatedNotifications = List<AppNotification>.from(state.notifications)..insert(0, newNotif);
    
    state = state.copyWith(
      notifications: updatedNotifications,
      activeBannerNotification: () => newNotif,
    );

    // Clear banner after 4 seconds
    Timer(const Duration(seconds: 4), () {
      if (state.activeBannerNotification?.id == newNotif.id) {
        state = state.copyWith(activeBannerNotification: () => null);
      }
    });
  }

  void markAllNotificationsAsRead() {
    final updated = state.notifications.map((n) {
      n.isRead = true;
      return n;
    }).toList();
    state = state.copyWith(notifications: updated);
  }

  void dismissBannerNotification() {
    state = state.copyWith(activeBannerNotification: () => null);
  }
}

final dashboardProvider = NotifierProvider<DashboardNotifier, DashboardState>(() {
  return DashboardNotifier();
});
