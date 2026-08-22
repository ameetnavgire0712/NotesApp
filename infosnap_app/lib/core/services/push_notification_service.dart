import 'dart:async';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'api_service.dart';

@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
}

class PushNotificationService {
  PushNotificationService._();

  static final FirebaseMessaging _messaging = FirebaseMessaging.instance;
  static final FlutterLocalNotificationsPlugin _localNotifications =
      FlutterLocalNotificationsPlugin();

  static const AndroidNotificationChannel _channel = AndroidNotificationChannel(
    'infosnap_updates',
    'InfoSnap updates',
    description: 'Group invites, shared snaps, reactions, and upload updates.',
    importance: Importance.high,
  );

  static bool _initialized = false;
  static StreamSubscription<String>? _tokenRefreshSub;
  static StreamSubscription<AuthState>? _authSub;
  static StreamSubscription<RemoteMessage>? _foregroundSub;
  static String? _lastRegisteredToken;

  static Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;

    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);

    await _initializeLocalNotifications();
    await _requestPermission();
    await _registerCurrentToken();

    _tokenRefreshSub = _messaging.onTokenRefresh.listen((token) {
      unawaited(_registerToken(token));
    });

    _authSub = Supabase.instance.client.auth.onAuthStateChange.listen((event) {
      if (event.session != null) {
        unawaited(_registerCurrentToken(force: true));
      }
    });

    _foregroundSub = FirebaseMessaging.onMessage.listen(_showForegroundMessage);

    final initialMessage = await _messaging.getInitialMessage();
    if (initialMessage != null) {
      debugPrint('Push opened app: ${initialMessage.data}');
    }

    FirebaseMessaging.onMessageOpenedApp.listen((message) {
      debugPrint('Push tapped: ${message.data}');
    });
  }

  static Future<void> dispose() async {
    await _tokenRefreshSub?.cancel();
    await _authSub?.cancel();
    await _foregroundSub?.cancel();
    _initialized = false;
  }

  static Future<void> _initializeLocalNotifications() async {
    const androidInit =
        AndroidInitializationSettings('@drawable/ic_notification_logo');
    const initSettings = InitializationSettings(android: androidInit);
    await _localNotifications.initialize(settings: initSettings);

    final androidPlugin =
        _localNotifications.resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
    await androidPlugin?.createNotificationChannel(_channel);
    await androidPlugin?.requestNotificationsPermission();
  }

  static Future<void> _requestPermission() async {
    if (!Platform.isAndroid && !Platform.isIOS) return;
    final settings = await _messaging.requestPermission(
      alert: true,
      badge: true,
      sound: true,
      provisional: false,
    );
    debugPrint('Push permission: ${settings.authorizationStatus}');
  }

  static Future<void> _registerCurrentToken({bool force = false}) async {
    if (Supabase.instance.client.auth.currentSession == null) return;
    try {
      final token = await _messaging.getToken();
      if (token == null || token.isEmpty) return;
      if (!force && token == _lastRegisteredToken) return;
      await _registerToken(token);
    } catch (e) {
      debugPrint('Push token fetch failed: $e');
    }
  }

  static Future<void> _registerToken(String token) async {
    if (Supabase.instance.client.auth.currentSession == null) return;
    final ok = await ApiService().registerDeviceToken(
      token: token,
      platform: Platform.isAndroid ? 'android' : Platform.operatingSystem,
    );
    if (ok) {
      _lastRegisteredToken = token;
      debugPrint('Push token registered');
    } else {
      debugPrint('Push token registration failed');
    }
  }

  static Future<void> _showForegroundMessage(RemoteMessage message) async {
    final notification = message.notification;
    final title = notification?.title ?? _titleFor(message.data['type']);
    final body = notification?.body ?? 'Open InfoSnap to view the update.';

    await _localNotifications.show(
      id: message.hashCode,
      title: title,
      body: body,
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          _channel.id,
          _channel.name,
          channelDescription: _channel.description,
          importance: Importance.high,
          priority: Priority.high,
          icon: '@drawable/ic_notification_logo',
          color: const Color(0xFF22C55E),
        ),
      ),
      payload: message.data.toString(),
    );
  }

  static String _titleFor(Object? type) {
    switch (type) {
      case 'group_invite':
        return 'Group invite';
      case 'group_invite_accepted':
        return 'Group invite accepted';
      case 'group_snap':
        return 'New snap shared';
      case 'group_reaction':
        return 'New reaction';
      case 'group_join_request':
        return 'Group join request';
      case 'group_join_request_accepted':
        return 'Join request accepted';
      default:
        return 'InfoSnap update';
    }
  }
}
