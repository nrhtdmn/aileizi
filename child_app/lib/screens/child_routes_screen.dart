import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'trail_record_screen.dart';

class ChildRoutesScreen extends StatefulWidget {
  const ChildRoutesScreen({super.key});

  @override
  State<ChildRoutesScreen> createState() => _ChildRoutesScreenState();
}

class _ChildRoutesScreenState extends State<ChildRoutesScreen> {
  String? _familyId;
  String? _childId;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      setState(() {
        _error = 'Oturum yok';
        _loading = false;
      });
      return;
    }
    final doc =
        await FirebaseFirestore.instance.collection('users').doc(user.uid).get();
    final fid = doc.data()?['familyId'] as String?;
    if (fid == null || fid.isEmpty) {
      setState(() {
        _error = 'Aile bağlantısı yok';
        _loading = false;
      });
      return;
    }
    setState(() {
      _familyId = fid;
      _childId = user.uid;
      _loading = false;
    });
  }

  Stream<QuerySnapshot<Map<String, dynamic>>>? get _stream {
    if (_familyId == null || _childId == null) return null;
    return FirebaseFirestore.instance
        .collection('families')
        .doc(_familyId)
        .collection('routes')
        .where('childId', isEqualTo: _childId)
        .snapshots();
  }

  Future<void> _cancelRoute(String routeId, String name) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rotayı iptal et?'),
        content: Text(
          '“$name” takibi durur. Ebeveyn haritasında da takip kapanır.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Vazgeç')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('İptal et'),
          ),
        ],
      ),
    );
    if (ok != true || _familyId == null) return;
    try {
      await FirebaseFirestore.instance
          .collection('families')
          .doc(_familyId)
          .collection('routes')
          .doc(routeId)
          .update({
        'active': false,
        'isDeviated': false,
        'cancelledAt': FieldValue.serverTimestamp(),
        'cancelledBy': 'child',
      });
      final user = FirebaseAuth.instance.currentUser;
      final childName = user?.displayName?.trim().isNotEmpty == true
          ? user!.displayName!
          : 'Çocuk';
      await FirebaseFirestore.instance
          .collection('families')
          .doc(_familyId)
          .collection('route_events')
          .add({
        'childId': _childId,
        'childName': childName,
        'routeId': routeId,
        'routeName': name,
        'eventType': 'cancel',
        'distanceMeters': 0,
        'thresholdMeters': 0,
        'timestamp': FieldValue.serverTimestamp(),
        'notified': false,
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('“$name” iptal edildi')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('İptal edilemedi: $e')));
      }
    }
  }

  Future<void> _openInMaps(List<dynamic> rawPoints, String name) async {
    final points = rawPoints
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    if (points.isEmpty) return;
    final first = points.first;
    final last = points.last;
    final oLat = (first['latitude'] as num).toDouble();
    final oLng = (first['longitude'] as num).toDouble();
    final dLat = (last['latitude'] as num).toDouble();
    final dLng = (last['longitude'] as num).toDouble();
    final uri = Uri.parse(
      'https://www.google.com/maps/dir/?api=1'
      '&origin=$oLat,$oLng&destination=$dLat,$dLng&travelmode=walking',
    );
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF4A90D9),
        foregroundColor: Colors.white,
        title: const Text('Rota takibi'),
        actions: [
          IconButton(
            tooltip: 'Yürüyüş kaydı',
            icon: const Icon(Icons.directions_walk),
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const TrailRecordScreen()),
              );
            },
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Text(_error!))
              : StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                  stream: _stream,
                  builder: (context, snap) {
                    if (snap.hasError) {
                      return Center(child: Text('Hata: ${snap.error}'));
                    }
                    final docs = snap.data?.docs ?? [];
                    final active =
                        docs.where((d) => d.data()['active'] == true).toList();
                    final inactive = docs
                        .where((d) => d.data()['active'] != true)
                        .toList();

                    if (docs.isEmpty) {
                      return const Center(
                        child: Padding(
                          padding: EdgeInsets.all(24),
                          child: Text(
                            'Şu an atanmış rota yok.\nEbeveyn rota gönderince burada görünür.',
                            textAlign: TextAlign.center,
                          ),
                        ),
                      );
                    }

                    return ListView(
                      padding: const EdgeInsets.all(16),
                      children: [
                        if (active.isNotEmpty) ...[
                          const Text(
                            'Aktif takip',
                            style: TextStyle(
                                fontWeight: FontWeight.bold, fontSize: 16),
                          ),
                          const SizedBox(height: 4),
                          const Text(
                            'Rotadan belirlenen metreden fazla çıkarsan ebeveyne bildirim gider. İptal edene kadar devam eder.',
                            style:
                                TextStyle(fontSize: 12, color: Colors.black54),
                          ),
                          const SizedBox(height: 8),
                          ...active.map((d) => _routeCard(d, tracking: true)),
                          const SizedBox(height: 20),
                        ],
                        if (inactive.isNotEmpty) ...[
                          const Text(
                            'Diğer rotalar',
                            style: TextStyle(
                                fontWeight: FontWeight.bold, fontSize: 16),
                          ),
                          const SizedBox(height: 8),
                          ...inactive
                              .map((d) => _routeCard(d, tracking: false)),
                        ],
                      ],
                    );
                  },
                ),
    );
  }

  Widget _routeCard(
    QueryDocumentSnapshot<Map<String, dynamic>> doc, {
    required bool tracking,
  }) {
    final data = doc.data();
    final name = data['name']?.toString() ?? 'Rota';
    final meters = (data['deviationMeters'] as num?)?.toInt() ?? 20;
    final points = data['points'] as List<dynamic>? ?? [];
    final deviated = data['isDeviated'] == true;

    return Card(
      color: tracking
          ? (deviated ? Colors.red.shade50 : Colors.green.shade50)
          : null,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.route,
                  color: tracking
                      ? (deviated ? Colors.red : Colors.green.shade800)
                      : Colors.grey,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(name,
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                ),
                if (tracking && deviated)
                  const Chip(
                    label: Text('Saptın', style: TextStyle(fontSize: 11)),
                    backgroundColor: Colors.redAccent,
                    labelStyle: TextStyle(color: Colors.white),
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              tracking
                  ? 'Takip aktif • Sapma eşiği: $meters m • ${points.length} nokta'
                  : 'Takip kapalı • Sapma: $meters m',
              style: const TextStyle(fontSize: 12, color: Colors.black54),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                if (points.isNotEmpty)
                  OutlinedButton.icon(
                    onPressed: () => _openInMaps(points, name),
                    icon: const Icon(Icons.map, size: 18),
                    label: const Text('Haritada git'),
                  ),
                if (tracking)
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.orange.shade800,
                      foregroundColor: Colors.white,
                    ),
                    onPressed: () => _cancelRoute(doc.id, name),
                    icon: const Icon(Icons.cancel, size: 18),
                    label: const Text('Rotayı iptal et'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
