import 'package:cloud_firestore/cloud_firestore.dart';

// lib/models/family_member.dart
class FamilyMember {
  final String uid;
  final String name;
  final String role; // 'parent' | 'child'
  final String? photoUrl;
  final String? fcmToken;

  FamilyMember({
    required this.uid,
    required this.name,
    required this.role,
    this.photoUrl,
    this.fcmToken,
  });

  factory FamilyMember.fromMap(Map<String, dynamic> map) {
    return FamilyMember(
      uid: map['uid'] ?? '',
      name: map['name'] ?? '',
      role: map['role'] ?? 'child',
      photoUrl: map['photoUrl'],
      fcmToken: map['fcmToken'],
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'uid': uid,
      'name': name,
      'role': role,
      'photoUrl': photoUrl,
      'fcmToken': fcmToken,
    };
  }

  bool get isParent => role == 'parent';
  bool get isChild => role == 'child';
}

// lib/models/location_data.dart
class LocationData {
  final String childId;
  final double latitude;
  final double longitude;
  final double accuracy;
  final double? speed;
  final double? speedKmh;
  final double? heading;
  final int batteryLevel;
  final DateTime timestamp;
  final bool isOnline;
  /// phone | sim_tracker
  final String source;

  LocationData({
    required this.childId,
    required this.latitude,
    required this.longitude,
    required this.accuracy,
    this.speed,
    this.speedKmh,
    this.heading,
    required this.batteryLevel,
    required this.timestamp,
    required this.isOnline,
    this.source = 'phone',
  });

  factory LocationData.fromMap(Map<String, dynamic> map) {
    double asDouble(dynamic v) {
      if (v is num) return v.toDouble();
      if (v is String) return double.tryParse(v) ?? 0;
      return 0;
    }

    int asInt(dynamic v) {
      if (v is int) return v;
      if (v is num) return v.toInt();
      return 0;
    }

    DateTime asDate(dynamic v) {
      if (v is Timestamp) return v.toDate();
      try {
        return (v as dynamic)?.toDate() as DateTime? ?? DateTime.now();
      } catch (_) {
        return DateTime.now();
      }
    }

    final speed = map['speed'] == null ? null : asDouble(map['speed']);
    double? speedKmh =
        map['speedKmh'] == null ? null : asDouble(map['speedKmh']);
    // Eski kayıtlar: sadece m/s varsa km/sa üret
    if (speedKmh == null && speed != null && speed >= 0) {
      speedKmh = speed * 3.6;
    }

    return LocationData(
      childId: map['childId']?.toString() ?? '',
      latitude: asDouble(map['latitude']),
      longitude: asDouble(map['longitude']),
      accuracy: asDouble(map['accuracy']),
      speed: speed,
      speedKmh: speedKmh,
      heading: map['heading'] == null ? null : asDouble(map['heading']),
      batteryLevel: asInt(map['batteryLevel']),
      timestamp: asDate(map['timestamp']),
      isOnline: map['isOnline'] == true,
      source: map['source']?.toString() ?? 'phone',
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'childId': childId,
      'latitude': latitude,
      'longitude': longitude,
      'accuracy': accuracy,
      'speed': speed,
      if (speedKmh != null) 'speedKmh': speedKmh,
      'heading': heading,
      'batteryLevel': batteryLevel,
      'timestamp': timestamp,
      'isOnline': isOnline,
      'source': source,
    };
  }
}

// lib/models/sos_event.dart
class SosEvent {
  final String id;
  final String childId;
  final String childName;
  final double latitude;
  final double longitude;
  final DateTime timestamp;
  final bool acknowledged;
  final String? acknowledgedBy;

  SosEvent({
    required this.id,
    required this.childId,
    required this.childName,
    required this.latitude,
    required this.longitude,
    required this.timestamp,
    this.acknowledged = false,
    this.acknowledgedBy,
  });

  factory SosEvent.fromMap(String id, Map<String, dynamic> map) {
    return SosEvent(
      id: id,
      childId: map['childId'] ?? '',
      childName: map['childName'] ?? '',
      latitude: (map['latitude'] ?? 0).toDouble(),
      longitude: (map['longitude'] ?? 0).toDouble(),
      timestamp: map['timestamp']?.toDate() ?? DateTime.now(),
      acknowledged: map['acknowledged'] ?? false,
      acknowledgedBy: map['acknowledgedBy'],
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'childId': childId,
      'childName': childName,
      'latitude': latitude,
      'longitude': longitude,
      'timestamp': timestamp,
      'acknowledged': acknowledged,
      'acknowledgedBy': acknowledgedBy,
    };
  }
}

// lib/models/geofence.dart
class Geofence {
  final String id;
  final String name;
  final double centerLat;
  final double centerLng;
  final double radiusMeters;
  final List<String> childIds; // hangi çocuklar için
  final bool notifyOnEnter;
  final bool notifyOnExit;

  Geofence({
    required this.id,
    required this.name,
    required this.centerLat,
    required this.centerLng,
    required this.radiusMeters,
    required this.childIds,
    this.notifyOnEnter = true,
    this.notifyOnExit = true,
  });

  factory Geofence.fromMap(String id, Map<String, dynamic> map) {
    return Geofence(
      id: id,
      name: map['name'] ?? '',
      centerLat: (map['centerLat'] ?? 0).toDouble(),
      centerLng: (map['centerLng'] ?? 0).toDouble(),
      radiusMeters: (map['radiusMeters'] ?? 200).toDouble(),
      childIds: List<String>.from(map['childIds'] ?? []),
      notifyOnEnter: map['notifyOnEnter'] != false,
      notifyOnExit: map['notifyOnExit'] != false,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'name': name,
      'centerLat': centerLat,
      'centerLng': centerLng,
      'radiusMeters': radiusMeters,
      'childIds': childIds,
      'notifyOnEnter': notifyOnEnter,
      'notifyOnExit': notifyOnExit,
    };
  }
}

// lib/models/screen_stats.dart
class AppUsageStat {
  final String packageName;
  final String appName;
  final int totalTimeMinutes;
  final DateTime date;

  AppUsageStat({
    required this.packageName,
    required this.appName,
    required this.totalTimeMinutes,
    required this.date,
  });

  factory AppUsageStat.fromMap(Map<String, dynamic> map) {
    int minutes = 0;
    final raw = map['totalTimeMinutes'];
    if (raw is int) {
      minutes = raw;
    } else if (raw is num) {
      minutes = raw.toInt();
    }

    DateTime date = DateTime.now();
    final d = map['date'];
    if (d is Timestamp) {
      date = d.toDate();
    } else if (d is DateTime) {
      date = d;
    } else {
      try {
        date = (d as dynamic)?.toDate() as DateTime? ?? DateTime.now();
      } catch (_) {}
    }

    final packageName = map['packageName']?.toString() ?? '';
    final appName = map['appName']?.toString() ?? '';
    return AppUsageStat(
      packageName: packageName,
      appName: appName.isNotEmpty ? appName : packageName,
      totalTimeMinutes: minutes,
      date: date,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'packageName': packageName,
      'appName': appName,
      'totalTimeMinutes': totalTimeMinutes,
      'date': date,
    };
  }
}

/// Ebeveynin çocuk için tanımladığı dijital refah ve izleme politikaları (Android).
class ChildPolicies {
  final String childId;
  final int? dailyScreenLimitMinutes;
  final String? bedTimeStart; // "HH:mm" yerel saat
  final String? bedTimeEnd;
  final String? schoolBlockStart;
  final String? schoolBlockEnd;
  final List<int> schoolWeekdays; // 1=Mon .. 7=Sun
  final List<String> blockedPackages;
  final bool blockAdultWebsites;
  final bool youtubeRestrictedModeHint;
  final bool logBrowserSearch;
  final bool monitorCallsAndSms;
  final bool flagUnknownContacts;
  final bool socialActivityHints;

  ChildPolicies({
    required this.childId,
    this.dailyScreenLimitMinutes,
    this.bedTimeStart,
    this.bedTimeEnd,
    this.schoolBlockStart,
    this.schoolBlockEnd,
    this.schoolWeekdays = const [1, 2, 3, 4, 5],
    this.blockedPackages = const [],
    this.blockAdultWebsites = false,
    this.youtubeRestrictedModeHint = false,
    this.logBrowserSearch = false,
    this.monitorCallsAndSms = false,
    this.flagUnknownContacts = false,
    this.socialActivityHints = false,
  });

  factory ChildPolicies.fromMap(String childId, Map<String, dynamic> map) {
    return ChildPolicies(
      childId: childId,
      dailyScreenLimitMinutes: map['dailyScreenLimitMinutes'] as int?,
      bedTimeStart: map['bedTimeStart'] as String?,
      bedTimeEnd: map['bedTimeEnd'] as String?,
      schoolBlockStart: map['schoolBlockStart'] as String?,
      schoolBlockEnd: map['schoolBlockEnd'] as String?,
      schoolWeekdays: List<int>.from(map['schoolWeekdays'] ?? [1, 2, 3, 4, 5]),
      blockedPackages: List<String>.from(map['blockedPackages'] ?? []),
      blockAdultWebsites: map['blockAdultWebsites'] ?? false,
      youtubeRestrictedModeHint: map['youtubeRestrictedModeHint'] ?? false,
      logBrowserSearch: map['logBrowserSearch'] ?? false,
      monitorCallsAndSms: map['monitorCallsAndSms'] ?? false,
      flagUnknownContacts: map['flagUnknownContacts'] ?? false,
      socialActivityHints: map['socialActivityHints'] ?? false,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'childId': childId,
      'dailyScreenLimitMinutes': dailyScreenLimitMinutes,
      'bedTimeStart': bedTimeStart,
      'bedTimeEnd': bedTimeEnd,
      'schoolBlockStart': schoolBlockStart,
      'schoolBlockEnd': schoolBlockEnd,
      'schoolWeekdays': schoolWeekdays,
      'blockedPackages': blockedPackages,
      'blockAdultWebsites': blockAdultWebsites,
      'youtubeRestrictedModeHint': youtubeRestrictedModeHint,
      'logBrowserSearch': logBrowserSearch,
      'monitorCallsAndSms': monitorCallsAndSms,
      'flagUnknownContacts': flagUnknownContacts,
      'socialActivityHints': socialActivityHints,
    };
  }
}

class GeofenceEvent {
  final String id;
  final String childName;
  final String fenceName;
  final String eventType;
  final DateTime timestamp;

  GeofenceEvent({
    required this.id,
    required this.childName,
    required this.fenceName,
    required this.eventType,
    required this.timestamp,
  });

  factory GeofenceEvent.fromDoc(String id, Map<String, dynamic> map) {
    return GeofenceEvent(
      id: id,
      childName: map['childName'] ?? '',
      fenceName: map['fenceName'] ?? '',
      eventType: map['eventType'] ?? '',
      timestamp: map['timestamp']?.toDate() ?? DateTime.now(),
    );
  }
}

class ChildSummary {
  final String uid;
  final String name;
  /// phone = çocuk telefonu uygulaması, sim_tracker = GPS/SIM takip cihazı
  final String deviceType;
  final String? simNumber;
  final String? hardwareId;
  final bool chatEnabled;

  ChildSummary({
    required this.uid,
    required this.name,
    this.deviceType = 'phone',
    this.simNumber,
    this.hardwareId,
    this.chatEnabled = true,
  });

  bool get isTracker => deviceType == 'sim_tracker';
  bool get canChat => chatEnabled && !isTracker;
}

class InviteCode {
  final String code;
  final String familyId;
  final DateTime? expiresAt;
  final DateTime? createdAt;
  final bool used;
  /// phone | sim_tracker
  final String deviceKind;
  final String? suggestedName;
  final String? simNumber;
  final String? hardwareId;

  InviteCode({
    required this.code,
    required this.familyId,
    this.expiresAt,
    this.createdAt,
    this.used = false,
    this.deviceKind = 'phone',
    this.suggestedName,
    this.simNumber,
    this.hardwareId,
  });

  bool get isTracker => deviceKind == 'sim_tracker';
}

class RoutePoint {
  final double latitude;
  final double longitude;

  const RoutePoint({required this.latitude, required this.longitude});

  factory RoutePoint.fromMap(Map<String, dynamic> map) {
    return RoutePoint(
      latitude: (map['latitude'] ?? 0).toDouble(),
      longitude: (map['longitude'] ?? 0).toDouble(),
    );
  }

  Map<String, dynamic> toMap() => {
        'latitude': latitude,
        'longitude': longitude,
      };
}

/// Çocuk için takip edilen rota (manuel veya otomatik).
class TrackedRoute {
  final String id;
  final String name;
  final String childId;
  final String mode; // manual | auto | recorded
  final List<RoutePoint> points;
  final double deviationMeters;
  /// true = rota takip aktif (sapma bildirimi + haritada takip çizgisi)
  final bool active;
  final bool isDeviated;
  /// Çocuk yürüyüş kaydı devam ediyor (canlı çizim)
  final bool recording;
  final DateTime? cancelledAt;
  final String? cancelledBy; // parent | child

  TrackedRoute({
    required this.id,
    required this.name,
    required this.childId,
    required this.mode,
    required this.points,
    this.deviationMeters = 20,
    this.active = true,
    this.isDeviated = false,
    this.recording = false,
    this.cancelledAt,
    this.cancelledBy,
  });

  factory TrackedRoute.fromMap(String id, Map<String, dynamic> map) {
    final raw = map['points'] as List<dynamic>? ?? [];
    return TrackedRoute(
      id: id,
      name: map['name'] ?? 'Rota',
      childId: map['childId'] ?? '',
      mode: map['mode'] ?? 'manual',
      points: raw
          .map((e) => RoutePoint.fromMap(Map<String, dynamic>.from(e as Map)))
          .toList(),
      deviationMeters: (map['deviationMeters'] ?? 20).toDouble(),
      active: map['active'] ?? true,
      isDeviated: map['isDeviated'] ?? false,
      recording: map['recording'] == true,
      cancelledAt: map['cancelledAt']?.toDate(),
      cancelledBy: map['cancelledBy']?.toString(),
    );
  }

  Map<String, dynamic> toMap() => {
        'name': name,
        'childId': childId,
        'mode': mode,
        'points': points.map((p) => p.toMap()).toList(),
        'deviationMeters': deviationMeters,
        'active': active,
        'isDeviated': isDeviated,
        'recording': recording,
        if (cancelledAt != null) 'cancelledAt': cancelledAt,
        if (cancelledBy != null) 'cancelledBy': cancelledBy,
      };
}

class RouteEvent {
  final String id;
  final String childId;
  final String childName;
  final String routeName;
  final String eventType; // deviate | return
  final double distanceMeters;
  final double thresholdMeters;
  final DateTime timestamp;

  RouteEvent({
    required this.id,
    required this.childId,
    required this.childName,
    required this.routeName,
    required this.eventType,
    required this.distanceMeters,
    this.thresholdMeters = 20,
    required this.timestamp,
  });

  factory RouteEvent.fromDoc(String id, Map<String, dynamic> map) {
    return RouteEvent(
      id: id,
      childId: map['childId'] ?? '',
      childName: map['childName'] ?? '',
      routeName: map['routeName'] ?? '',
      eventType: map['eventType'] ?? 'deviate',
      distanceMeters: (map['distanceMeters'] ?? 0).toDouble(),
      thresholdMeters: (map['thresholdMeters'] ?? 20).toDouble(),
      timestamp: map['timestamp']?.toDate() ?? DateTime.now(),
    );
  }
}

/// Chat mesajı: text | location | image | route
class ChatMessage {
  final String id;
  final String childId;
  final String senderId;
  final String senderRole; // parent | child
  final String type;
  final String text;
  final double? latitude;
  final double? longitude;
  final String? imageUrl;
  final String? routeName;
  final List<RoutePoint> routePoints;
  final DateTime createdAt;
  final bool readByParent;
  final bool readByChild;

  ChatMessage({
    required this.id,
    required this.childId,
    required this.senderId,
    required this.senderRole,
    required this.type,
    this.text = '',
    this.latitude,
    this.longitude,
    this.imageUrl,
    this.routeName,
    this.routePoints = const [],
    required this.createdAt,
    this.readByParent = false,
    this.readByChild = false,
  });

  factory ChatMessage.fromMap(String id, Map<String, dynamic> map) {
    final rawPts = map['routePoints'] as List<dynamic>? ?? [];
    return ChatMessage(
      id: id,
      childId: map['childId'] ?? '',
      senderId: map['senderId'] ?? '',
      senderRole: map['senderRole'] ?? 'parent',
      type: map['type'] ?? 'text',
      text: map['text']?.toString() ?? '',
      latitude: map['latitude'] == null
          ? null
          : (map['latitude'] as num).toDouble(),
      longitude: map['longitude'] == null
          ? null
          : (map['longitude'] as num).toDouble(),
      imageUrl: map['imageUrl']?.toString(),
      routeName: map['routeName']?.toString(),
      routePoints: rawPts
          .map((e) => RoutePoint.fromMap(Map<String, dynamic>.from(e as Map)))
          .toList(),
      createdAt: map['createdAt']?.toDate() ?? DateTime.now(),
      readByParent: map['readByParent'] ?? false,
      readByChild: map['readByChild'] ?? false,
    );
  }

  Map<String, dynamic> toCreateMap() {
    return {
      'childId': childId,
      'senderId': senderId,
      'senderRole': senderRole,
      'type': type,
      'text': text,
      if (latitude != null) 'latitude': latitude,
      if (longitude != null) 'longitude': longitude,
      if (imageUrl != null) 'imageUrl': imageUrl,
      if (routeName != null) 'routeName': routeName,
      if (routePoints.isNotEmpty)
        'routePoints': routePoints.map((p) => p.toMap()).toList(),
      'createdAt': FieldValue.serverTimestamp(),
      'readByParent': senderRole == 'parent',
      'readByChild': senderRole == 'child',
    };
  }
}
