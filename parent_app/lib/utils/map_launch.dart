import 'package:url_launcher/url_launcher.dart';
import '../models/models.dart';

/// Rotayı / konumu telefonun harita uygulamasında açar.
class MapLaunch {
  static Future<bool> openLocation(double lat, double lng, {String? label}) async {
    final q = Uri.encodeComponent(label ?? '$lat,$lng');
    final uri = Uri.parse(
      'https://www.google.com/maps/search/?api=1&query=$lat,$lng&query_place_id=&q=$q',
    );
    final geo = Uri.parse('geo:$lat,$lng?q=$lat,$lng(${Uri.encodeComponent(label ?? 'Konum')})');
    if (await canLaunchUrl(geo)) {
      return launchUrl(geo, mode: LaunchMode.externalApplication);
    }
    return launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  /// Yol tarifi: mevcut konumdan hedefe (Google Haritalar / sistem haritası).
  static Future<bool> openDirections(
    double lat,
    double lng, {
    String? label,
  }) async {
    final destLabel = Uri.encodeComponent(label ?? 'Hedef');
    final dir = Uri.parse(
      'https://www.google.com/maps/dir/?api=1'
      '&destination=$lat,$lng'
      '&destination_place_id='
      '&travelmode=driving',
    );
    final geo = Uri.parse(
      'google.navigation:q=$lat,$lng',
    );
    try {
      if (await canLaunchUrl(geo)) {
        return launchUrl(geo, mode: LaunchMode.externalApplication);
      }
    } catch (_) {}
    try {
      final geoQ = Uri.parse(
        'geo:0,0?q=$lat,$lng($destLabel)',
      );
      if (await canLaunchUrl(geoQ)) {
        return launchUrl(geoQ, mode: LaunchMode.externalApplication);
      }
    } catch (_) {}
    return launchUrl(dir, mode: LaunchMode.externalApplication);
  }

  /// Rota noktalarını Google Maps yol tarifi olarak açar.
  static Future<bool> openRoute(List<RoutePoint> points, {String? name}) async {
    if (points.isEmpty) return false;
    if (points.length == 1) {
      return openLocation(points.first.latitude, points.first.longitude,
          label: name);
    }

    final origin = points.first;
    final dest = points.last;
    // Google Maps waypoint limiti ~10; aradan örnekle.
    final middles = <RoutePoint>[];
    if (points.length > 2) {
      final mid = points.sublist(1, points.length - 1);
      const maxWp = 8;
      if (mid.length <= maxWp) {
        middles.addAll(mid);
      } else {
        for (var i = 0; i < maxWp; i++) {
          final idx = ((i + 1) * mid.length / (maxWp + 1)).floor();
          middles.add(mid[idx.clamp(0, mid.length - 1)]);
        }
      }
    }

    final wp = middles
        .map((p) => '${p.latitude},${p.longitude}')
        .join('|');
    final uri = Uri.parse(
      'https://www.google.com/maps/dir/?api=1'
      '&origin=${origin.latitude},${origin.longitude}'
      '&destination=${dest.latitude},${dest.longitude}'
      '${wp.isNotEmpty ? '&waypoints=$wp' : ''}'
      '&travelmode=walking',
    );
    return launchUrl(uri, mode: LaunchMode.externalApplication);
  }
}
