import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:geolocator/geolocator.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:battery_plus/battery_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'geofence_helper.dart';
import 'child_notification_service.dart';

const _notifChannelId = 'location_service';
const _notifChannelName = 'Konum Servisi';

Future<void> initBackgroundService() async {
  final service = FlutterBackgroundService();

  const AndroidNotificationChannel channel = AndroidNotificationChannel(
    _notifChannelId,
    _notifChannelName,
    description: 'Konum takip servisi',
    importance: Importance.low,
  );

  final FlutterLocalNotificationsPlugin notifications =
      FlutterLocalNotificationsPlugin();

  await notifications
      .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(channel);

  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onServiceStart,
      autoStart: true,
      isForegroundMode: true,
      notificationChannelId: _notifChannelId,
      initialNotificationTitle: 'Aileİzi',
      initialNotificationContent: 'Konum paylaşılıyor...',
      foregroundServiceNotificationId: 888,
    ),
    iosConfiguration: IosConfiguration(
      autoStart: true,
      onForeground: onServiceStart,
      onBackground: onIosBackground,
    ),
  );
}

Future<void> startLocationBackgroundService() async {
  final service = FlutterBackgroundService();
  final running = await service.isRunning();
  if (!running) {
    await service.startService();
  }
}

@pragma('vm:entry-point')
Future<bool> onIosBackground(ServiceInstance service) async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  return true;
}

@pragma('vm:entry-point')
void onServiceStart(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();
  await Firebase.initializeApp();

  Future<void> tick() async {
    final db = FirebaseFirestore.instance;
    final auth = FirebaseAuth.instance;
    final user = auth.currentUser;
    if (user == null) return;

    try {
      final userDoc = await db.collection('users').doc(user.uid).get();
      final familyId = userDoc.data()?['familyId'] as String?;
      final childName = userDoc.data()?['name'] as String? ?? 'Çocuk';
      if (familyId == null) return;

      final batteryLevel = await _getBatteryLevel();
      final sharingEnabled =
          userDoc.data()?['locationSharingEnabled'] as bool? ?? true;
      if (!sharingEnabled) {
        await db
            .collection('families')
            .doc(familyId)
            .collection('locations')
            .doc(user.uid)
            .set({
          'childId': user.uid,
          'batteryLevel': batteryLevel,
          'timestamp': FieldValue.serverTimestamp(),
          'isOnline': false,
          'hasLocation': false,
        }, SetOptions(merge: true));
        return;
      }

      Position? position;
      try {
        position = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.bestForNavigation,
            timeLimit: Duration(seconds: 18),
          ),
        );
      } catch (_) {
        position = await Geolocator.getLastKnownPosition();
      }
      if (position == null) {
        // Konum yok — nabız at, çevrimiçi kalsın
        await db
            .collection('families')
            .doc(familyId)
            .collection('locations')
            .doc(user.uid)
            .set({
          'childId': user.uid,
          'batteryLevel': batteryLevel,
          'timestamp': FieldValue.serverTimestamp(),
          'isOnline': true,
        }, SetOptions(merge: true));
        await db
            .collection('families')
            .doc(familyId)
            .collection('device_status')
            .doc(user.uid)
            .set({
          'batteryLevel': batteryLevel,
          'lastSeen': FieldValue.serverTimestamp(),
          'isOnline': true,
        }, SetOptions(merge: true));
        return;
      }

      final prevSnap = await db
          .collection('families')
          .doc(familyId)
          .collection('locations')
          .doc(user.uid)
          .get();

      double speedMps = position.speed;
      if (!speedMps.isFinite || speedMps < 0.5) {
        final prev = prevSnap.data();
        if (prev != null) {
          final plat = (prev['latitude'] as num?)?.toDouble();
          final plng = (prev['longitude'] as num?)?.toDouble();
          final pts = prev['timestamp'];
          DateTime? prevAt;
          if (pts is Timestamp) prevAt = pts.toDate();
          if (plat != null && plng != null && prevAt != null) {
            final dt = DateTime.now().difference(prevAt).inMilliseconds / 1000.0;
            if (dt >= 2 && dt <= 90) {
              final dist = Geolocator.distanceBetween(
                  plat, plng, position.latitude, position.longitude);
              if (dist >= 3) {
                final calc = dist / dt;
                if (calc.isFinite && calc >= 0 && calc < 55) speedMps = calc;
              } else {
                speedMps = 0;
              }
            }
          }
        }
        if (!speedMps.isFinite || speedMps < 0) speedMps = 0;
      }

      if (position.accuracy > 80 && prevSnap.exists) {
        // Kötü GPS — konumu bozma, nabız güncelle
        await db
            .collection('families')
            .doc(familyId)
            .collection('locations')
            .doc(user.uid)
            .set({
          'childId': user.uid,
          'batteryLevel': batteryLevel,
          'timestamp': FieldValue.serverTimestamp(),
          'isOnline': true,
          'hasLocation': true,
        }, SetOptions(merge: true));
        await db
            .collection('families')
            .doc(familyId)
            .collection('device_status')
            .doc(user.uid)
            .set({
          'batteryLevel': batteryLevel,
          'lastSeen': FieldValue.serverTimestamp(),
          'isOnline': true,
        }, SetOptions(merge: true));
        return;
      }

      final locationData = {
        'childId': user.uid,
        'latitude': position.latitude,
        'longitude': position.longitude,
        'accuracy': position.accuracy,
        'speed': speedMps,
        'speedKmh': speedMps * 3.6,
        'heading': position.heading,
        'batteryLevel': batteryLevel,
        'timestamp': FieldValue.serverTimestamp(),
        'isOnline': true,
        'hasLocation': true,
      };

      try {
        await GeofenceHelper.evaluateAndRecord(
          db: db,
          familyId: familyId,
          childId: user.uid,
          childName: childName,
          lat: position.latitude,
          lng: position.longitude,
          previousLocationDoc: prevSnap.data(),
        );
      } catch (_) {}

      await db
          .collection('families')
          .doc(familyId)
          .collection('locations')
          .doc(user.uid)
          .set(locationData, SetOptions(merge: true));

      try {
        await db
            .collection('families')
            .doc(familyId)
            .collection('location_history')
            .doc(user.uid)
            .collection('entries')
            .add(locationData);
      } catch (_) {}

      await db
          .collection('families')
          .doc(familyId)
          .collection('device_status')
          .doc(user.uid)
          .set({
        'batteryLevel': batteryLevel,
        'lastSeen': FieldValue.serverTimestamp(),
        'isOnline': true,
        'locationSharingEnabled': true,
        'latitude': position.latitude,
        'longitude': position.longitude,
        'speedKmh': speedMps * 3.6,
      }, SetOptions(merge: true));

      // Ebeveyn mesajları (arka planda bildirim)
      try {
        await ChildNotificationService.instance.init();
        final chatSnap = await db
            .collection('families')
            .doc(familyId)
            .collection('chats')
            .doc(user.uid)
            .collection('messages')
            .where('readByChild', isEqualTo: false)
            .limit(20)
            .get();
        final prefs = await SharedPreferences.getInstance();
        for (final doc in chatSnap.docs) {
          final d = doc.data();
          if (d['senderRole']?.toString() != 'parent') continue;
          final key = 'calert_chat_${doc.id}';
          if (prefs.getBool(key) == true) continue;
          final ts = d['createdAt'];
          if (ts is Timestamp) {
            final age = DateTime.now().difference(ts.toDate());
            if (age > const Duration(hours: 24)) {
              await prefs.setBool(key, true);
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
          await ChildNotificationService.instance
              .showChat(messageId: doc.id, preview: preview);
          await prefs.setBool(key, true);
        }
      } catch (_) {}
    } catch (_) {
      // Arka planda sessiz; ön plan yükleyici ana güvence.
    }
  }

  // İlk konumu hemen gönder; sonra periyodik devam et.
  await tick();
  Timer.periodic(const Duration(seconds: 25), (_) => tick());
}

Future<int> _getBatteryLevel() async {
  try {
    return await Battery().batteryLevel;
  } catch (_) {
    return -1;
  }
}
