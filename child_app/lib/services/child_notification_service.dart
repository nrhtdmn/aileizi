import 'dart:typed_data';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Çocuk uygulaması sistem bildirimleri (mesaj vb.).
class ChildNotificationService {
  ChildNotificationService._();
  static final ChildNotificationService instance = ChildNotificationService._();

  static const chatChannelId = 'child_chat_v3';

  /// chat | chat_open
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
      onDidReceiveNotificationResponse: (r) {
        final p = r.payload;
        if (p == null || p.isEmpty) return;
        pendingPayload = p;
        onPayload?.call(p);
      },
      onDidReceiveBackgroundNotificationResponse: childNotificationTapBackground,
    );

    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    try {
      await android?.requestNotificationsPermission();
    } catch (_) {}

    await android?.createNotificationChannel(const AndroidNotificationChannel(
      chatChannelId,
      'Ebeveyn mesajları',
      description: 'Ebeveynden gelen mesajlar',
      importance: Importance.max,
      playSound: true,
      enableVibration: true,
      showBadge: true,
    ));

    final launch = await _plugin.getNotificationAppLaunchDetails();
    if (launch?.didNotificationLaunchApp == true) {
      final p = launch!.notificationResponse?.payload;
      if (p != null && p.isNotEmpty) pendingPayload = p;
    }
    _ready = true;
  }

  Future<void> showChat({
    required String messageId,
    required String preview,
  }) async {
    await init();
    await _plugin.show(
      messageId.hashCode & 0x7fffffff,
      'Ebeveyn',
      preview,
      NotificationDetails(
        android: AndroidNotificationDetails(
          chatChannelId,
          'Ebeveyn mesajları',
          channelDescription: 'Ebeveynden gelen mesajlar',
          importance: Importance.max,
          priority: Priority.max,
          playSound: true,
          enableVibration: true,
          vibrationPattern: Int64List.fromList([0, 400, 200, 400]),
          category: AndroidNotificationCategory.message,
          visibility: NotificationVisibility.public,
          styleInformation: BigTextStyleInformation(preview),
          autoCancel: true,
        ),
      ),
      payload: 'chat',
    );
  }

  Future<bool> wasShown(String key) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool('calert_$key') ?? false;
  }

  Future<void> markShown(String key) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('calert_$key', true);
  }

  String? takePendingPayload() {
    final p = pendingPayload;
    pendingPayload = null;
    return p;
  }
}

@pragma('vm:entry-point')
void childNotificationTapBackground(NotificationResponse response) {
  final p = response.payload;
  if (p != null && p.isNotEmpty) {
    ChildNotificationService.pendingPayload = p;
  }
}
