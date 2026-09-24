import 'dart:convert';
import 'dart:math';
import 'package:http/http.dart' as http;
import '../models/models.dart';
import 'geofence_service.dart';

class RouteService {
  /// OSRM ile iki nokta arası sürüş rotası (API anahtarı gerekmez).
  static Future<List<RoutePoint>> fetchDrivingRoute({
    required double startLat,
    required double startLng,
    required double endLat,
    required double endLng,
  }) async {
    final url = Uri.parse(
      'https://router.project-osrm.org/route/v1/driving/'
      '$startLng,$startLat;$endLng,$endLat'
      '?overview=full&geometries=geojson',
    );
    final res = await http.get(url).timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) {
      throw Exception('Rota servisi yanıt vermedi (${res.statusCode})');
    }
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    if (body['code'] != 'Ok') {
      throw Exception('Rota bulunamadı');
    }
    final routes = body['routes'] as List<dynamic>?;
    if (routes == null || routes.isEmpty) {
      throw Exception('Rota bulunamadı');
    }
    final geometry = routes.first['geometry'] as Map<String, dynamic>;
    final coords = geometry['coordinates'] as List<dynamic>;
    return coords.map((c) {
      final pair = c as List<dynamic>;
      return RoutePoint(
        latitude: (pair[1] as num).toDouble(),
        longitude: (pair[0] as num).toDouble(),
      );
    }).toList();
  }

  /// Noktanın poliline’a en kısa mesafesi (metre).
  static double distanceToRouteMeters({
    required double latitude,
    required double longitude,
    required List<RoutePoint> points,
  }) {
    if (points.isEmpty) return double.infinity;
    if (points.length == 1) {
      return GeofenceService.distanceInMeters(
        latitude,
        longitude,
        points.first.latitude,
        points.first.longitude,
      );
    }

    var minDist = double.infinity;
    for (var i = 0; i < points.length - 1; i++) {
      final d = _distanceToSegmentMeters(
        latitude,
        longitude,
        points[i].latitude,
        points[i].longitude,
        points[i + 1].latitude,
        points[i + 1].longitude,
      );
      if (d < minDist) minDist = d;
    }
    return minDist;
  }

  static double _distanceToSegmentMeters(
    double lat,
    double lng,
    double lat1,
    double lng1,
    double lat2,
    double lng2,
  ) {
    // Yerel düzlem yaklaşımı (kısa mesafeler için yeterli).
    final midLat = (lat1 + lat2) / 2;
    final metersPerDegLat = 111320.0;
    final metersPerDegLng = 111320.0 * cos(midLat * pi / 180);

    final x = (lng - lng1) * metersPerDegLng;
    final y = (lat - lat1) * metersPerDegLat;
    final dx = (lng2 - lng1) * metersPerDegLng;
    final dy = (lat2 - lat1) * metersPerDegLat;
    final len2 = dx * dx + dy * dy;
    if (len2 < 1e-6) {
      return GeofenceService.distanceInMeters(lat, lng, lat1, lng1);
    }
    var t = (x * dx + y * dy) / len2;
    if (t < 0) t = 0;
    if (t > 1) t = 1;
    final projLat = lat1 + t * (lat2 - lat1);
    final projLng = lng1 + t * (lng2 - lng1);
    return GeofenceService.distanceInMeters(lat, lng, projLat, projLng);
  }
}
