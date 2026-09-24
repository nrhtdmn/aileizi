import 'dart:async';
import 'dart:ui';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'notification_service.dart';

const _watchChannelId = 'family_watch_service';
const _watchChannelName = 'Uyarı dinleme';

Future<void> initParentAlertBackgroundService() async {
  final service = FlutterBackgroundService();

  final notifications = FlutterLocalNotificationsPlugin();
  await notifications
      .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(const AndroidNotificationChannel(
    _watchChannelId,
    _watchChannelName,
    description: 'SOS ve rota uyarılarını dinler',
    importance: Importance.low,
  ));

  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onParentAlertServiceStart,
      autoStart: false,
      isForegroundMode: true,
      notificationChannelId: _watchChannelId,
      initialNotificationTitle: 'Aileİzi',
      initialNotificationContent: 'Uyarılar dinleniyor…',
      foregroundServiceNotificationId: 901,
      foregroundServiceTypes: [AndroidForegroundType.dataSync],
    ),
    iosConfiguration: IosConfiguration(
      autoStart: false,
      onForeground: onParentAlertServiceStart,
      onBackground: onParentAlertIosBackground,
    ),
  );
}

Future<void> startParentAlertBackgroundService() async {
  final service = FlutterBackgroundService();
  final running = await service.isRunning();
  if (!running) {
    await service.startService();
  }
}

@pragma('vm:entry-point')
Future<bool> onParentAlertIosBackground(ServiceInstance service) async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  return true;
}

@pragma('vm:entry-point')
void onParentAlertServiceStart(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  await ParentNotificationService.instance.init();

  if (service is AndroidServiceInstance) {
    service.on('setAsForeground').listen((_) {
      service.setAsForegroundService();
    });
    service.on('setAsBackground').listen((_) {
      service.setAsBackgroundService();
    });
  }

  service.on('stopService').listen((_) {
    service.stopSelf();
  });

  Future<void> tick() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    final familyId = user.uid;
    final db = FirebaseFirestore.instance;
    final notif = ParentNotificationService.instance;

    try {
      final sosSnap = await db
          .collection('families')
          .doc(familyId)
          .collection('sos_events')
          .where('acknowledged', isEqualTo: false)
          .limit(20)
          .get();
      for (final doc in sosSnap.docs) {
        final key = 'sos_${doc.id}';
        if (await notif.wasShown(key)) continue;
        final ts = doc.data()['timestamp'];
        if (ts is Timestamp) {
          final age = DateTime.now().difference(ts.toDate());
          if (age > const Duration(minutes: 30)) {
            await notif.markShown(key);
            continue;
          }
        }
        final name = doc.data()['childName']?.toString() ?? 'Çocuk';
        await notif.showSos(eventId: doc.id, childName: name);
        await notif.markShown(key);
      }
    } catch (_) {}

    try {
      final routeSnap = await db
          .collection('families')
          .doc(familyId)
          .collection('route_events')
          .where('notified', isEqualTo: false)
          .limit(20)
          .get();
      for (final doc in routeSnap.docs) {
        final key = 'route_${doc.id}';
        if (await notif.wasShown(key)) continue;
        final d = doc.data();
        await notif.showRoute(
          eventId: doc.id,
          childName: d['childName']?.toString() ?? 'Çocuk',
          routeName: d['routeName']?.toString() ?? 'Rota',
          eventType: d['eventType']?.toString() ?? 'deviate',
          meters: (d['distanceMeters'] as num?)?.toDouble() ?? 0,
          thresholdMeters: (d['thresholdMeters'] as num?)?.toDouble() ?? 20,
        );
        await notif.markShown(key);
        try {
          await doc.reference.update({'notified': true});
        } catch (_) {}
      }
    } catch (_) {}

    try {
      final geoSnap = await db
          .collection('families')
          .doc(familyId)
          .collection('geofence_events')
          .where('notified', isEqualTo: false)
          .limit(20)
          .get();
      for (final doc in geoSnap.docs) {
        final key = 'geo_${doc.id}';
        if (await notif.wasShown(key)) continue;
        final d = doc.data();
        await notif.showGeofence(
          eventId: doc.id,
          childName: d['childName']?.toString() ?? 'Çocuk',
          fenceName: d['fenceName']?.toString() ?? 'Bölge',
          eventType: d['eventType']?.toString() ?? 'exit',
        );
        await notif.markShown(key);
        try {
          await doc.reference.update({'notified': true});
        } catch (_) {}
      }
    } catch (_) {}

    try {
      final fam = await db.collection('families').doc(familyId).get();
      final childIds = List<String>.from(fam.data()?['childIds'] ?? []);
      for (final childId in childIds) {
        String childName = 'Çocuk';
        try {
          final u = await db.collection('users').doc(childId).get();
          childName = u.data()?['name']?.toString() ?? childName;
        } catch (_) {}
        final chatSnap = await db
            .collection('families')
            .doc(familyId)
            .collection('chats')
            .doc(childId)
            .collection('messages')
            .where('readByParent', isEqualTo: false)
            .limit(30)
            .get();
        for (final doc in chatSnap.docs) {
          final d = doc.data();
          if (d['senderRole']?.toString() != 'child') continue;
          final key = 'chat_${doc.id}';
          if (await notif.wasShown(key)) continue;
          final ts = d['createdAt'];
          if (ts is Timestamp) {
            final age = DateTime.now().difference(ts.toDate());
            if (age > const Duration(hours: 24)) {
              await notif.markShown(key);
              continue;
            }
          }
          final type = d['type']?.toString() ?? 'text';
          final text = d['text']?.toString() ?? '';
          final routeName = d['routeName']?.toString();
          String preview;
          switch (type) {
            case 'location':
              preview = '📍 Konum paylaştı';
              break;
            case 'image':
              preview = '📷 Fotoğraf gönderdi';
              break;
            case 'route':
              preview = '🗺️ ${routeName ?? 'Rota'} gönderdi';
              break;
            default:
              preview = text.trim().isEmpty ? 'Yeni mesaj' : text.trim();
          }
          await notif.showChat(
            messageId: doc.id,
            childName: childName,
            preview: preview,
            childId: childId,
          );
          await notif.markShown(key);
        }
      }
    } catch (_) {}

    if (service is AndroidServiceInstance) {
      if (await service.isForegroundService()) {
        service.setForegroundNotificationInfo(
          title: 'Aileİzi',
          content: 'Uyarılar ve mesajlar dinleniyor…',
        );
      }
    }
  }

  await tick();
  Timer.periodic(const Duration(seconds: 45), (_) => tick());
}
