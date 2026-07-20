import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

class NotificationHelper {
  static final FlutterLocalNotificationsPlugin _notificationsPlugin =
      FlutterLocalNotificationsPlugin();

  static Future<void> initialize() async {
    if (kIsWeb) return;
    
    const AndroidInitializationSettings initializationSettingsAndroid =
        AndroidInitializationSettings('@mipmap/ic_launcher');

    const InitializationSettings initializationSettings = InitializationSettings(
      android: initializationSettingsAndroid,
    );

    await _notificationsPlugin.initialize(
      settings: initializationSettings,
    );

    // Request permissions for Android 13+
    if (Platform.isAndroid) {
      final androidImplementation =
          _notificationsPlugin.resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>();
      if (androidImplementation != null) {
        try {
          await androidImplementation.requestNotificationsPermission();
        } catch (e) {
          debugPrint('Error requesting notifications permission: $e');
        }
      }
    }
  }

  static Future<void> showNotification(String title, String body, {bool isAlert = false}) async {
    if (kIsWeb) {
      debugPrint('Web Notification: $title - $body');
      return;
    }

    final AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
      isAlert ? 'critical_alerts_channel' : 'general_alerts_channel',
      isAlert ? 'Alertas Críticas' : 'Alertas Generales',
      channelDescription: isAlert 
          ? 'Notificaciones de seguridad de alta prioridad'
          : 'Notificaciones del sistema de control de acceso',
      importance: Importance.max,
      priority: Priority.high,
      playSound: true,
      enableVibration: true,
    );

    final NotificationDetails notificationDetails = NotificationDetails(
      android: androidDetails,
    );

    try {
      await _notificationsPlugin.show(
        id: DateTime.now().millisecondsSinceEpoch.hashCode,
        title: title,
        body: body,
        notificationDetails: notificationDetails,
      );
    } catch (e) {
      debugPrint('Error showing local notification: $e');
    }
  }
}
