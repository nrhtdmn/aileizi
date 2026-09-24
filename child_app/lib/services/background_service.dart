import 'dart:async';
import 'dart:ui';
import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform, kIsWeb;
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
      foregroundServiceTypes: [AndroidForegroundType.location],
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

LocationSettings _bgLocationSettings() {
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
    return AndroidSettings(
      accuracy: LocationAccuracy.bestForNavigation,
      distanceFilter: 8,
      intervalDuration: const Duration(seconds: 15),
    );
  }
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
    return AppleSettings(
      accuracy: LocationAccuracy.bestForNavigation,
      activityType: ActivityType.fitness,
      distanceFilter: 8,
      pauseLocationUpdatesAutomatically: false,
      showBackgroundLocationIndicator: true,
      allowBackgroundLocationUpdates: true,
    );
  }
  return const LocationSettings(
    accuracy: LocationAccuracy.bestForNavigation,
    distanceFilter: 8,
  );
}

@pragma('vm:entry-point')
void onServiceStart(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();
  await Firebase.initializeApp();

  StreamSubscription<Position>? posSub;
  Timer? fallbackTimer;

  Future<void> tick({Position? forced}) async {
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

      Position? position = forced;
      if (position == null) {
        try {
          position = await Geolocator.getCurrentPosition(
            locationSettings: _bgLocationSettings(),
          );
        } catch (_) {
          position = await Geolocator.getLastKnownPosition();
        }
      }
      if (position == null) {
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

      final prefs = await SharedPreferences.getInstance();
      final prevLat = prefs.getDouble('last_fix_lat');
      final prevLng = prefs.getDouble('last_fix_lng');

      double speedMps = position.speed;
      if (!speedMps.isFinite || speedMps < 0.5) {
        if (prevLat != null && prevLng != null) {
          final prevAt = prefs.getInt('last_fix_at_ms');
          if (prevAt != null) {
            final dt =
                (DateTime.now().millisecondsSinceEpoch - prevAt) / 1000.0;
            if (dt >= 2 && dt <= 90) {
              final dist = Geolocator.distanceBetween(
                  prevLat, prevLng, position.latitude, position.longitude);
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

      if (position.accuracy > 80 && prevLat != null) {
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
          previousLat: prevLat,
          previousLng: prevLng,
        );
      } catch (_) {}

      await db
          .collection('families')
          .doc(familyId)
          .collection('locations')
          .doc(user.uid)
          .set(locationData, SetOptions(merge: true));

      await prefs.setDouble('last_fix_lat', position.latitude);
      await prefs.setDouble('last_fix_lng', position.longitude);
      await prefs.setInt(
          'last_fix_at_ms', DateTime.now().millisecondsSinceEpoch);

      final lastHist = prefs.getInt('last_hist_at_ms') ?? 0;
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      double moved = 9999;
      if (prevLat != null && prevLng != null) {
        moved = Geolocator.distanceBetween(
            prevLat, prevLng, position.latitude, position.longitude);
      }
      if (moved >= 40 || (nowMs - lastHist) / 1000.0 >= 300) {
        try {
          await db
              .collection('families')
              .doc(familyId)
              .collection('location_history')
              .doc(user.uid)
              .collection('entries')
              .add(locationData);
          await prefs.setInt('last_hist_at_ms', nowMs);
        } catch (_) {}
      }

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

  // Sürekli konum akışı (ekran kapalı / arka plan)
  try {
    posSub = Geolocator.getPositionStream(
      locationSettings: _bgLocationSettings(),
    ).listen(
      (pos) => tick(forced: pos),
      onError: (_) {},
    );
  } catch (_) {}

  // İlk anında + akış kesilirse yedek timer
  await tick();
  fallbackTimer = Timer.periodic(const Duration(seconds: 20), (_) => tick());

  service.on('stop').listen((_) async {
    await posSub?.cancel();
    fallbackTimer?.cancel();
    if (service is AndroidServiceInstance) {
      service.stopSelf();
    }
  });
}

Future<int> _getBatteryLevel() async {
  try {
    return await Battery().batteryLevel;
  } catch (_) {
    return -1;
  }
}
