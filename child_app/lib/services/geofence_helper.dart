import 'dart:math';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Ebeveyn uygulamasındaki mantıkla uyumlu: çocuk cihazında bölge çıkışı/girişi kaydı.
/// Inside durumu SharedPreferences'ta tutulur — önceki Firestore doc olmasa da çalışır.
class GeofenceHelper {
  static double distanceMeters(
    double lat1,
    double lon1,
    double lat2,
    double lon2,
  ) {
    const r = 6371000.0;
    final dLat = _rad(lat2 - lat1);
    final dLon = _rad(lon2 - lon1);
    final a = sin(dLat / 2) * sin(dLat / 2) +
        cos(_rad(lat1)) * cos(_rad(lat2)) * sin(dLon / 2) * sin(dLon / 2);
    final c = 2 * atan2(sqrt(a), sqrt(1 - a));
    return r * c;
  }

  static double _rad(double d) => d * pi / 180;

  static String _stateKey(String familyId, String childId, String fenceId) =>
      'geo_inside_${familyId}_${childId}_$fenceId';

  static Future<void> evaluateAndRecord({
    required FirebaseFirestore db,
    required String familyId,
    required String childId,
    required String childName,
    required double lat,
    required double lng,
    Map<String, dynamic>? previousLocationDoc,
    double? previousLat,
    double? previousLng,
  }) async {
    double? plat = previousLat;
    double? plng = previousLng;
    if (plat == null || plng == null) {
      plat = (previousLocationDoc?['latitude'] as num?)?.toDouble();
      plng = (previousLocationDoc?['longitude'] as num?)?.toDouble();
    }
    if (plat != null &&
        plng != null &&
        plat.abs() < 0.00001 &&
        plng.abs() < 0.00001) {
      plat = null;
      plng = null;
    }

    final prefs = await SharedPreferences.getInstance();
    final fencesSnap = await db
        .collection('families')
        .doc(familyId)
        .collection('geofences')
        .get();

    for (final doc in fencesSnap.docs) {
      final m = doc.data();
      final childIds = List<String>.from(m['childIds'] ?? []);
      if (childIds.isNotEmpty && !childIds.contains(childId)) continue;

      final centerLat = (m['centerLat'] as num?)?.toDouble() ?? 0.0;
      final centerLng = (m['centerLng'] as num?)?.toDouble() ?? 0.0;
      final radius = (m['radiusMeters'] as num?)?.toDouble() ?? 200.0;
      final name = m['name'] as String? ?? 'Bölge';
      final notifyExit = m['notifyOnExit'] != false;
      final notifyEnter = m['notifyOnEnter'] != false;

      final buffer = min(25.0, max(10.0, radius * 0.08));
      final distNow = distanceMeters(lat, lng, centerLat, centerLng);
      final isInside = distNow <= radius;
      final key = _stateKey(familyId, childId, doc.id);

      bool? wasInside;
      if (prefs.containsKey(key)) {
        wasInside = prefs.getBool(key);
      } else if (plat != null && plng != null) {
        wasInside = distanceMeters(plat, plng, centerLat, centerLng) <= radius;
      } else {
        // İlk ölçüm: olay üretme, sadece durumu kaydet
        await prefs.setBool(key, isInside);
        continue;
      }

      final exited = wasInside == true && distNow > (radius + buffer);
      final entered = wasInside == false && distNow < (radius - buffer);

      if (exited && notifyExit) {
        await _addEvent(
            db, familyId, childId, childName, name, 'exit', lat, lng);
        await prefs.setBool(key, false);
      } else if (entered && notifyEnter) {
        await _addEvent(
            db, familyId, childId, childName, name, 'enter', lat, lng);
        await prefs.setBool(key, true);
      } else if (distNow <= radius - buffer || distNow >= radius + buffer) {
        await prefs.setBool(key, isInside);
      } else if (wasInside != null) {
        await prefs.setBool(key, wasInside);
      }
    }
  }

  static Future<void> _addEvent(
    FirebaseFirestore db,
    String familyId,
    String childId,
    String childName,
    String fenceName,
    String eventType,
    double lat,
    double lng,
  ) async {
    await db
        .collection('families')
        .doc(familyId)
        .collection('geofence_events')
        .add({
      'childId': childId,
      'childName': childName,
      'fenceName': fenceName,
      'eventType': eventType,
      'latitude': lat,
      'longitude': lng,
      'timestamp': FieldValue.serverTimestamp(),
      'notified': false,
    });
  }
}
