import 'dart:typed_data';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import '../models/chat_message.dart';

class ChildChatService {
  static final _db = FirebaseFirestore.instance;
  static final _auth = FirebaseAuth.instance;

  static Future<({String familyId, String childId, String childName})?>
      profile() async {
    final user = _auth.currentUser;
    if (user == null) return null;
    final doc = await _db.collection('users').doc(user.uid).get();
    final familyId = doc.data()?['familyId'] as String?;
    if (familyId == null || familyId.isEmpty) return null;
    return (
      familyId: familyId,
      childId: user.uid,
      childName: doc.data()?['name']?.toString() ?? 'Çocuk',
    );
  }

  static Stream<List<ChatMessage>> watchMessages(String familyId, String childId) {
    return _db
        .collection('families')
        .doc(familyId)
        .collection('chats')
        .doc(childId)
        .collection('messages')
        .orderBy('createdAt', descending: false)
        .limitToLast(200)
        .snapshots()
        .map((snap) => snap.docs
            .map((d) => ChatMessage.fromMap(d.id, d.data()))
            .toList());
  }

  static Future<void> send({
    required String familyId,
    required String childId,
    required String type,
    String text = '',
    double? latitude,
    double? longitude,
    String? imageUrl,
    String? routeName,
    List<RoutePoint> routePoints = const [],
  }) async {
    final user = _auth.currentUser;
    if (user == null) throw StateError('Oturum yok');
    await _db
        .collection('families')
        .doc(familyId)
        .collection('chats')
        .doc(childId)
        .collection('messages')
        .add({
      'childId': childId,
      'senderId': user.uid,
      'senderRole': 'child',
      'type': type,
      'text': text,
      if (latitude != null) 'latitude': latitude,
      if (longitude != null) 'longitude': longitude,
      if (imageUrl != null) 'imageUrl': imageUrl,
      if (routeName != null) 'routeName': routeName,
      if (routePoints.isNotEmpty)
        'routePoints': routePoints.map((p) => p.toMap()).toList(),
      'createdAt': FieldValue.serverTimestamp(),
      'readByParent': false,
      'readByChild': true,
    });
  }

  static Future<String> uploadImage({
    required String familyId,
    required String childId,
    required Uint8List bytes,
  }) async {
    final user = _auth.currentUser;
    if (user == null) throw StateError('Oturum yok');
    if (bytes.isEmpty) throw StateError('Fotoğraf boş.');
    if (bytes.length > 7 * 1024 * 1024) {
      throw StateError('Fotoğraf çok büyük. Daha küçük bir görsel seç.');
    }
    final name = '${DateTime.now().millisecondsSinceEpoch}_${user.uid}.jpg';
    final ref = FirebaseStorage.instance
        .ref()
        .child('families')
        .child(familyId)
        .child('chats')
        .child(childId)
        .child(name);
    try {
      await ref.putData(bytes, SettableMetadata(contentType: 'image/jpeg'));
      return await ref.getDownloadURL();
    } on FirebaseException catch (e) {
      if (e.code == 'unauthorized' || e.code == 'permission-denied') {
        throw StateError(
          'Depolama izni yok. Storage kurallarını yayınla '
          '(firebase deploy --only storage).',
        );
      }
      throw StateError('Fotoğraf yüklenemedi: ${e.code} ${e.message ?? ''}');
    }
  }

  static Future<void> markRead(String familyId, String childId) async {
    final snap = await _db
        .collection('families')
        .doc(familyId)
        .collection('chats')
        .doc(childId)
        .collection('messages')
        .where('readByChild', isEqualTo: false)
        .limit(50)
        .get();
    final batch = _db.batch();
    for (final d in snap.docs) {
      batch.update(d.reference, {'readByChild': true});
    }
    if (snap.docs.isNotEmpty) await batch.commit();
  }
}
