import 'dart:math';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/models.dart';

class GeofenceService {
  /// İki koordinat arasındaki mesafeyi metre cinsinden hesapla (Haversine)
  static double distanceInMeters(
    double lat1,
    double lon1,
    double lat2,
    double lon2,
  ) {
    const earthRadius = 6371000.0; // metre
    final dLat = _toRad(lat2 - lat1);
    final dLon = _toRad(lon2 - lon1);

    final a = sin(dLat / 2) * sin(dLat / 2) +
        cos(_toRad(lat1)) * cos(_toRad(lat2)) * sin(dLon / 2) * sin(dLon / 2);

    final c = 2 * atan2(sqrt(a), sqrt(1 - a));
    return earthRadius * c;
  }

  static double _toRad(double deg) => deg * pi / 180;

  /// Konum güncellenmesinde geofence kontrolü yap
  static Future<void> checkGeofences({
    required List<Geofence> geofences,
    required LocationData newLocation,
    required LocationData? previousLocation,
    required String childName,
    required String familyId,
    required FirebaseFirestore db,
  }) async {
    for (final fence in geofences) {
      // Boş liste = tüm çocuklara uygulanır.
      if (fence.childIds.isNotEmpty &&
          !fence.childIds.contains(newLocation.childId)) continue;

      final distNow = distanceInMeters(
        newLocation.latitude,
        newLocation.longitude,
        fence.centerLat,
        fence.centerLng,
      );

      final isInsideNow = distNow <= fence.radiusMeters;

      if (previousLocation != null) {
        final distPrev = distanceInMeters(
          previousLocation.latitude,
          previousLocation.longitude,
          fence.centerLat,
          fence.centerLng,
        );
        final wasInsidePrev = distPrev <= fence.radiusMeters;

        // Bölgeden çıktı
        if (wasInsidePrev && !isInsideNow && fence.notifyOnExit) {
          await _createGeofenceEvent(
            db: db,
            familyId: familyId,
            childId: newLocation.childId,
            childName: childName,
            fenceName: fence.name,
            eventType: 'exit',
            location: newLocation,
          );
        }

        // Bölgeye girdi
        if (!wasInsidePrev && isInsideNow && fence.notifyOnEnter) {
          await _createGeofenceEvent(
            db: db,
            familyId: familyId,
            childId: newLocation.childId,
            childName: childName,
            fenceName: fence.name,
            eventType: 'enter',
            location: newLocation,
          );
        }
      }
    }
  }

  static Future<void> _createGeofenceEvent({
    required FirebaseFirestore db,
    required String familyId,
    required String childId,
    required String childName,
    required String fenceName,
    required String eventType, // 'enter' | 'exit'
    required LocationData location,
  }) async {
    await db
        .collection('families')
        .doc(familyId)
        .collection('geofence_events')
        .add({
      'childId': childId,
      'childName': childName,
      'fenceName': fenceName,
      'eventType': eventType,
      'latitude': location.latitude,
      'longitude': location.longitude,
      'timestamp': FieldValue.serverTimestamp(),
      'notified': false,
    });
  }
}
