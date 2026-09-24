import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/background_service.dart';
import '../services/location_upload_service.dart';
import '../services/screen_stats_service.dart';
import '../services/child_notification_service.dart';
import '../utils/chat_helpers.dart';
import '../utils/policy_evaluator.dart';
import 'child_chat_screen.dart';
import 'child_routes_screen.dart';
import 'trail_record_screen.dart';

class ChildHomeScreen extends StatefulWidget {
  const ChildHomeScreen({super.key});

  @override
  State<ChildHomeScreen> createState() => _ChildHomeScreenState();
}

class _ChildHomeScreenState extends State<ChildHomeScreen>
    with WidgetsBindingObserver {
  bool _sosPressed = false;
  bool _isSharing = true;
  Timer? _sosTimer;
  int _sosCountdown = 3;
  String? _childName;
  String? _familyId;
  bool _quietHoursLock = false;
  bool _dailyLimitLock = false;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _policySub;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _chatSub;
  Timer? _limitCheckTimer;
  Timer? _locationTimer;
  bool _locationUploading = false;
  String _locationStatus = 'Konum henüz gönderilmedi';
  DateTime? _lastLocationSentAt;
  bool _usagePermissionGranted = false;
  String _screenStatsStatus = 'Ekran süresi henüz gönderilmedi';
  Timer? _screenStatsTimer;
  bool _chatSeeded = false;
  final Set<String> _chatSeen = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadProfile();
    _refreshScreenStats();
    _initChatNotifications();
    _limitCheckTimer = Timer.periodic(
        const Duration(minutes: 2), (_) => _checkDailyScreenLimit());
    _screenStatsTimer = Timer.periodic(
        const Duration(minutes: 15), (_) => _refreshScreenStats());
  }

  Future<void> _initChatNotifications() async {
    await ChildNotificationService.instance.init();
    ChildNotificationService.onPayload = (payload) {
      if (!mounted) return;
      if (payload == 'chat' || payload.startsWith('chat')) {
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const ChildChatScreen()),
        );
      }
    };
    final pending = ChildNotificationService.instance.takePendingPayload();
    if (pending != null && mounted) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const ChildChatScreen()),
        );
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      final pending = ChildNotificationService.instance.takePendingPayload();
      if (pending != null && mounted) {
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const ChildChatScreen()),
        );
      }
    }
  }

  void _bindChatWatch(String familyId, String childId) {
    _chatSub?.cancel();
    _chatSeeded = false;
    _chatSeen.clear();
    _chatSub = FirebaseFirestore.instance
        .collection('families')
        .doc(familyId)
        .collection('chats')
        .doc(childId)
        .collection('messages')
        .where('readByChild', isEqualTo: false)
        .snapshots()
        .listen((snap) async {
      final notif = ChildNotificationService.instance;
      final fromParent = snap.docs.where((d) {
        return d.data()['senderRole']?.toString() == 'parent';
      }).toList();

      if (!_chatSeeded) {
        for (final d in fromParent) {
          _chatSeen.add(d.id);
        }
        _chatSeeded = true;
        return;
      }

      for (final d in fromParent) {
        if (_chatSeen.contains(d.id)) continue;
        _chatSeen.add(d.id);
        final key = 'chat_${d.id}';
        if (await notif.wasShown(key)) continue;
        final data = d.data();
        final preview = chatPreviewText(
          data['type']?.toString() ?? 'text',
          data['text']?.toString() ?? '',
          routeName: data['routeName']?.toString(),
        );
        await notif.showChat(messageId: d.id, preview: preview);
        await notif.markShown(key);
      }
    });
  }

  Future<void> _refreshScreenStats() async {
    final granted = await ScreenStatsService.requestPermissionCheckOnly();
    if (!mounted) return;
    setState(() => _usagePermissionGranted = granted);
    if (!granted) {
      setState(() =>
          _screenStatsStatus = 'Kullanım erişimi kapalı — ebeveyn göremez');
      return;
    }
    final ok = await ScreenStatsService.uploadDailyStats();
    if (!mounted) return;
    final now = DateTime.now();
    final time =
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
    setState(() {
      _screenStatsStatus = ok
          ? 'Ekran süresi gönderildi • $time'
          : 'Ekran süresi gönderilemedi (veri yok veya hata)';
    });
  }

  Future<void> _openUsagePermission() async {
    await ScreenStatsService.requestPermission();
    await Future.delayed(const Duration(seconds: 1));
    await _refreshScreenStats();
  }

  Future<void> _loadProfile() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final doc = await FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .get();

    final familyId = doc.data()?['familyId'] as String?;

    setState(() {
      _childName = doc.data()?['name'] ?? 'Çocuk';
      _familyId = familyId;
      _isSharing = doc.data()?['locationSharingEnabled'] as bool? ?? true;
    });

    await _policySub?.cancel();
    if (familyId != null) {
      await _ensureFamilyMembership(familyId, user.uid);
      _bindChatWatch(familyId, user.uid);
      _policySub = FirebaseFirestore.instance
          .collection('families')
          .doc(familyId)
          .collection('child_policies')
          .doc(user.uid)
          .snapshots()
          .listen((snap) {
        final locked = PolicyEvaluator.isQuietHoursLocked(snap.data());
        if (mounted) setState(() => _quietHoursLock = locked);
      });
    }
    await _syncMessagingToken(user.uid);
    await _checkDailyScreenLimit();
    await _startLocationSharing();
  }

  Future<void> _startLocationSharing() async {
    if (!_isSharing) return;
    await LocationUploadService.ensurePermission();
    final perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.whileInUse && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Ekran kapalıyken konum için izni «Her zaman izin ver» yapın. '
            'Ayarlar → Konum → Aileİzi Çocuk.',
          ),
          duration: Duration(seconds: 6),
        ),
      );
    }
    await startLocationBackgroundService();
    await _pushLocationNow();
    _locationTimer?.cancel();
    _locationTimer = Timer.periodic(const Duration(seconds: 20), (_) {
      _pushLocationNow();
    });
  }

  Future<void> _pushLocationNow() async {
    if (!_isSharing || _locationUploading) return;
    setState(() => _locationUploading = true);
    try {
      final ok = await LocationUploadService.uploadOnce(familyId: _familyId);
      if (!mounted) return;
      setState(() {
        if (ok) {
          _lastLocationSentAt = DateTime.now();
          _locationStatus =
              'Konum gönderildi • ${_lastLocationSentAt!.hour.toString().padLeft(2, '0')}:${_lastLocationSentAt!.minute.toString().padLeft(2, '0')}:${_lastLocationSentAt!.second.toString().padLeft(2, '0')}';
        } else {
          _locationStatus =
              'Konum alınamadı. Konum iznini / GPS’i açıp tekrar dene.';
        }
      });
    } catch (e) {
      if (mounted) {
        setState(() => _locationStatus = 'Konum gönderilemedi: $e');
      }
    } finally {
      if (mounted) setState(() => _locationUploading = false);
    }
  }

  Future<void> _ensureFamilyMembership(String familyId, String uid) async {
    try {
      await FirebaseFirestore.instance.collection('families').doc(familyId).set({
        'childIds': FieldValue.arrayUnion([uid]),
        'memberIds': FieldValue.arrayUnion([uid]),
      }, SetOptions(merge: true));
    } catch (_) {
      // Kurallar henüz yayınlanmadıysa veya üyelik zaten tamamsa ana akış sürer.
    }
  }

  Future<void> _syncMessagingToken(String uid) async {
    try {
      await FirebaseMessaging.instance.requestPermission();
      final token = await FirebaseMessaging.instance.getToken();
      if (token == null) return;

      await FirebaseFirestore.instance.collection('users').doc(uid).set({
        'fcmToken': token,
      }, SetOptions(merge: true));
    } catch (_) {
      // Push hazırlığı başarısız olsa bile ana takip akışı devam etmeli.
    }
  }

  Future<void> _checkDailyScreenLimit() async {
    final user = FirebaseAuth.instance.currentUser;
    final familyId = _familyId;
    if (user == null || familyId == null) return;

    final pol = await FirebaseFirestore.instance
        .collection('families')
        .doc(familyId)
        .collection('child_policies')
        .doc(user.uid)
        .get();
    final limit = pol.data()?['dailyScreenLimitMinutes'] as int?;
    if (limit == null) {
      if (mounted) setState(() => _dailyLimitLock = false);
      return;
    }

    final now = DateTime.now();
    final dateStr =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    final stat = await FirebaseFirestore.instance
        .collection('families')
        .doc(familyId)
        .collection('screen_stats')
        .doc(user.uid)
        .collection('daily')
        .doc(dateStr)
        .get();
    final total = stat.data()?['totalMinutes'] as int? ?? 0;
    if (mounted) setState(() => _dailyLimitLock = total >= limit);
  }

  Future<void> _setLocationSharing(bool enabled) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    setState(() => _isSharing = enabled);
    try {
      await FirebaseFirestore.instance.collection('users').doc(user.uid).set({
        'locationSharingEnabled': enabled,
      }, SetOptions(merge: true));
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('location_sharing_enabled', enabled);
      if (enabled) {
        await _startLocationSharing();
      } else {
        _locationTimer?.cancel();
        if (mounted) {
          setState(() => _locationStatus = 'Konum paylaşımı kapalı');
        }
      }
    } catch (_) {
      if (mounted) setState(() => _isSharing = !enabled);
    }
  }

  void _startSos() {
    if (_sosPressed) return;
    setState(() {
      _sosPressed = true;
      _sosCountdown = 3;
    });

    _sosTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      setState(() => _sosCountdown--);

      if (_sosCountdown <= 0) {
        timer.cancel();
        _sendSos();
      }
    });
  }

  void _cancelSos() {
    _sosTimer?.cancel();
    setState(() {
      _sosPressed = false;
      _sosCountdown = 3;
    });
  }

  Future<void> _sendSos() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      if (mounted) setState(() => _sosPressed = false);
      return;
    }

    var familyId = _familyId;
    var childName = _childName ?? 'Çocuk';
    if (familyId == null) {
      final doc = await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .get();
      familyId = doc.data()?['familyId'] as String?;
      childName = doc.data()?['name'] as String? ?? childName;
      if (mounted) {
        setState(() {
          _familyId = familyId;
          _childName = childName;
        });
      }
    }
    if (familyId == null) {
      if (mounted) {
        setState(() => _sosPressed = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Aile bağlantısı bulunamadı.')),
        );
      }
      return;
    }

    try {
      final position = await _getSosPosition();

      await FirebaseFirestore.instance
          .collection('families')
          .doc(familyId)
          .collection('sos_events')
          .add({
        'childId': user.uid,
        'childName': childName,
        'latitude': position?.latitude ?? 0.0,
        'longitude': position?.longitude ?? 0.0,
        'hasLocation': position != null,
        'timestamp': FieldValue.serverTimestamp(),
        'acknowledged': false,
      });

      if (mounted) {
        setState(() => _sosPressed = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('SOS gönderildi! Ebeveynin bilgilendirildi.'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _sosPressed = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Hata: $e')),
        );
      }
    } finally {
      if (mounted && _sosPressed) {
        setState(() => _sosPressed = false);
      }
    }
  }

  Future<Position?> _getSosPosition() async {
    try {
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return await Geolocator.getLastKnownPosition();
      }

      return await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 10),
        ),
      ).timeout(const Duration(seconds: 12));
    } catch (_) {
      return await Geolocator.getLastKnownPosition();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    ChildNotificationService.onPayload = null;
    _sosTimer?.cancel();
    _policySub?.cancel();
    _chatSub?.cancel();
    _limitCheckTimer?.cancel();
    _locationTimer?.cancel();
    _screenStatsTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final locked = _quietHoursLock || _dailyLimitLock;

    return Stack(
      children: [
        Scaffold(
          backgroundColor: const Color(0xFFF0F4FF),
          appBar: AppBar(
            backgroundColor: const Color(0xFF4A90D9),
            foregroundColor: Colors.white,
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Aileİzi',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
                ),
                Text(
                  'Merhaba, ${_childName ?? ''}!',
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
                ),
              ],
            ),
            actions: [
              IconButton(
                icon: const Icon(Icons.directions_walk),
                tooltip: 'Yürüyüş kaydı',
                onPressed: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                        builder: (_) => const TrailRecordScreen()),
                  );
                },
              ),
              IconButton(
                icon: const Icon(Icons.route),
                tooltip: 'Rota takibi',
                onPressed: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                        builder: (_) => const ChildRoutesScreen()),
                  );
                },
              ),
              IconButton(
                icon: const Icon(Icons.chat_bubble_outline),
                tooltip: 'Mesajlar',
                onPressed: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const ChildChatScreen()),
                  );
                },
              ),
              IconButton(
                icon: Icon(_isSharing ? Icons.location_on : Icons.location_off),
                tooltip: _isSharing ? 'Konum Paylaşılıyor' : 'Konum Kapalı',
                onPressed: () => _setLocationSharing(!_isSharing),
              ),
            ],
          ),
          body: SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final short = constraints.maxHeight < 680;
                final sosSize = short ? 140.0 : 180.0;
                return SingleChildScrollView(
                  padding: EdgeInsets.fromLTRB(20, 12, 20, short ? 16 : 24),
                  child: Column(
                    children: [
                  // Durum kartı
                  Card(
                    color: _isSharing
                        ? Colors.green.shade50
                        : Colors.orange.shade50,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        children: [
                          Row(
                            children: [
                              Icon(
                                _isSharing
                                    ? Icons.location_on
                                    : Icons.location_off,
                                color:
                                    _isSharing ? Colors.green : Colors.orange,
                                size: 32,
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      _isSharing
                                          ? 'Konum Paylaşılıyor'
                                          : 'Konum Kapalı',
                                      style: TextStyle(
                                        fontWeight: FontWeight.bold,
                                        color: _isSharing
                                            ? Colors.green.shade800
                                            : Colors.orange.shade800,
                                      ),
                                    ),
                                    Text(
                                      _locationStatus,
                                      style: const TextStyle(
                                        fontSize: 12,
                                        color: Colors.grey,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              if (_locationUploading)
                                const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              else if (_isSharing)
                                IconButton(
                                  tooltip: 'Konumu şimdi gönder',
                                  icon: const Icon(Icons.refresh),
                                  onPressed: _pushLocationNow,
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Card(
                    color: _usagePermissionGranted
                        ? Colors.blue.shade50
                        : Colors.red.shade50,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(
                                Icons.phone_android,
                                color: _usagePermissionGranted
                                    ? Colors.blue
                                    : Colors.red,
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      _usagePermissionGranted
                                          ? 'Ekran süresi açık'
                                          : 'Ekran süresi izni gerekli',
                                      style: TextStyle(
                                        fontWeight: FontWeight.bold,
                                        color: _usagePermissionGranted
                                            ? Colors.blue.shade800
                                            : Colors.red.shade800,
                                      ),
                                    ),
                                    Text(
                                      _screenStatsStatus,
                                      style: const TextStyle(
                                        fontSize: 12,
                                        color: Colors.grey,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              IconButton(
                                tooltip: 'Yenile',
                                icon: const Icon(Icons.refresh),
                                onPressed: _refreshScreenStats,
                              ),
                            ],
                          ),
                          if (!_usagePermissionGranted) ...[
                            const SizedBox(height: 8),
                            SizedBox(
                              width: double.infinity,
                              child: ElevatedButton.icon(
                                onPressed: _openUsagePermission,
                                icon: const Icon(Icons.settings),
                                label: const Text('Kullanım erişimini aç'),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),

                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF2D6A4F),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                      onPressed: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                              builder: (_) => const TrailRecordScreen()),
                        );
                      },
                      icon: const Icon(Icons.directions_walk),
                      label: const Text('Yürüyüş rotası kaydet (A→B)'),
                    ),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                              builder: (_) => const ChildRoutesScreen()),
                        );
                      },
                      icon: const Icon(Icons.route),
                      label: const Text('Rota takibi'),
                    ),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                              builder: (_) => const ChildChatScreen()),
                        );
                      },
                      icon: const Icon(Icons.chat),
                      label: const Text('Ebeveyn ile mesajlaş'),
                    ),
                  ),

                  SizedBox(height: short ? 20 : 32),

                  // SOS butonu
                  const Text(
                    'Acil Durum Butonu',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      color: Colors.black54,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Yardıma ihtiyacın varsa\nbaskılı tut',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.grey),
                  ),
                  SizedBox(height: short ? 16 : 28),

                  // Büyük SOS butonu
                  GestureDetector(
                    onLongPressStart: (_) => _startSos(),
                    onLongPressEnd: (_) {
                      if (_sosPressed && _sosCountdown > 0) _cancelSos();
                    },
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      width: _sosPressed ? sosSize + 20 : sosSize,
                      height: _sosPressed ? sosSize + 20 : sosSize,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _sosPressed ? Colors.red : Colors.red.shade400,
                        boxShadow: [
                          BoxShadow(
                            color:
                                Colors.red.withOpacity(_sosPressed ? 0.5 : 0.3),
                            blurRadius: _sosPressed ? 40 : 20,
                            spreadRadius: _sosPressed ? 10 : 5,
                          ),
                        ],
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.emergency,
                              color: Colors.white,
                              size: short ? 40 : 48),
                          const SizedBox(height: 4),
                          Text(
                            _sosPressed ? '$_sosCountdown' : 'SOS',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: short ? 24 : 28,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          if (_sosPressed)
                            const Text(
                              'Bırak → İptal',
                              style: TextStyle(
                                color: Colors.white70,
                                fontSize: 11,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),

                  SizedBox(height: short ? 16 : 24),

                  // İpucu
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.blue.shade50,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Row(
                      children: [
                        Icon(Icons.info_outline, color: Colors.blue, size: 18),
                        SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Butonu 3 saniye basılı tutarsan ebeveynine acil uyarı gider.',
                            style: TextStyle(fontSize: 12, color: Colors.blue),
                          ),
                        ),
                      ],
                    ),
                  ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
        if (locked) ...[
          const ModalBarrier(color: Colors.black54, dismissible: false),
          Center(
            child: Card(
              margin: const EdgeInsets.all(32),
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      _dailyLimitLock
                          ? Icons.timer_off
                          : Icons.nightlight_round,
                      size: 48,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      _dailyLimitLock
                          ? 'Günlük ekran süre limitine ulaşıldı'
                          : 'Ebeveynin belirlediği saatlerde cihaz kilitli',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _dailyLimitLock
                          ? 'Yarın tekrar kullanabilirsin veya ebeveynin limiti güncelleyebilir.'
                          : 'Uyku veya ders saati bitince ekran açılır.',
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 13, color: Colors.grey),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}
