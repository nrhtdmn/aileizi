import 'package:battery_plus/battery_plus.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'geofence_helper.dart';
import 'route_monitor_service.dart';

/// Çocuk uygulamasından konumun Firestore'a güvenilir yazılması.
/// Kota dostu: gereksiz okuma/yazmayı throttle eder.
class LocationUploadService {
  static const _prefLat = 'last_fix_lat';
  static const _prefLng = 'last_fix_lng';
  static const _prefAt = 'last_fix_at_ms';
  static const _prefFamily = 'cached_family_id';
  static const _prefHistAt = 'last_hist_at_ms';
  static const _prefHeartbeatAt = 'last_heartbeat_at_ms';

  /// Tam konum yazımı için minimum süre / mesafe
  static const _minFullWriteSec = 20;
  static const _minMoveMeters = 12.0;
  static const _heartbeatSec = 90;
  static const _historyMinSec = 300;
  static const _historyMinMeters = 40.0;

  static Future<bool> ensurePermission() async {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) return false;

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      return false;
    }
    // whileInUse → Always (ekran kapalı / arka plan için gerekli)
    if (permission == LocationPermission.whileInUse) {
      permission = await Geolocator.requestPermission();
    }
    return permission == LocationPermission.whileInUse ||
        permission == LocationPermission.always;
  }

  static const _locationSettings = LocationSettings(
    accuracy: LocationAccuracy.high,
    distanceFilter: 8,
    timeLimit: Duration(seconds: 20),
  );

  static Future<String?> _resolveFamilyId({
    required FirebaseFirestore db,
    required String uid,
    String? familyId,
  }) async {
    if (familyId != null && familyId.isNotEmpty) return familyId;
    final prefs = await SharedPreferences.getInstance();
    final cached = prefs.getString(_prefFamily);
    if (cached != null && cached.isNotEmpty) return cached;

    final userDoc = await db.collection('users').doc(uid).get();
    final resolved = userDoc.data()?['familyId'] as String?;
    if (resolved != null && resolved.isNotEmpty) {
      await prefs.setString(_prefFamily, resolved);
    }
    return resolved;
  }

  /// Konumu alıp aile locations koleksiyonuna yazar.
  static Future<bool> uploadOnce({String? familyId}) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return false;

    final db = FirebaseFirestore.instance;
    final resolvedFamilyId = await _resolveFamilyId(
      db: db,
      uid: user.uid,
      familyId: familyId,
    );
    if (resolvedFamilyId == null || resolvedFamilyId.isEmpty) return false;

    // sharing flag: cache’li aile ile her seferinde users.get yapma
    bool sharingEnabled = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final cachedShare = prefs.getBool('location_sharing_enabled');
      if (cachedShare != null) {
        sharingEnabled = cachedShare;
      } else {
        final userDoc = await db.collection('users').doc(user.uid).get();
        sharingEnabled =
            userDoc.data()?['locationSharingEnabled'] as bool? ?? true;
        await prefs.setBool('location_sharing_enabled', sharingEnabled);
        final name = userDoc.data()?['name'] as String?;
        if (name != null) await prefs.setString('cached_child_name', name);
      }
    } catch (_) {}

    if (!sharingEnabled) {
      await db
          .collection('families')
          .doc(resolvedFamilyId)
          .collection('locations')
          .doc(user.uid)
          .set({
        'childId': user.uid,
        'timestamp': FieldValue.serverTimestamp(),
        'isOnline': false,
        'hasLocation': false,
      }, SetOptions(merge: true));
      return false;
    }

    final allowed = await ensurePermission();
    if (!allowed) return false;

    Position? position;
    try {
      position = await Geolocator.getCurrentPosition(
        locationSettings: _locationSettings,
      ).timeout(const Duration(seconds: 22));
    } catch (_) {
      try {
        position = await Geolocator.getLastKnownPosition();
      } catch (_) {}
    }

    final prefs = await SharedPreferences.getInstance();
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final lastAt = prefs.getInt(_prefAt) ?? 0;
    final lastHb = prefs.getInt(_prefHeartbeatAt) ?? 0;
    final ageSec = (nowMs - lastAt) / 1000.0;
    final hbAgeSec = (nowMs - lastHb) / 1000.0;

    if (position == null) {
      if (hbAgeSec < _heartbeatSec) return false;
      return _writeHeartbeat(
        db: db,
        familyId: resolvedFamilyId,
        uid: user.uid,
        prefs: prefs,
        hasLocation: false,
      );
    }

    final hadFix = prefs.containsKey(_prefLat);
    final prevLatEarly = prefs.getDouble(_prefLat);
    final prevLngEarly = prefs.getDouble(_prefLng);
    final childNameEarly = prefs.getString('cached_child_name') ?? 'Çocuk';

    // Düşük doğrulukta bile geofence kontrol et (konum yazma atlanır)
    if (position.accuracy > 75 && hadFix) {
      try {
        await GeofenceHelper.evaluateAndRecord(
          db: db,
          familyId: resolvedFamilyId,
          childId: user.uid,
          childName: childNameEarly,
          lat: position.latitude,
          lng: position.longitude,
          previousLat: prevLatEarly,
          previousLng: prevLngEarly,
        );
      } catch (_) {}
      if (hbAgeSec < _heartbeatSec) return true;
      return _writeHeartbeat(
        db: db,
        familyId: resolvedFamilyId,
        uid: user.uid,
        prefs: prefs,
        hasLocation: true,
      );
    }

    final prevLat = prevLatEarly;
    final prevLng = prevLngEarly;
    double moved = 9999;
    if (prevLat != null && prevLng != null) {
      moved = Geolocator.distanceBetween(
        prevLat,
        prevLng,
        position.latitude,
        position.longitude,
      );
    }

    // Hareket az olsa da geofence değerlendir
    if (moved >= 5 || ageSec >= 30) {
      try {
        await GeofenceHelper.evaluateAndRecord(
          db: db,
          familyId: resolvedFamilyId,
          childId: user.uid,
          childName: childNameEarly,
          lat: position.latitude,
          lng: position.longitude,
          previousLat: prevLat,
          previousLng: prevLng,
        );
      } catch (_) {}
    }

    final significantMove = moved >= _minMoveMeters;
    final dueFull = ageSec >= _minFullWriteSec;
    if (!significantMove && !dueFull) {
      if (hbAgeSec >= _heartbeatSec) {
        return _writeHeartbeat(
          db: db,
          familyId: resolvedFamilyId,
          uid: user.uid,
          prefs: prefs,
          hasLocation: true,
        );
      }
      return true;
    }

    final computed = await _computeSpeedMps(
      prefs: prefs,
      lat: position.latitude,
      lng: position.longitude,
      gpsSpeed: position.speed,
    );

    int battery = -1;
    try {
      battery = await Battery().batteryLevel;
    } catch (_) {}

    final childName = childNameEarly;

    final data = {
      'childId': user.uid,
      'latitude': position.latitude,
      'longitude': position.longitude,
      'accuracy': position.accuracy,
      'speed': computed,
      'speedKmh': computed * 3.6,
      'heading': position.heading,
      'batteryLevel': battery,
      'timestamp': FieldValue.serverTimestamp(),
      'isOnline': true,
      'hasLocation': true,
    };

    await db
        .collection('families')
        .doc(resolvedFamilyId)
        .collection('locations')
        .doc(user.uid)
        .set(data, SetOptions(merge: true));

    await prefs.setDouble(_prefLat, position.latitude);
    await prefs.setDouble(_prefLng, position.longitude);
    await prefs.setInt(_prefAt, nowMs);
    await prefs.setInt(_prefHeartbeatAt, nowMs);

    try {
      await RouteMonitorService.checkDeviation(
        familyId: resolvedFamilyId,
        childId: user.uid,
        childName: childName,
        position: position,
      );
    } catch (_) {}

    // Geçmiş: her tick değil — hareket veya 5 dk
    final lastHist = prefs.getInt(_prefHistAt) ?? 0;
    final histAge = (nowMs - lastHist) / 1000.0;
    if (moved >= _historyMinMeters || histAge >= _historyMinSec) {
      try {
        await db
            .collection('families')
            .doc(resolvedFamilyId)
            .collection('location_history')
            .doc(user.uid)
            .collection('entries')
            .add(data);
        await prefs.setInt(_prefHistAt, nowMs);
      } catch (_) {}
    }

    try {
      await db
          .collection('families')
          .doc(resolvedFamilyId)
          .collection('device_status')
          .doc(user.uid)
          .set({
        'batteryLevel': battery,
        'lastSeen': FieldValue.serverTimestamp(),
        'isOnline': true,
        'locationSharingEnabled': true,
        'latitude': position.latitude,
        'longitude': position.longitude,
        'speedKmh': computed * 3.6,
      }, SetOptions(merge: true));
    } catch (_) {}

    return true;
  }

  static Future<bool> _writeHeartbeat({
    required FirebaseFirestore db,
    required String familyId,
    required String uid,
    required SharedPreferences prefs,
    required bool hasLocation,
  }) async {
    int battery = -1;
    try {
      battery = await Battery().batteryLevel;
    } catch (_) {}
    try {
      await db
          .collection('families')
          .doc(familyId)
          .collection('locations')
          .doc(uid)
          .set({
        'childId': uid,
        'batteryLevel': battery,
        'timestamp': FieldValue.serverTimestamp(),
        'isOnline': true,
        if (hasLocation) 'hasLocation': true,
      }, SetOptions(merge: true));
      await db
          .collection('families')
          .doc(familyId)
          .collection('device_status')
          .doc(uid)
          .set({
        'batteryLevel': battery,
        'lastSeen': FieldValue.serverTimestamp(),
        'isOnline': true,
      }, SetOptions(merge: true));
      await prefs.setInt(
          _prefHeartbeatAt, DateTime.now().millisecondsSinceEpoch);
    } catch (_) {
      return false;
    }
    return true;
  }

  /// GPS speed geçersizse ardışık noktalardan m/s hesapla.
  static Future<double> _computeSpeedMps({
    required SharedPreferences prefs,
    required double lat,
    required double lng,
    required double gpsSpeed,
  }) async {
    if (gpsSpeed.isFinite && gpsSpeed >= 0.5 && gpsSpeed < 55) {
      return gpsSpeed;
    }

    final prevLat = prefs.getDouble(_prefLat);
    final prevLng = prefs.getDouble(_prefLng);
    final prevAt = prefs.getInt(_prefAt);
    if (prevLat == null || prevLng == null || prevAt == null) {
      return gpsSpeed.isFinite && gpsSpeed > 0 ? gpsSpeed : 0;
    }

    final dtSec = (DateTime.now().millisecondsSinceEpoch - prevAt) / 1000.0;
    if (dtSec < 1.5 || dtSec > 120) {
      return gpsSpeed.isFinite && gpsSpeed > 0 ? gpsSpeed : 0;
    }

    final dist = Geolocator.distanceBetween(prevLat, prevLng, lat, lng);
    if (dist < 3) return 0;
    final mps = dist / dtSec;
    if (!mps.isFinite || mps < 0) return 0;
    if (mps > 55) return gpsSpeed.isFinite && gpsSpeed > 0 ? gpsSpeed : 0;
    return mps;
  }
}
