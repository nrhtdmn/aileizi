import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:geolocator/geolocator.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../brand.dart';
import '../l10n/app_locale.dart';

class JoinScreen extends StatefulWidget {
  const JoinScreen({super.key});

  @override
  State<JoinScreen> createState() => _JoinScreenState();
}

class _JoinScreenState extends State<JoinScreen> {
  final _nameCtrl = TextEditingController();
  final _codeCtrl = TextEditingController();
  bool _loading = false;
  bool _consentAccepted = false;
  String? _error;

  Future<void> _joinFamily() async {
    final l10n = context.read<AppLocale>();
    final name = _nameCtrl.text.trim();
    final code = _codeCtrl.text.trim();

    if (name.isEmpty || code.isEmpty) {
      setState(() => _error = l10n.t('fill_all'));
      return;
    }
    if (!_consentAccepted) {
      setState(() => _error = l10n.t('consent_required'));
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final db = FirebaseFirestore.instance;

      // Oturum yoksa aç (normalde main'de açılmış olur; formu bozmaz).
      var user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        final cred = await FirebaseAuth.instance.signInAnonymously();
        user = cred.user;
      }
      if (user == null) {
        throw Exception('Oturum açılamadı. İnterneti kontrol edip tekrar dene.');
      }
      final uid = user.uid;

      final inviteDoc = await db.collection('invites').doc(code).get();
      if (!inviteDoc.exists) {
        throw Exception('Geçersiz davet kodu');
      }

      final inviteData = inviteDoc.data()!;
      if (inviteData['used'] == true) {
        throw Exception('Bu kod zaten kullanılmış. Parent uygulamadan yeni kod oluştur.');
      }

      final expiresRaw = inviteData['expiresAt'];
      DateTime? expiresAt;
      if (expiresRaw is Timestamp) {
        expiresAt = expiresRaw.toDate();
      } else if (expiresRaw != null) {
        try {
          expiresAt = (expiresRaw as dynamic).toDate() as DateTime;
        } catch (_) {
          expiresAt = null;
        }
      }
      if (expiresAt != null && DateTime.now().isAfter(expiresAt)) {
        throw Exception('Davet kodunun süresi dolmuş. Yeni kod iste.');
      }

      final familyId = inviteData['familyId'] as String?;
      if (familyId == null || familyId.isEmpty) {
        throw Exception('Davet kodunda aile bilgisi yok');
      }

      // Not: Aile belgesi okunmaz (çocuk henüz üye değil; kurallar get'e izin vermez).
      // Doğrudan güncelleme denenir; yoksa izin/aile hatası gelir.

      // 1) Çocuk profili
      await db.collection('users').doc(uid).set({
        'uid': uid,
        'name': name,
        'role': 'child',
        'familyId': familyId,
        'locationSharingEnabled': true,
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('cached_family_id', familyId);
        await prefs.setBool('location_sharing_enabled', true);
        await prefs.setString('cached_child_name', name);
      } catch (_) {}

      // 2) Aileye ekle (davet işaretlemeden önce)
      try {
        await db.collection('families').doc(familyId).update({
          'childIds': FieldValue.arrayUnion([uid]),
          'memberIds': FieldValue.arrayUnion([uid]),
        });
      } catch (e) {
        final em = e.toString();
        if (em.contains('permission-denied') ||
            em.contains('PERMISSION_DENIED') ||
            em.contains('not-found')) {
          throw Exception(
            'Aileye eklenemedi. Firebase Console → Firestore → Rules '
            'içinde güncel kuralları Publish ettiğinden emin ol '
            '(firebase_rules/firestore.rules). Sonra yeni davet kodu al.',
          );
        }
        rethrow;
      }

      // 3) Daveti kullanıldı yap (artık çocuk ailede; eski/yeni kurallarla uyumlu)
      try {
        await db.collection('invites').doc(code).update({'used': true});
      } catch (_) {
        // Aileye ekleme başarılıysa davet işaretlenmese de devam et.
      }

      // 4) İlk konum (parent hemen görsün)
      await _writeInitialLocation(db: db, familyId: familyId, childId: uid);

      // ProfileGate stream familyId'yi görünce ana ekrana geçer.
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Aileye katıldın!')),
        );
      }
    } catch (e) {
      final msg = e.toString();
      String friendly = msg;
      if (msg.contains('permission-denied') ||
          msg.contains('PERMISSION_DENIED')) {
        friendly =
            'İzin hatası: Firestore kuralları güncel değil veya davet kodu geçersiz. '
            'Parent Firebase Console\'da Rules yayınlandı mı kontrol et.';
      } else if (msg.contains('network') || msg.contains('Unavailable')) {
        friendly = 'İnternet bağlantısı yok. Bağlantıyı kontrol edip tekrar dene.';
      } else {
        friendly = msg.replaceFirst('Exception: ', '');
      }
      if (mounted) setState(() => _error = friendly);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _writeInitialLocation({
    required FirebaseFirestore db,
    required String familyId,
    required String childId,
  }) async {
    try {
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }

      Position? position;
      if (permission != LocationPermission.denied &&
          permission != LocationPermission.deniedForever) {
        position = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high,
            timeLimit: Duration(seconds: 8),
          ),
        ).timeout(const Duration(seconds: 10));
      }

      await db
          .collection('families')
          .doc(familyId)
          .collection('locations')
          .doc(childId)
          .set({
        'childId': childId,
        'latitude': position?.latitude ?? 0.0,
        'longitude': position?.longitude ?? 0.0,
        'accuracy': position?.accuracy ?? 0.0,
        'speed': position?.speed,
        'heading': position?.heading,
        'batteryLevel': -1,
        'timestamp': FieldValue.serverTimestamp(),
        'isOnline': position != null,
        'hasLocation': position != null,
      }, SetOptions(merge: true));
    } catch (_) {
      try {
        await db
            .collection('families')
            .doc(familyId)
            .collection('locations')
            .doc(childId)
            .set({
          'childId': childId,
          'latitude': 0.0,
          'longitude': 0.0,
          'accuracy': 0.0,
          'batteryLevel': -1,
          'timestamp': FieldValue.serverTimestamp(),
          'isOnline': false,
          'hasLocation': false,
        }, SetOptions(merge: true));
      } catch (_) {}
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _codeCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.watch<AppLocale>();
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color(0xFF2A6F97),
              Color(0xFF4A90D9),
              Color(0xFFE8F4FC),
            ],
            stops: [0.0, 0.45, 1.0],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                children: [
                  Align(
                    alignment: Alignment.centerRight,
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.25),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _LangChip(
                            label: 'TR',
                            selected: l10n.isTr,
                            onTap: () => l10n.setLanguageCode('tr'),
                          ),
                          _LangChip(
                            label: 'EN',
                            selected: !l10n.isTr,
                            onTap: () => l10n.setLanguageCode('en'),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  BrandHero(
                    logoAsset: 'assets/brand/launcher.png',
                    subtitle: l10n.t('join_title'),
                  ),
                  const SizedBox(height: 36),
                  Card(
                    elevation: 8,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            l10n.isTr
                                ? 'Ebeveyninden aldığın kodu gir'
                                : 'Enter the code from your parent',
                            style: const TextStyle(color: Colors.grey),
                          ),
                          const SizedBox(height: 16),
                          TextField(
                            controller: _nameCtrl,
                            decoration: InputDecoration(
                              labelText: l10n.t('child_name'),
                              prefixIcon: const Icon(Icons.person),
                              border: const OutlineInputBorder(),
                            ),
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: _codeCtrl,
                            keyboardType: TextInputType.number,
                            maxLength: 6,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              fontSize: 24,
                              letterSpacing: 8,
                              fontWeight: FontWeight.bold,
                            ),
                            decoration: InputDecoration(
                              labelText: l10n.t('invite_code'),
                              border: const OutlineInputBorder(),
                              counterText: '',
                            ),
                          ),
                          const SizedBox(height: 12),
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: Colors.blue.shade50,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: Colors.blue.shade100),
                            ),
                            child: Text(
                              l10n.isTr
                                  ? 'Bu uygulama, ailenin güvenlik amacıyla konumunu, '
                                      'batarya durumunu, SOS uyarılarını ve izin verirsen '
                                      'ekran kullanım özetini ebeveyn uygulamasına gönderir. '
                                      'Konum paylaşımını ana ekrandan kapatabilirsin.'
                                  : 'This app shares location, battery, SOS alerts and '
                                      '(if allowed) screen-time summaries with the parent app '
                                      'for family safety. You can turn off location sharing '
                                      'from the home screen.',
                              style: const TextStyle(
                                  fontSize: 12, color: Colors.black87),
                            ),
                          ),
                          CheckboxListTile(
                            contentPadding: EdgeInsets.zero,
                            value: _consentAccepted,
                            onChanged: (value) {
                              setState(() => _consentAccepted = value ?? false);
                            },
                            title: Text(
                              l10n.t('consent'),
                              style: const TextStyle(fontSize: 13),
                            ),
                            controlAffinity: ListTileControlAffinity.leading,
                          ),
                          if (_error != null) ...[
                            const SizedBox(height: 8),
                            Text(
                              _error!,
                              style: const TextStyle(color: Colors.red),
                            ),
                          ],
                          const SizedBox(height: 24),
                          ElevatedButton(
                            onPressed: _loading ? null : _joinFamily,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF4A90D9),
                              foregroundColor: Colors.white,
                              padding:
                                  const EdgeInsets.symmetric(vertical: 16),
                            ),
                            child: _loading
                                ? const SizedBox(
                                    height: 20,
                                    width: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white,
                                    ),
                                  )
                                : Text(l10n.t('join')),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _LangChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _LangChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.all(4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? Colors.white : Colors.transparent,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontWeight: FontWeight.bold,
            color: selected ? const Color(0xFF2A6F97) : Colors.white,
          ),
        ),
      ),
    );
  }
}
