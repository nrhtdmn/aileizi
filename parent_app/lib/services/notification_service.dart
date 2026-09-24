import 'dart:typed_data';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Sistem bildirimi (ses + titreşim) ve tıklama navigasyonu.
class ParentNotificationService {
  ParentNotificationService._();
  static final ParentNotificationService instance =
      ParentNotificationService._();

  static const sosChannelId = 'family_sos_v3';
  static const routeChannelId = 'family_route_v3';
  static const geoChannelId = 'family_geofence_v3';
  static const chatChannelId = 'family_chat_v3';

  /// payload: sos | route | geofence | chat | chat:{childId}
  static String? pendingPayload;
  static void Function(String payload)? onPayload;

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  bool _ready = false;

  Future<void> init() async {
    if (_ready) return;

    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    await _plugin.initialize(
      const InitializationSettings(android: androidInit),
      onDidReceiveNotificationResponse: _onTap,
      onDidReceiveBackgroundNotificationResponse: notificationTapBackground,
    );

    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    try {
      await android?.requestNotificationsPermission();
    } catch (_) {}

    await android?.createNotificationChannel(const AndroidNotificationChannel(
      sosChannelId,
      'SOS Uyarıları',
      description: 'Çocuk SOS gönderdiğinde',
      importance: Importance.max,
      playSound: true,
      enableVibration: true,
      showBadge: true,
    ));
    await android?.createNotificationChannel(const AndroidNotificationChannel(
      routeChannelId,
      'Rota Sapması',
      description: 'Çocuk rotadan saptığında',
      importance: Importance.max,
      playSound: true,
      enableVibration: true,
      showBadge: true,
    ));
    await android?.createNotificationChannel(const AndroidNotificationChannel(
      geoChannelId,
      'Güvenli Bölge',
      description: 'Güvenli bölge giriş/çıkış',
      importance: Importance.max,
      playSound: true,
      enableVibration: true,
      showBadge: true,
    ));
    await android?.createNotificationChannel(const AndroidNotificationChannel(
      chatChannelId,
      'Mesajlar',
      description: 'Çocuktan gelen mesajlar',
      importance: Importance.max,
      playSound: true,
      enableVibration: true,
      showBadge: true,
    ));

    final launch = await _plugin.getNotificationAppLaunchDetails();
    if (launch?.didNotificationLaunchApp == true) {
      final p = launch!.notificationResponse?.payload;
      if (p != null && p.isNotEmpty) {
        pendingPayload = p;
      }
    }

    _ready = true;
  }

  static void _onTap(NotificationResponse response) {
    final p = response.payload;
    if (p == null || p.isEmpty) return;
    pendingPayload = p;
    onPayload?.call(p);
  }

  Future<void> showAlert({
    required int id,
    required String title,
    required String body,
    required String channelId,
    required String channelName,
    required String payload,
  }) async {
    await init();
    await _plugin.show(
      id & 0x7fffffff,
      title,
      body,
      NotificationDetails(
        android: AndroidNotificationDetails(
          channelId,
          channelName,
          channelDescription: 'Aileİzi uyarıları',
          importance: Importance.max,
          priority: Priority.max,
          playSound: true,
          enableVibration: true,
          vibrationPattern: Int64List.fromList([0, 500, 200, 500, 200, 800]),
          category: AndroidNotificationCategory.alarm,
          visibility: NotificationVisibility.public,
          ticker: title,
          styleInformation: BigTextStyleInformation(body),
          autoCancel: true,
        ),
      ),
      payload: payload,
    );
  }

  Future<void> showSos({
    required String eventId,
    required String childName,
  }) async {
    await showAlert(
      id: eventId.hashCode,
      title: 'SOS — Acil durum',
      body: '$childName yardım istiyor',
      channelId: sosChannelId,
      channelName: 'SOS Uyarıları',
      payload: 'sos',
    );
  }

  Future<void> showRoute({
    required String eventId,
    required String childName,
    required String routeName,
    required String eventType,
    required double meters,
    double thresholdMeters = 20,
  }) async {
    String title;
    String body;
    switch (eventType) {
      case 'return':
        title = 'Rotaya dönüş';
        body = '$childName “$routeName” rotasına döndü';
        break;
      case 'cancel':
        title = 'Rota iptal edildi';
        body = '$childName “$routeName” takibini iptal etti';
        break;
      default:
        title = 'Rotadan sapma';
        body =
            '$childName “$routeName” rotasından ${meters.toStringAsFixed(0)} m saptı (eşik ${thresholdMeters.toStringAsFixed(0)} m)';
    }
    await showAlert(
      id: eventId.hashCode,
      title: title,
      body: body,
      channelId: routeChannelId,
      channelName: 'Rota Sapması',
      payload: 'route',
    );
  }

  Future<void> showGeofence({
    required String eventId,
    required String childName,
    required String fenceName,
    required String eventType,
  }) async {
    await showAlert(
      id: eventId.hashCode,
      title: eventType == 'exit'
          ? 'Güvenli bölgeden çıkış'
          : 'Güvenli bölgeye giriş',
      body: '$childName: $fenceName',
      channelId: geoChannelId,
      channelName: 'Güvenli Bölge',
      payload: 'geofence',
    );
  }

  Future<void> showChat({
    required String messageId,
    required String childName,
    required String preview,
    required String childId,
  }) async {
    await showAlert(
      id: messageId.hashCode,
      title: childName,
      body: preview,
      channelId: chatChannelId,
      channelName: 'Mesajlar',
      payload: 'chat:$childId',
    );
  }

  Future<void> showFromRemote(RemoteMessage message) async {
    final n = message.notification;
    final data = message.data;
    final title = n?.title ?? data['title']?.toString() ?? 'Aileİzi';
    final body = n?.body ?? data['body']?.toString() ?? '';
    final payload =
        data['payload']?.toString() ?? data['type']?.toString() ?? 'sos';
    final channel = switch (payload) {
      'route' => routeChannelId,
      'geofence' => geoChannelId,
      _ when payload.startsWith('chat') => chatChannelId,
      _ => sosChannelId,
    };
    final channelName = switch (payload) {
      'route' => 'Rota Sapması',
      'geofence' => 'Güvenli Bölge',
      _ when payload.startsWith('chat') => 'Mesajlar',
      _ => 'SOS Uyarıları',
    };
    await showAlert(
      id: message.messageId?.hashCode ??
          DateTime.now().millisecondsSinceEpoch,
      title: title,
      body: body,
      channelId: channel,
      channelName: channelName,
      payload: payload,
    );
  }

  Future<bool> wasShown(String key) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool('alert_$key') ?? false;
  }

  Future<void> markShown(String key) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('alert_$key', true);
  }

  String? takePendingPayload() {
    final p = pendingPayload;
    pendingPayload = null;
    return p;
  }
}

@pragma('vm:entry-point')
void notificationTapBackground(NotificationResponse response) {
  final p = response.payload;
  if (p != null && p.isNotEmpty) {
    ParentNotificationService.pendingPayload = p;
  }
}
