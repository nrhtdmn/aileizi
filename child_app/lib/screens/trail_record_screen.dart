import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

/// A noktasında kayıt başlar; yürüdükçe rota çizilir; B'de kaydedilir.
class TrailRecordScreen extends StatefulWidget {
  const TrailRecordScreen({super.key});

  @override
  State<TrailRecordScreen> createState() => _TrailRecordScreenState();
}

class _TrailRecordScreenState extends State<TrailRecordScreen> {
  static const _minPointDistanceM = 8.0;
  static const _syncEveryPoints = 3;

  final _mapReady = Completer<GoogleMapController>();
  StreamSubscription<Position>? _posSub;
  Timer? _tickTimer;

  String? _familyId;
  String? _childId;
  String? _routeId;
  String? _error;

  bool _loading = true;
  bool _recording = false;
  bool _saving = false;
  bool _followCamera = true;
  int _unsynced = 0;

  final List<LatLng> _points = [];
  double _distanceM = 0;
  DateTime? _startedAt;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  @override
  void dispose() {
    _posSub?.cancel();
    _tickTimer?.cancel();
    super.dispose();
  }

  Future<void> _bootstrap() async {
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

    final perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      await Geolocator.requestPermission();
    }
    if (await Geolocator.checkPermission() == LocationPermission.deniedForever ||
        await Geolocator.checkPermission() == LocationPermission.denied) {
      setState(() {
        _error = 'Konum izni gerekli';
        _loading = false;
      });
      return;
    }

    Position? pos;
    try {
      pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 12),
        ),
      );
    } catch (_) {
      pos = await Geolocator.getLastKnownPosition();
    }

    setState(() {
      _familyId = fid;
      _childId = user.uid;
      _loading = false;
      if (pos != null) {
        _points.add(LatLng(pos.latitude, pos.longitude));
      }
    });

    if (pos != null) {
      try {
        final c = await _mapReady.future;
        await c.animateCamera(
          CameraUpdate.newLatLngZoom(
            LatLng(pos.latitude, pos.longitude),
            16,
          ),
        );
      } catch (_) {}
    }
  }

  Future<void> _startRecording() async {
    if (_familyId == null || _childId == null || _recording) return;
    if (_points.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Konum alınamadı, biraz bekleyip tekrar dene')),
      );
      return;
    }

    setState(() => _saving = true);
    try {
      final start = _points.first;
      final ref = await FirebaseFirestore.instance
          .collection('families')
          .doc(_familyId)
          .collection('routes')
          .add({
        'name': 'Yürüyüş kaydı',
        'childId': _childId,
        'mode': 'recorded',
        'recording': true,
        'active': false,
        'isDeviated': false,
        'deviationMeters': 20,
        'points': [
          {'latitude': start.latitude, 'longitude': start.longitude},
        ],
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });

      setState(() {
        _routeId = ref.id;
        _recording = true;
        _startedAt = DateTime.now();
        _saving = false;
        _unsynced = 0;
      });

      _tickTimer?.cancel();
      _tickTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted && _recording) setState(() {});
      });

      _posSub?.cancel();
      _posSub = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.bestForNavigation,
          distanceFilter: 5,
        ),
      ).listen(_onPosition, onError: (_) {});

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Kayıt başladı — A noktasından yürümeye başla'),
          ),
        );
      }
    } catch (e) {
      setState(() => _saving = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Başlatılamadı: $e')),
        );
      }
    }
  }

  void _onPosition(Position pos) {
    if (!_recording) return;
    final next = LatLng(pos.latitude, pos.longitude);
    if (_points.isNotEmpty) {
      final last = _points.last;
      final d = Geolocator.distanceBetween(
        last.latitude,
        last.longitude,
        next.latitude,
        next.longitude,
      );
      if (d < _minPointDistanceM) return;
      _distanceM += d;
    }

    setState(() {
      _points.add(next);
      _unsynced++;
    });

    if (_followCamera) {
      _mapReady.future.then((c) {
        c.animateCamera(CameraUpdate.newLatLng(next));
      }).catchError((_) {});
    }

    if (_unsynced >= _syncEveryPoints) {
      _syncPoints();
    }
  }

  Future<void> _syncPoints() async {
    if (_routeId == null || _familyId == null || _points.isEmpty) return;
    final snapshot = List<LatLng>.from(_points);
    _unsynced = 0;
    try {
      await FirebaseFirestore.instance
          .collection('families')
          .doc(_familyId)
          .collection('routes')
          .doc(_routeId)
          .update({
        'points': snapshot
            .map((p) => {'latitude': p.latitude, 'longitude': p.longitude})
            .toList(),
        'updatedAt': FieldValue.serverTimestamp(),
      });
    } catch (_) {}
  }

  Future<void> _finishAndSave() async {
    if (!_recording || _points.length < 2) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Kaydetmek için en az biraz yürümelisin')),
      );
      return;
    }

    await _posSub?.cancel();
    _posSub = null;
    await _syncPoints();

    final defaultName =
        'Yürüyüş ${DateTime.now().day}.${DateTime.now().month} ${DateTime.now().hour}:${DateTime.now().minute.toString().padLeft(2, '0')}';

    final result = await showDialog<_TrailSaveResult>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _TrailSaveDialog(
        initialName: defaultName,
        pointCount: _points.length,
        distanceKm: _distanceM / 1000,
      ),
    );

    if (result == null) {
      // Kayıda devam
      _posSub = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.bestForNavigation,
          distanceFilter: 5,
        ),
      ).listen(_onPosition, onError: (_) {});
      return;
    }

    _tickTimer?.cancel();
    final name = result.name;
    final startTracking = result.startTracking;
    final deviation = result.deviation;

    setState(() => _saving = true);
    try {
      await FirebaseFirestore.instance
          .collection('families')
          .doc(_familyId)
          .collection('routes')
          .doc(_routeId)
          .update({
        'name': name,
        'points': _points
            .map((p) => {'latitude': p.latitude, 'longitude': p.longitude})
            .toList(),
        'recording': false,
        'active': startTracking,
        'deviationMeters': deviation,
        'updatedAt': FieldValue.serverTimestamp(),
      });

      if (!mounted) return;
      setState(() {
        _recording = false;
        _saving = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('“$name” kaydedildi')),
      );
      Navigator.of(context).pop(true);
    } catch (e) {
      setState(() => _saving = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Kaydedilemedi: $e')),
        );
      }
      _posSub = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.bestForNavigation,
          distanceFilter: 5,
        ),
      ).listen(_onPosition, onError: (_) {});
    }
  }

  Future<void> _discard() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Kayıt silinsin mi?'),
        content: const Text('Çizilen yol silinir, geri alınamaz.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Vazgeç')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Sil', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    if (ok != true) return;

    await _posSub?.cancel();
    _posSub = null;
    _tickTimer?.cancel();
    if (_routeId != null && _familyId != null) {
      try {
        await FirebaseFirestore.instance
            .collection('families')
            .doc(_familyId)
            .collection('routes')
            .doc(_routeId)
            .delete();
      } catch (_) {}
    }
    if (mounted) Navigator.of(context).pop();
  }

  Set<Marker> get _markers {
    final m = <Marker>{};
    if (_points.isEmpty) return m;
    m.add(Marker(
      markerId: const MarkerId('start'),
      position: _points.first,
      infoWindow: const InfoWindow(title: 'A — Başlangıç'),
      icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueGreen),
    ));
    if (_points.length > 1) {
      m.add(Marker(
        markerId: const MarkerId('end'),
        position: _points.last,
        infoWindow: InfoWindow(
          title: _recording ? 'Şu an' : 'B — Bitiş',
        ),
        icon: BitmapDescriptor.defaultMarkerWithHue(
          _recording ? BitmapDescriptor.hueAzure : BitmapDescriptor.hueRed,
        ),
      ));
    }
    return m;
  }

  String get _elapsed {
    if (_startedAt == null) return '00:00';
    final s = DateTime.now().difference(_startedAt!).inSeconds;
    final mm = (s ~/ 60).toString().padLeft(2, '0');
    final ss = (s % 60).toString().padLeft(2, '0');
    return '$mm:$ss';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF2D6A4F),
        foregroundColor: Colors.white,
        title: Text(_recording ? 'Kayıt sürüyor' : 'Yürüyüş rotası'),
        actions: [
          if (_recording)
            IconButton(
              tooltip: _followCamera ? 'Kamerayı serbest bırak' : 'Takip et',
              icon: Icon(_followCamera ? Icons.my_location : Icons.location_searching),
              onPressed: () => setState(() => _followCamera = !_followCamera),
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Text(_error!))
              : Column(
                  children: [
                    Expanded(
                      child: GoogleMap(
                        initialCameraPosition: CameraPosition(
                          target: _points.isNotEmpty
                              ? _points.first
                              : const LatLng(39.92, 32.85),
                          zoom: 16,
                        ),
                        myLocationEnabled: true,
                        myLocationButtonEnabled: true,
                        compassEnabled: true,
                        markers: _markers,
                        polylines: {
                          if (_points.length >= 2)
                            Polyline(
                              polylineId: const PolylineId('trail'),
                              points: List.of(_points),
                              color: const Color(0xFFE85D04),
                              width: 6,
                            ),
                        },
                        onMapCreated: (c) {
                          if (!_mapReady.isCompleted) _mapReady.complete(c);
                        },
                      ),
                    ),
                    Material(
                      elevation: 8,
                      child: SafeArea(
                        top: false,
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text(
                                _recording
                                    ? 'A → yürüyüş → B. Yol haritada çiziliyor; ebeveyn de canlı görür.'
                                    : 'A noktasında “Kaydı başlat”a bas, B’ye kadar yürü, sonra kaydet.',
                                style: const TextStyle(
                                    fontSize: 13, color: Colors.black54),
                              ),
                              const SizedBox(height: 8),
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: [
                                  _statChip(Icons.timeline, '${_points.length} nokta'),
                                  _statChip(
                                    Icons.straighten,
                                    _distanceM < 1000
                                        ? '${_distanceM.toStringAsFixed(0)} m'
                                        : '${(_distanceM / 1000).toStringAsFixed(2)} km',
                                  ),
                                  if (_recording)
                                    _statChip(Icons.timer, _elapsed),
                                ],
                              ),
                              const SizedBox(height: 12),
                              if (!_recording)
                                ElevatedButton.icon(
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: const Color(0xFF2D6A4F),
                                    foregroundColor: Colors.white,
                                    padding: const EdgeInsets.symmetric(vertical: 14),
                                  ),
                                  onPressed: _saving ? null : _startRecording,
                                  icon: _saving
                                      ? const SizedBox(
                                          width: 18,
                                          height: 18,
                                          child: CircularProgressIndicator(
                                              strokeWidth: 2, color: Colors.white),
                                        )
                                      : const Icon(Icons.fiber_manual_record),
                                  label: Text(_saving ? 'Başlatılıyor…' : 'Kaydı başlat (A)'),
                                )
                              else
                                Row(
                                  children: [
                                    Expanded(
                                      child: OutlinedButton.icon(
                                        onPressed: _saving ? null : _discard,
                                        icon: const Icon(Icons.delete_outline),
                                        label: const Text('Sil'),
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      flex: 2,
                                      child: ElevatedButton.icon(
                                        style: ElevatedButton.styleFrom(
                                          backgroundColor: const Color(0xFFE85D04),
                                          foregroundColor: Colors.white,
                                          padding: const EdgeInsets.symmetric(
                                              vertical: 14),
                                        ),
                                        onPressed: _saving ? null : _finishAndSave,
                                        icon: _saving
                                            ? const SizedBox(
                                                width: 18,
                                                height: 18,
                                                child: CircularProgressIndicator(
                                                    strokeWidth: 2,
                                                    color: Colors.white),
                                              )
                                            : const Icon(Icons.stop),
                                        label: Text(
                                            _saving ? 'Kaydediliyor…' : 'Bitir ve kaydet (B)'),
                                      ),
                                    ),
                                  ],
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
    );
  }

  Widget _statChip(IconData icon, String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.grey.shade100,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: Colors.black54),
          const SizedBox(width: 4),
          Text(text, style: const TextStyle(fontSize: 12)),
        ],
      ),
    );
  }
}

class _TrailSaveResult {
  final String name;
  final bool startTracking;
  final double deviation;

  const _TrailSaveResult({
    required this.name,
    required this.startTracking,
    required this.deviation,
  });
}

class _TrailSaveDialog extends StatefulWidget {
  final String initialName;
  final int pointCount;
  final double distanceKm;

  const _TrailSaveDialog({
    required this.initialName,
    required this.pointCount,
    required this.distanceKm,
  });

  @override
  State<_TrailSaveDialog> createState() => _TrailSaveDialogState();
}

class _TrailSaveDialogState extends State<_TrailSaveDialog> {
  late final TextEditingController _nameCtrl;
  bool _startTracking = false;
  double _deviation = 20.0;

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: widget.initialName);
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _nameCtrl.text.trim().isEmpty
        ? 'Yürüyüş kaydı'
        : _nameCtrl.text.trim();
    Navigator.pop(
      context,
      _TrailSaveResult(
        name: name,
        startTracking: _startTracking,
        deviation: _deviation,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Rotayı kaydet'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '${widget.pointCount} nokta • ~${widget.distanceKm.toStringAsFixed(2)} km',
              style: const TextStyle(color: Colors.black54),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _nameCtrl,
              decoration: const InputDecoration(
                labelText: 'Rota adı',
                border: OutlineInputBorder(),
              ),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Rota takip aktif'),
              subtitle: const Text(
                'Sonraki kullanımlarda sapma bildirimi için',
              ),
              value: _startTracking,
              onChanged: (v) => setState(() => _startTracking = v),
            ),
            if (_startTracking)
              DropdownButtonFormField<double>(
                value: _deviation,
                decoration: const InputDecoration(
                  labelText: 'Sapma eşiği',
                  border: OutlineInputBorder(),
                ),
                items: const [20.0, 30.0, 50.0, 75.0, 100.0]
                    .map((m) => DropdownMenuItem(
                          value: m,
                          child: Text('${m.toInt()} metre'),
                        ))
                    .toList(),
                onChanged: (v) {
                  if (v != null) setState(() => _deviation = v);
                },
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('İptal'),
        ),
        ElevatedButton.icon(
          onPressed: _submit,
          icon: const Icon(Icons.save),
          label: const Text('Kaydet'),
        ),
      ],
    );
  }
}
