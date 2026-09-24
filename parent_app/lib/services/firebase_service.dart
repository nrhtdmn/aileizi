import 'dart:typed_data';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:google_sign_in/google_sign_in.dart';
import '../models/models.dart';

class FirebaseService {
  final FirebaseFirestore _db = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseMessaging _messaging = FirebaseMessaging.instance;
  final GoogleSignIn _googleSignIn = GoogleSignIn();

  User? get currentUser => _auth.currentUser;
  Stream<User?> get authStateChanges => _auth.authStateChanges();
  String? get familyId =>
      currentUser?.uid; // Ebeveyn UID'si familyId olarak kullanılır

  // ── AUTH ─────────────────────────────────────────────────────────────────

  bool _isPigeonAuthBug(Object e) {
    final s = e.toString();
    return s.contains('PigeonUserDetails') || s.contains('List<Object?>');
  }

  /// firebase_auth eklenti hatası olsa bile oturum açıldıysa başarılı say.
  Future<void> _afterAuthOk() async {
    await ensureParentProfile();
  }

  Future<void> signIn(String email, String password) async {
    try {
      await _auth.signInWithEmailAndPassword(
        email: email,
        password: password,
      );
    } on FirebaseAuthException {
      rethrow;
    } catch (e) {
      if (!_isPigeonAuthBug(e) || _auth.currentUser == null) rethrow;
    }
    await _afterAuthOk();
  }

  /// Google hesabıyla giriş (şifre gerektirmez).
  Future<void> signInWithGoogle() async {
    final googleUser = await _googleSignIn.signIn();
    if (googleUser == null) {
      throw StateError('sign_in_canceled');
    }

    final googleAuth = await googleUser.authentication;
    final credential = GoogleAuthProvider.credential(
      accessToken: googleAuth.accessToken,
      idToken: googleAuth.idToken,
    );

    try {
      await _auth.signInWithCredential(credential);
    } on FirebaseAuthException {
      rethrow;
    } catch (e) {
      if (!_isPigeonAuthBug(e) || _auth.currentUser == null) rethrow;
    }
    await _afterAuthOk();
  }

  Future<void> register(String email, String password, String name) async {
    UserCredential? cred;
    try {
      cred = await _auth.createUserWithEmailAndPassword(
        email: email,
        password: password,
      );
    } on FirebaseAuthException {
      rethrow;
    } catch (e) {
      if (!_isPigeonAuthBug(e) || _auth.currentUser == null) rethrow;
    }

    final user = cred?.user ?? _auth.currentUser;
    if (user == null) {
      throw FirebaseAuthException(
        code: 'user-not-found',
        message: 'Registration failed',
      );
    }

    try {
      await user.updateDisplayName(name);
    } catch (_) {}

    await _db.collection('users').doc(user.uid).set({
      'uid': user.uid,
      'name': name,
      'email': email,
      'role': 'parent',
      'createdAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));

    await _db.collection('families').doc(user.uid).set({
      'parentIds': [user.uid],
      'childIds': [],
      'memberIds': [user.uid],
      'createdAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  Future<void> sendPasswordResetEmail(String email) async {
    await _auth.sendPasswordResetEmail(email: email.trim());
  }

  bool get hasPasswordProvider =>
      currentUser?.providerData.any((p) => p.providerId == 'password') ??
      false;

  Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    final user = _auth.currentUser;
    final email = user?.email;
    if (user == null || email == null || email.isEmpty) {
      throw FirebaseAuthException(
        code: 'user-not-found',
        message: 'Not signed in',
      );
    }
    final cred = EmailAuthProvider.credential(
      email: email,
      password: currentPassword,
    );
    try {
      await user.reauthenticateWithCredential(cred);
    } catch (e) {
      if (!_isPigeonAuthBug(e)) rethrow;
    }
    await user.updatePassword(newPassword);
  }

  Future<void> signOut() async {
    try {
      await _googleSignIn.signOut();
    } catch (_) {
      // Google ile giriş yapılmadıysa sorun değil.
    }
    await _auth.signOut();
  }

  // ── AİLE ─────────────────────────────────────────────────────────────────

  /// Çocuk davet kodu oluştur (6 haneli)
  Future<String> createInviteCode() async {
    await ensureParentProfile();

    final code =
        (100000 + DateTime.now().millisecondsSinceEpoch % 900000).toString();
    await _db.collection('invites').doc(code).set({
      'familyId': familyId,
      'createdBy': currentUser!.uid,
      'createdAt': FieldValue.serverTimestamp(),
      'expiresAt':
          Timestamp.fromDate(DateTime.now().add(const Duration(hours: 24))),
      'used': false,
    });
    return code;
  }

  /// Eski kurulumlardan gelen hesaplarda aile/profil belgesi eksik olabilir.
  /// Ebeveyn aksiyonlarından önce minimum veriyi tamamlayarak sessiz hataları önler.
  Future<void> ensureParentProfile() async {
    final user = currentUser;
    if (user == null) {
      throw StateError('Oturum bulunamadı. Lütfen tekrar giriş yapın.');
    }

    final userRef = _db.collection('users').doc(user.uid);
    final familyRef = _db.collection('families').doc(user.uid);
    final familyExists = (await familyRef.get()).exists;
    final batch = _db.batch();

    batch.set(
      userRef,
      {
        'uid': user.uid,
        'name': (user.displayName?.trim().isNotEmpty ?? false)
            ? user.displayName
            : 'Ebeveyn',
        'email': user.email ?? '',
        'role': 'parent',
        'familyId': user.uid,
        'updatedAt': FieldValue.serverTimestamp(),
      },
      SetOptions(merge: true),
    );
    if (familyExists) {
      batch.set(
        familyRef,
        {
          'parentIds': FieldValue.arrayUnion([user.uid]),
          'memberIds': FieldValue.arrayUnion([user.uid]),
          'updatedAt': FieldValue.serverTimestamp(),
        },
        SetOptions(merge: true),
      );
    } else {
      batch.set(familyRef, {
        'parentIds': [user.uid],
        'memberIds': [user.uid],
        'childIds': <String>[],
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });
    }

    await batch.commit();
  }

  // ── KONUM ─────────────────────────────────────────────────────────────────

  /// Tüm çocukların anlık konumlarını dinle
  Stream<List<LocationData>> watchChildLocations() {
    final fid = familyId;
    if (fid == null) return Stream.value(const []);
    return _db
        .collection('families')
        .doc(fid)
        .collection('locations')
        .snapshots()
        .map((snap) => snap.docs
            .map((doc) {
              final data = Map<String, dynamic>.from(doc.data());
              data['childId'] ??= doc.id;
              return LocationData.fromMap(data);
            })
            .toList());
  }

  /// Belirli çocuğun konum geçmişi (son 24 saat)
  Future<List<LocationData>> getLocationHistory(String childId,
      {int hours = 24}) async {
    final since = DateTime.now().subtract(Duration(hours: hours));
    final snap = await _db
        .collection('families')
        .doc(familyId)
        .collection('location_history')
        .doc(childId)
        .collection('entries')
        .where('timestamp', isGreaterThan: since)
        .orderBy('timestamp', descending: false)
        .get();

    return snap.docs.map((d) => LocationData.fromMap(d.data())).toList();
  }

  // ── SOS ───────────────────────────────────────────────────────────────────

  Stream<List<SosEvent>> watchSosEvents() {
    final fid = familyId;
    if (fid == null) return Stream.value(const []);
    // orderBy index/izin sorununda yedek: sırasız dinle, istemcide sırala.
    return _db
        .collection('families')
        .doc(fid)
        .collection('sos_events')
        .limit(50)
        .snapshots()
        .map((snap) {
      final list = snap.docs
          .map((doc) => SosEvent.fromMap(doc.id, doc.data()))
          .toList();
      list.sort((a, b) => b.timestamp.compareTo(a.timestamp));
      return list.take(20).toList();
    });
  }

  Future<void> acknowledgeSos(String eventId) async {
    await _db
        .collection('families')
        .doc(familyId)
        .collection('sos_events')
        .doc(eventId)
        .update({
      'acknowledged': true,
      'acknowledgedBy': currentUser?.uid,
      'acknowledgedAt': FieldValue.serverTimestamp(),
    });
  }

  Future<void> reactivateSos(String eventId) async {
    await ensureParentProfile();
    await _db
        .collection('families')
        .doc(familyId)
        .collection('sos_events')
        .doc(eventId)
        .update({
      'acknowledged': false,
      'acknowledgedBy': FieldValue.delete(),
      'acknowledgedAt': FieldValue.delete(),
    });
  }

  Future<void> deleteSos(String eventId) async {
    await ensureParentProfile();
    await _db
        .collection('families')
        .doc(familyId)
        .collection('sos_events')
        .doc(eventId)
        .delete();
  }

  // ── GEOFENCE ──────────────────────────────────────────────────────────────

  Stream<List<Geofence>> watchGeofences() {
    return _db
        .collection('families')
        .doc(familyId)
        .collection('geofences')
        .snapshots()
        .map((snap) => snap.docs
            .map((doc) => Geofence.fromMap(doc.id, doc.data()))
            .toList());
  }

  Future<void> addGeofence(Geofence geofence) async {
    await _db
        .collection('families')
        .doc(familyId)
        .collection('geofences')
        .add(geofence.toMap());
  }

  Future<void> updateGeofence(Geofence geofence) async {
    await ensureParentProfile();
    await _db
        .collection('families')
        .doc(familyId)
        .collection('geofences')
        .doc(geofence.id)
        .update(geofence.toMap());
  }

  Future<void> deleteGeofence(String geofenceId) async {
    await _db
        .collection('families')
        .doc(familyId)
        .collection('geofences')
        .doc(geofenceId)
        .delete();
  }

  // ── ROTALAR ───────────────────────────────────────────────────────────────

  Stream<List<TrackedRoute>> watchRoutes() {
    final fid = familyId;
    if (fid == null) return Stream.value(const []);
    return _db
        .collection('families')
        .doc(fid)
        .collection('routes')
        .snapshots()
        .map((snap) => snap.docs
            .map((d) => TrackedRoute.fromMap(d.id, d.data()))
            .toList());
  }

  Future<String> addRoute(TrackedRoute route) async {
    await ensureParentProfile();
    final ref = await _db
        .collection('families')
        .doc(familyId)
        .collection('routes')
        .add({
      ...route.toMap(),
      'createdAt': FieldValue.serverTimestamp(),
    });
    return ref.id;
  }

  Future<void> setRouteActive(String routeId, bool active) async {
    await ensureParentProfile();
    await _db
        .collection('families')
        .doc(familyId)
        .collection('routes')
        .doc(routeId)
        .update({
      'active': active,
      'isDeviated': false,
      if (active) ...{
        'cancelledAt': FieldValue.delete(),
        'cancelledBy': FieldValue.delete(),
      } else ...{
        'cancelledAt': FieldValue.serverTimestamp(),
        'cancelledBy': 'parent',
      },
    });
  }

  Future<void> setRouteDeviation(String routeId, double meters) async {
    await ensureParentProfile();
    await _db
        .collection('families')
        .doc(familyId)
        .collection('routes')
        .doc(routeId)
        .update({'deviationMeters': meters});
  }

  Future<void> deleteRoute(String routeId) async {
    await ensureParentProfile();
    await _db
        .collection('families')
        .doc(familyId)
        .collection('routes')
        .doc(routeId)
        .delete();
  }

  Future<void> renameRoute(String routeId, String name) async {
    await ensureParentProfile();
    await _db
        .collection('families')
        .doc(familyId)
        .collection('routes')
        .doc(routeId)
        .update({'name': name.trim()});
  }

  Stream<List<RouteEvent>> watchUnnotifiedRouteEvents() {
    final fid = familyId;
    if (fid == null) return const Stream.empty();
    return _db
        .collection('families')
        .doc(fid)
        .collection('route_events')
        .where('notified', isEqualTo: false)
        .snapshots()
        .map((snap) => snap.docs
            .map((d) => RouteEvent.fromDoc(d.id, d.data()))
            .toList());
  }

  Future<void> markRouteEventNotified(String eventId) async {
    await _db
        .collection('families')
        .doc(familyId)
        .collection('route_events')
        .doc(eventId)
        .update({'notified': true});
  }

  // ── EKRAN İSTATİSTİKLERİ ─────────────────────────────────────────────────

  Future<List<AppUsageStat>> getScreenStats(
      String childId, DateTime date) async {
    final dateStr =
        '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
    final snap = await _db
        .collection('families')
        .doc(familyId)
        .collection('screen_stats')
        .doc(childId)
        .collection('daily')
        .doc(dateStr)
        .get();

    if (!snap.exists) return [];

    final data = snap.data()!;
    final apps = data['apps'] as List<dynamic>? ?? [];
    return apps
        .map((a) => AppUsageStat.fromMap(a as Map<String, dynamic>))
        .toList();
  }

  // ── BİLDİRİMLER ──────────────────────────────────────────────────────────

  Future<void> initNotifications() async {
    await _messaging.requestPermission(
      alert: true,
      badge: true,
      sound: true,
      announcement: true,
      criticalAlert: true,
    );
    await _messaging.setForegroundNotificationPresentationOptions(
      alert: true,
      badge: true,
      sound: true,
    );
    final token = await _messaging.getToken();
    if (token != null && currentUser != null) {
      try {
        await ensureParentProfile();
      } catch (_) {}
      await _db.collection('users').doc(currentUser!.uid).set(
        {
          'fcmToken': token,
          'fcmUpdatedAt': FieldValue.serverTimestamp(),
        },
        SetOptions(merge: true),
      );
      // set(merge) ile yarım aile belgesi oluşturmayı önle: yalnızca mevcut aileye yaz
      final familyRef = _db.collection('families').doc(currentUser!.uid);
      final fam = await familyRef.get();
      if (fam.exists) {
        await familyRef.set(
          {
            'parentFcmTokens': FieldValue.arrayUnion([token]),
          },
          SetOptions(merge: true),
        );
      }
    }
  }

  // ── ÇOCUK LİSTESİ & POLİTİKALAR ───────────────────────────────────────────

  Stream<List<ChildSummary>> watchChildren() {
    final fid = familyId;
    if (fid == null) {
      return Stream.value(const []);
    }
    return _db.collection('families').doc(fid).snapshots().asyncMap((fam) async {
      if (!fam.exists) return <ChildSummary>[];
      final childIds = List<String>.from(fam.data()?['childIds'] ?? []);
      final out = <ChildSummary>[];
      for (final id in childIds) {
        try {
          final u = await _db.collection('users').doc(id).get();
          out.add(ChildSummary(
            uid: id,
            name: u.data()?['name'] ??
                (id.length <= 6 ? id : id.substring(0, 6)),
          ));
        } catch (_) {
          out.add(ChildSummary(
            uid: id,
            name: id.length <= 6 ? id : id.substring(0, 6),
          ));
        }
      }
      return out;
    });
  }

  /// Firestore / Auth hatalarını kullanıcıya okunur metne çevir.
  static String describeError(Object e) {
    if (e is FirebaseException) {
      switch (e.code) {
        case 'permission-denied':
          return 'Firestore izni yok (permission-denied). '
              'Firebase Console’da firestore.rules yayınlanmamış olabilir. '
              'Proje kökünde: firebase login && firebase deploy --only firestore:rules';
        case 'resource-exhausted':
          return 'Firestore günlük kotası dolmuş. Pasifik gece yarısına (~10:00 TR) '
              'kadar bekle veya Firebase’de Blaze planına geç.';
        case 'unavailable':
          return 'Firestore’a ulaşılamıyor. İnternet bağlantını kontrol et.';
        case 'not-found':
          return 'Kayıt bulunamadı. Aile profili veya çocuk belgesi eksik olabilir.';
        case 'unauthenticated':
          return 'Oturum yok. Çıkış yapıp tekrar giriş dene.';
      }
      return '${e.code}: ${e.message ?? e}';
    }
    final s = e.toString();
    if (s.contains('permission-denied') || s.contains('PERMISSION_DENIED')) {
      return 'Firestore izni yok (permission-denied). '
          'Kuralları deploy et: firebase deploy --only firestore:rules';
    }
    return s;
  }

  /// Çocuk adını düzenle
  Future<void> renameChild(String childId, String newName) async {
    await ensureParentProfile();
    final name = newName.trim();
    if (name.isEmpty) throw StateError('İsim boş olamaz');
    try {
      await _db.collection('users').doc(childId).update({
        'name': name,
        'updatedAt': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      throw StateError(describeError(e));
    }
  }

  /// Çocuğu aileden çıkar (sil)
  Future<void> removeChild(String childId) async {
    await ensureParentProfile();
    final fid = familyId;
    if (fid == null) throw StateError('Aile yok');

    await _db.collection('families').doc(fid).update({
      'childIds': FieldValue.arrayRemove([childId]),
      'memberIds': FieldValue.arrayRemove([childId]),
    });

    try {
      await _db.collection('users').doc(childId).update({
        'familyId': FieldValue.delete(),
        'role': 'child',
        'locationSharingEnabled': false,
        'updatedAt': FieldValue.serverTimestamp(),
      });
    } catch (_) {}

    try {
      await _db
          .collection('families')
          .doc(fid)
          .collection('locations')
          .doc(childId)
          .delete();
    } catch (_) {}

    try {
      await _db
          .collection('families')
          .doc(fid)
          .collection('device_status')
          .doc(childId)
          .delete();
    } catch (_) {}
  }

  /// Kullanılmamış / geçerli davet kodları
  Stream<List<InviteCode>> watchActiveInvites() {
    final fid = familyId;
    if (fid == null) return Stream.value(const []);
    return _db
        .collection('invites')
        .where('familyId', isEqualTo: fid)
        .snapshots()
        .map((snap) {
      final now = DateTime.now();
      final list = <InviteCode>[];
      for (final d in snap.docs) {
        final m = d.data();
        final used = m['used'] == true;
        final exp = m['expiresAt'];
        DateTime? expiresAt;
        if (exp is Timestamp) expiresAt = exp.toDate();
        if (used) continue;
        if (expiresAt != null && expiresAt.isBefore(now)) continue;
        list.add(InviteCode(
          code: d.id,
          familyId: fid,
          expiresAt: expiresAt,
          used: false,
          createdAt: m['createdAt'] is Timestamp
              ? (m['createdAt'] as Timestamp).toDate()
              : null,
        ));
      }
      list.sort((a, b) {
        final ac = a.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
        final bc = b.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
        return bc.compareTo(ac);
      });
      return list;
    });
  }

  Future<void> deleteInvite(String code) async {
    await ensureParentProfile();
    await _db.collection('invites').doc(code).delete();
  }

  Future<ChildPolicies?> getChildPoliciesOnce(String childId) async {
    final snap = await _db
        .collection('families')
        .doc(familyId)
        .collection('child_policies')
        .doc(childId)
        .get();
    if (!snap.exists || snap.data() == null) return null;
    return ChildPolicies.fromMap(childId, snap.data()!);
  }

  Future<void> saveChildPolicies(ChildPolicies policies) async {
    await _db
        .collection('families')
        .doc(familyId)
        .collection('child_policies')
        .doc(policies.childId)
        .set({
      ...policies.toMap(),
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  Stream<ChildPolicies?> watchChildPolicies(String childId) {
    return _db
        .collection('families')
        .doc(familyId)
        .collection('child_policies')
        .doc(childId)
        .snapshots()
        .map((s) {
      if (!s.exists || s.data() == null) return null;
      return ChildPolicies.fromMap(childId, s.data()!);
    });
  }

  Stream<List<GeofenceEvent>> watchRecentGeofenceEvents({int limit = 30}) {
    return _db
        .collection('families')
        .doc(familyId)
        .collection('geofence_events')
        .orderBy('timestamp', descending: true)
        .limit(limit)
        .snapshots()
        .map((snap) => snap.docs
            .map((d) => GeofenceEvent.fromDoc(d.id, d.data()))
            .toList());
  }

  /// Bildirim gösterilmemiş geofence olayları (ebeveyn uygulaması dinler).
  Stream<List<GeofenceEvent>> watchUnnotifiedGeofenceEvents() {
    final fid = familyId;
    if (fid == null) return const Stream.empty();
    return _db
        .collection('families')
        .doc(fid)
        .collection('geofence_events')
        .where('notified', isEqualTo: false)
        .snapshots()
        .map((snap) => snap.docs
            .map((d) => GeofenceEvent.fromDoc(d.id, d.data()))
            .toList());
  }

  Future<void> markGeofenceEventNotified(String eventId) async {
    await _db
        .collection('families')
        .doc(familyId)
        .collection('geofence_events')
        .doc(eventId)
        .update({'notified': true});
  }

  /// Son [days] gün için günlük toplam ekran dakikası (screen_stats üzerinden).
  Future<List<MapEntry<DateTime, int>>> getScreenTimeDailySeries(
    String childId,
    int days,
  ) async {
    final out = <MapEntry<DateTime, int>>[];
    final now = DateTime.now();
    for (var i = 0; i < days; i++) {
      final d =
          DateTime(now.year, now.month, now.day).subtract(Duration(days: i));
      final dateStr =
          '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
      final snap = await _db
          .collection('families')
          .doc(familyId)
          .collection('screen_stats')
          .doc(childId)
          .collection('daily')
          .doc(dateStr)
          .get();
      var total = 0;
      if (snap.exists) {
        final apps = snap.data()?['apps'] as List<dynamic>? ?? [];
        for (final a in apps) {
          final m = a as Map<String, dynamic>;
          total += (m['totalTimeMinutes'] as int?) ?? 0;
        }
      }
      out.add(MapEntry(d, total));
    }
    return out.reversed.toList();
  }

  Future<void> reportSuspiciousActivity({
    required String childId,
    required String childName,
    required String reason,
    Map<String, dynamic>? extra,
  }) async {
    await _db
        .collection('families')
        .doc(familyId)
        .collection('suspicious_events')
        .add({
      'childId': childId,
      'childName': childName,
      'reason': reason,
      'extra': extra ?? {},
      'timestamp': FieldValue.serverTimestamp(),
      'notified': false,
    });
  }

  // ── MESAJLAR ─────────────────────────────────────────────────────────────

  CollectionReference<Map<String, dynamic>> _chatMessages(String childId) {
    return _db
        .collection('families')
        .doc(familyId)
        .collection('chats')
        .doc(childId)
        .collection('messages');
  }

  Stream<List<ChatMessage>> watchChatMessages(String childId) {
    return _chatMessages(childId)
        .orderBy('createdAt', descending: false)
        .limitToLast(200)
        .snapshots()
        .map((snap) => snap.docs
            .map((d) => ChatMessage.fromMap(d.id, d.data()))
            .toList());
  }

  Future<void> sendChatMessage(ChatMessage draft) async {
    await ensureParentProfile();
    await _chatMessages(draft.childId).add(draft.toCreateMap());
  }

  Future<String> uploadChatImage({
    required String childId,
    required List<int> bytes,
    required String contentType,
  }) async {
    await ensureParentProfile();
    final fid = familyId;
    final uid = currentUser?.uid;
    if (fid == null || uid == null) {
      throw StateError('Oturum veya aile bulunamadı.');
    }
    if (bytes.isEmpty) {
      throw StateError('Fotoğraf boş.');
    }
    // ~8 MB Storage kural limitinin altında kalsın
    if (bytes.length > 7 * 1024 * 1024) {
      throw StateError('Fotoğraf çok büyük. Daha küçük bir görsel seç.');
    }
    final name = '${DateTime.now().millisecondsSinceEpoch}_$uid.jpg';
    final ref = FirebaseStorage.instance
        .ref()
        .child('families')
        .child(fid)
        .child('chats')
        .child(childId)
        .child(name);
    try {
      await ref.putData(
        Uint8List.fromList(bytes),
        SettableMetadata(
          contentType:
              contentType.isEmpty ? 'image/jpeg' : contentType,
        ),
      );
      return await ref.getDownloadURL();
    } on FirebaseException catch (e) {
      if (e.code == 'unauthorized' || e.code == 'permission-denied') {
        throw StateError(
          'Depolama izni yok. Firebase Console’da Storage’ı açıp '
          'storage.rules dosyasını deploy et '
          '(firebase deploy --only storage).',
        );
      }
      if (e.code == 'retry-limit-exceeded' || e.code == 'unknown') {
        throw StateError(
          'Yükleme başarısız (${e.code}). İnterneti kontrol et veya '
          'Firestore/Storage kotasının dolmadığından emin ol.',
        );
      }
      throw StateError('Fotoğraf yüklenemedi: ${e.code} ${e.message ?? ''}');
    }
  }

  Future<void> markChatReadByParent(String childId) async {
    final snap = await _chatMessages(childId)
        .where('readByParent', isEqualTo: false)
        .limit(50)
        .get();
    final batch = _db.batch();
    for (final d in snap.docs) {
      batch.update(d.reference, {'readByParent': true});
    }
    if (snap.docs.isNotEmpty) await batch.commit();
  }

  /// Çocuktan gelen, ebeveynin henüz okumadığı mesajlar
  Stream<List<ChatMessage>> watchUnreadChatFromChild(String childId) {
    return _chatMessages(childId)
        .where('readByParent', isEqualTo: false)
        .snapshots()
        .map((snap) => snap.docs
            .map((d) => ChatMessage.fromMap(d.id, d.data()))
            .where((m) => m.senderRole == 'child')
            .toList());
  }

  Stream<ChatMessage?> watchLatestChatMessage(String childId) {
    return _chatMessages(childId)
        .orderBy('createdAt', descending: true)
        .limit(1)
        .snapshots()
        .map((snap) {
      if (snap.docs.isEmpty) return null;
      return ChatMessage.fromMap(snap.docs.first.id, snap.docs.first.data());
    });
  }

  Stream<int> watchUnreadChatCount(String childId) {
    return watchUnreadChatFromChild(childId).map((list) => list.length);
  }
}
