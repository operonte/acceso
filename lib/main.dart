import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'screens/dashboard_screen.dart';
import 'theme/colors.dart';
import 'utils/supabase_sync_manager.dart';
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
  await Hive.openBox('sync_metadata_box');
  
  // Initialize Supabase Synchronization
  await SupabaseSyncManager.initialize();
  
  // Initialize Sentry for real-time error tracking
  await SentryFlutter.init(
    (options) {
      options.dsn = 'https://a1b2c3d4e5f6g7h8i9j0@o0.ingest.sentry.io/placeholder';
      options.tracesSampleRate = 1.0;
      options.attachScreenshot = true;
    },
    appRunner: () => runApp(const MyApp()),
  );
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

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
      initialRoute: '/',
      routes: {
        '/': (context) => const LoginScreen(),
        '/dashboard': (context) {
          final role = ModalRoute.of(context)!.settings.arguments as UserRole;
          return DashboardScreen(userRole: role);
        },
      },
    );
  }
}
