import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'screens/dashboard_screen.dart';
import 'theme/colors.dart';
import 'utils/supabase_sync_manager.dart';
import 'utils/notification_helper.dart';
import 'screens/login_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize Supabase
  await Supabase.initialize(
    url: 'https://uajfwuwgbnpptvkujvwp.supabase.co',
    publishableKey: 'sb_publishable__k-MtHWCMbpsCzek22ZVuQ_OOmr3P8j',
  );
  
  // Initialize Hive
  await Hive.initFlutter();
  
  // Open storage boxes for access records, pre-authorizations, and blacklist
  await Hive.openBox('records_box');
  await Hive.openBox('pre_auth_box');
  await Hive.openBox('blacklist_box');
  await Hive.openBox('whitelist_box');
  await Hive.openBox('installations_box');
  await Hive.openBox('destinations_box');
  await Hive.openBox('sync_metadata_box');
  await Hive.openBox('session_box');

  // Keep boxes empty by default for clean start
  
  // Initialize system notifications
  await NotificationHelper.initialize();
  
  // Initialize Supabase Synchronization
  await SupabaseSyncManager.initialize();
  
  // Get persisted session if any
  final sessionBox = Hive.box('session_box');
  final String? activeRoleStr = sessionBox.get('active_role') as String?;
  final String? activeInstallation = sessionBox.get('active_installation') as String?;
  
  UserRole? activeRole;
  if (activeRoleStr == 'admin') {
    activeRole = UserRole.admin;
  } else if (activeRoleStr == 'guardia') {
    activeRole = UserRole.guardia;
  } else if (activeRoleStr == 'cliente') {
    activeRole = UserRole.cliente;
  }

  // Initialize Sentry for real-time error tracking
  await SentryFlutter.init(
    (options) {
      options.dsn = 'https://a1b2c3d4e5f6g7h8i9j0@o0.ingest.sentry.io/placeholder';
      options.tracesSampleRate = 1.0;
      options.attachScreenshot = true;
    },
    appRunner: () => runApp(
      ProviderScope(
        child: MyApp(
          initialRole: activeRole,
          initialInstallation: activeInstallation,
        ),
      ),
    ),
  );
}

class MyApp extends StatelessWidget {
  final UserRole? initialRole;
  final String? initialInstallation;

  const MyApp({
    super.key,
    this.initialRole,
    this.initialInstallation,
  });

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Control de Acceso',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: slate900,
        primaryColor: const Color(0xFF10B981),
        appBarTheme: const AppBarTheme(
          backgroundColor: slate800,
        ),
        cardTheme: const CardThemeData(
          color: slate800,
        ),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF10B981),
          secondary: Color(0xFF3B82F6),
          surface: slate800,
        ),
      ),
      initialRoute: initialRole != null ? '/dashboard' : '/',
      routes: {
        '/': (context) => const LoginScreen(),
        '/dashboard': (context) {
          final args = ModalRoute.of(context)!.settings.arguments;
          if (args is LoginSession) {
            return DashboardScreen(
              userRole: args.role,
              installationName: args.installationName,
            );
          } else if (args is UserRole) {
            return DashboardScreen(userRole: args);
          }
          
          if (initialRole != null) {
            return DashboardScreen(
              userRole: initialRole!,
              installationName: initialInstallation,
            );
          }
          return const DashboardScreen(userRole: UserRole.guardia);
        },
      },
    );
  }
}
