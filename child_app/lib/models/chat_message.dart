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

class ChatMessage {
  final String id;
  final String childId;
  final String senderId;
  final String senderRole;
  final String type;
  final String text;
  final double? latitude;
  final double? longitude;
  final String? imageUrl;
  final String? routeName;
  final List<RoutePoint> routePoints;
  final DateTime createdAt;

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
    );
  }
}
