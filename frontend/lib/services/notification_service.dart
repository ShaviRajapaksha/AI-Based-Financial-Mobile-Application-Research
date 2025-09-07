import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest_all.dart' as tz;
import 'package:timezone/timezone.dart' as tz;
import 'package:flutter_timezone/flutter_timezone.dart';


class NotificationService {
  NotificationService._privateConstructor();
  static final NotificationService instance = NotificationService._privateConstructor();

  final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();

  bool _initialized = false;

  /// Call this early (main.dart) before try to schedule notifications.
  Future<void> initialize({
    AndroidInitializationSettings? androidSettings,
    DarwinInitializationSettings? iosSettings,
    void Function(NotificationResponse)? onDidReceiveResponse,
    void Function(NotificationResponse)? onDidReceiveBackgroundResponse,
  }) async {
    if (_initialized) return;

    // timezone initialization
    tz.initializeTimeZones();
    try {
      final String tzName = await FlutterTimezone.getLocalTimezone();
      tz.setLocalLocation(tz.getLocation(tzName));
    } catch (e) {
      // fallback: use system default (timezone package will pick something sensible)
      tz.setLocalLocation(tz.local);
    }

    final AndroidInitializationSettings aInit =
        androidSettings ?? const AndroidInitializationSettings('@mipmap/ic_launcher');

    final DarwinInitializationSettings dInit = iosSettings ??
        const DarwinInitializationSettings(
          requestAlertPermission: true,
          requestBadgePermission: true,
          requestSoundPermission: true,
        );

    final InitializationSettings initSettings = InitializationSettings(
      android: aInit,
      iOS: dInit,
      macOS: dInit,
    );

    await _plugin.initialize(
      initSettings,
      onDidReceiveNotificationResponse: onDidReceiveResponse,
      onDidReceiveBackgroundNotificationResponse: onDidReceiveBackgroundResponse,
    );

    _initialized = true;
  }

  /// Request permissions. Returns true if granted.
  Future<bool> requestPermissions() async {
    // iOS/macOS
    await _plugin
        .resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>()
        ?.requestPermissions(alert: true, badge: true, sound: true);

    // Android: ask for runtime POST_NOTIFICATIONS on Android 13+ via plugin helper
    final AndroidFlutterLocalNotificationsPlugin? androidImpl =
    _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    final granted = await androidImpl?.requestNotificationsPermission() ?? true;

    return granted;
  }

  /// Simple immediate notification (useful for tests)
  Future<void> show(
      int id, {
        required String title,
        String? body,
        String? payload,
        AndroidNotificationDetails? androidDetails,
        DarwinNotificationDetails? iosDetails,
      }) async {
    final NotificationDetails details = NotificationDetails(
      android: androidDetails ??
          const AndroidNotificationDetails(
            'default_channel',
            'General',
            channelDescription: 'General notifications',
            importance: Importance.defaultImportance,
            priority: Priority.defaultPriority,
          ),
      iOS: iosDetails,
      macOS: iosDetails,
    );

    await _plugin.show(id, title, body, details, payload: payload);
  }

  /// Schedule a one-off notification at a specific DateTime (local time).
  ///
  /// - [exact] when true will use an exact schedule mode (may require SCHEDULE_EXACT_ALARM).
  /// - [recurrence] if 'daily'|'weekly'|'monthly' will set matchDateTimeComponents accordingly.
  Future<void> schedule(
      int id, {
        required String title,
        String? body,
        required DateTime scheduledDate,
        String? payload,
        bool exact = false,
        String? recurrence, // 'daily' | 'weekly' | 'monthly' or null
        AndroidNotificationDetails? androidDetails,
        DarwinNotificationDetails? iosDetails,
      }) async {
    if (!_initialized) {
      debugPrint('NotificationService not initialized. Call initialize() first.');
      return;
    }

    final tz.TZDateTime tzDate = _toTZDateTime(scheduledDate);

    final NotificationDetails details = NotificationDetails(
      android: androidDetails ??
          const AndroidNotificationDetails(
            'default_channel',
            'General',
            channelDescription: 'General notifications',
            importance: Importance.defaultImportance,
            priority: Priority.defaultPriority,
          ),
      iOS: iosDetails,
      macOS: iosDetails,
    );

    // choose AndroidScheduleMode: use inexact by default to avoid needing exact alarm permission
    final AndroidScheduleMode androidScheduleMode =
    exact ? AndroidScheduleMode.exactAllowWhileIdle : AndroidScheduleMode.inexact;

    DateTimeComponents? match;
    if (recurrence == 'daily') {
      match = DateTimeComponents.time;
    } else if (recurrence == 'weekly') {
      // match day-of-week + time
      match = DateTimeComponents.dayOfWeekAndTime;
    } else if (recurrence == 'monthly') {
      match = DateTimeComponents.dayOfMonthAndTime;
    }

    await _plugin.zonedSchedule(
      id,
      title,
      body,
      tzDate,
      details,
      payload: payload,
      androidScheduleMode: androidScheduleMode,
      // uiLocalNotificationDateInterpretation removed in newer versions (handled internally).
      // Use matchDateTimeComponents for recurring schedules
      matchDateTimeComponents: match,
      // If you want exact alarm clock style (Android alarm clock): AndroidScheduleMode.alarmClock exists,
      // you'd pass it via 'androidScheduleMode' and request SCHEDULE_EXACT_ALARM in manifest as needed.
    );
  }

  /// Cancel a single notification by id
  Future<void> cancel(int id) async {
    await _plugin.cancel(id);
  }

  /// Cancel all notifications (pending + shown)
  Future<void> cancelAll() async {
    await _plugin.cancelAll();
  }

  /// List pending scheduled notifications
  Future<List<PendingNotificationRequest>> pending() async {
    return await _plugin.pendingNotificationRequests();
  }

  tz.TZDateTime _toTZDateTime(DateTime dt) {
    // convert a Dart DateTime (local) into a timezone-aware TZDateTime.
    if (dt.isUtc) {
      return tz.TZDateTime.from(dt, tz.UTC);
    }
    return tz.TZDateTime.from(dt, tz.local);
  }
}
