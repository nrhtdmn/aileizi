import 'dart:math';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:geolocator/geolocator.dart';

/// Aktif rota takibini kontrol eder; sapma eşiği aşılınca ebeveyne event yazar.
class RouteMonitorService {
  static Future<void> checkDeviation({
    required String familyId,
    required String childId,
    required String childName,
    required Position position,
  }) async {
    final db = FirebaseFirestore.instance;
    final snap = await db
        .collection('families')
        .doc(familyId)
        .collection('routes')
        .where('childId', isEqualTo: childId)
        .get();

    for (final doc in snap.docs) {
      final data = doc.data();
      if (data['active'] != true) continue;
      final points = (data['points'] as List<dynamic>? ?? [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
      if (points.length < 2) continue;

      final threshold = (data['deviationMeters'] as num?)?.toDouble() ?? 20;
      final wasDeviated = data['isDeviated'] as bool? ?? false;
      final dist = _distanceToPolyline(
        position.latitude,
        position.longitude,
        points,
      );
      final isDeviated = dist >= threshold;

      if (isDeviated == wasDeviated) continue;

      await doc.reference.update({
        'isDeviated': isDeviated,
        'lastDistanceMeters': dist,
        'lastCheckedAt': FieldValue.serverTimestamp(),
      });
      await db
          .collection('families')
          .doc(familyId)
          .collection('route_events')
          .add({
        'childId': childId,
        'childName': childName,
        'routeId': doc.id,
        'routeName': data['name'] ?? 'Rota',
        'eventType': isDeviated ? 'deviate' : 'return',
        'distanceMeters': dist,
        'thresholdMeters': threshold,
        'latitude': position.latitude,
        'longitude': position.longitude,
        'timestamp': FieldValue.serverTimestamp(),
        'notified': false,
      });
    }
  }

  static double _distanceToPolyline(
    double lat,
    double lng,
    List<Map<String, dynamic>> points,
  ) {
    var minDist = double.infinity;
    for (var i = 0; i < points.length - 1; i++) {
      final d = _distanceToSegment(
        lat,
        lng,
        (points[i]['latitude'] as num).toDouble(),
        (points[i]['longitude'] as num).toDouble(),
        (points[i + 1]['latitude'] as num).toDouble(),
        (points[i + 1]['longitude'] as num).toDouble(),
      );
      if (d < minDist) minDist = d;
    }
    return minDist;
  }

  static double _distanceToSegment(
    double lat,
    double lng,
    double lat1,
    double lng1,
    double lat2,
    double lng2,
  ) {
    final midLat = (lat1 + lat2) / 2;
    final metersPerDegLat = 111320.0;
    final metersPerDegLng = 111320.0 * cos(midLat * pi / 180);
    final x = (lng - lng1) * metersPerDegLng;
    final y = (lat - lat1) * metersPerDegLat;
    final dx = (lng2 - lng1) * metersPerDegLng;
    final dy = (lat2 - lat1) * metersPerDegLat;
    final len2 = dx * dx + dy * dy;
    if (len2 < 1e-6) {
      return Geolocator.distanceBetween(lat, lng, lat1, lng1);
    }
    var t = (x * dx + y * dy) / len2;
    if (t < 0) t = 0;
    if (t > 1) t = 1;
    return Geolocator.distanceBetween(
      lat,
      lng,
      lat1 + t * (lat2 - lat1),
      lng1 + t * (lng2 - lng1),
    );
  }
}
