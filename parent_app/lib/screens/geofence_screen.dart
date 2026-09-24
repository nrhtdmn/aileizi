import 'dart:async';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:provider/provider.dart';
import '../services/firebase_service.dart';
import '../services/parent_nav.dart';
import '../models/models.dart';
import '../utils/map_launch.dart';
import '../l10n/app_locale.dart';

class GeofenceScreen extends StatefulWidget {
  const GeofenceScreen({super.key});

  @override
  State<GeofenceScreen> createState() => _GeofenceScreenState();
}

class _GeofenceScreenState extends State<GeofenceScreen> {
  final Completer<GoogleMapController> _mapController = Completer();
  LatLng? _newFenceCenter;
  double _newFenceRadius = 200;
  ParentNav? _nav;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final nav = context.read<ParentNav>();
    if (_nav != nav) {
      _nav?.removeListener(_onNavChanged);
      _nav = nav;
      _nav!.addListener(_onNavChanged);
      WidgetsBinding.instance.addPostFrameCallback((_) => _onNavChanged());
    }
  }

  @override
  void dispose() {
    _nav?.removeListener(_onNavChanged);
    super.dispose();
  }

  Future<void> _onNavChanged() async {
    final nav = _nav;
    if (nav == null || nav.geofenceTarget == null || !mounted) return;
    final target = nav.geofenceTarget!;
    final openDialog = nav.openGeofenceDialog;
    setState(() => _newFenceCenter = target);
    try {
      final ctrl = await _mapController.future;
      await ctrl.animateCamera(CameraUpdate.newLatLngZoom(target, 15));
    } catch (_) {}
    nav.consumeGeofenceTarget();
    if (openDialog && mounted) {
      await _showFenceDialog();
    }
  }

  Future<void> _focusFence(Geofence fence) async {
    final target = LatLng(fence.centerLat, fence.centerLng);
    setState(() {
      _newFenceCenter = target;
      _newFenceRadius = fence.radiusMeters;
    });
    try {
      final ctrl = await _mapController.future;
      await ctrl.animateCamera(CameraUpdate.newLatLngZoom(target, 15));
    } catch (_) {}
  }

  Future<void> _openOnMainMap(Geofence fence) async {
    context.read<ParentNav>().openMapAt(
          latitude: fence.centerLat,
          longitude: fence.centerLng,
          title: fence.name,
        );
  }

  Future<void> _openDirections(Geofence fence) async {
    final ok = await MapLaunch.openDirections(
      fence.centerLat,
      fence.centerLng,
      label: fence.name,
    );
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Harita uygulaması açılamadı.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final svc = context.read<FirebaseService>();

    return Scaffold(
      appBar: AppBar(
        title: Text(context.watch<AppLocale>().t('title_geofence')),
        actions: [
          IconButton(
            icon: const Icon(Icons.add_location_alt),
            tooltip: 'Bölge ekle',
            onPressed: () => _showFenceDialog(),
          ),
        ],
      ),
      body: StreamBuilder<List<Geofence>>(
        stream: svc.watchGeofences(),
        builder: (context, snapshot) {
          final fences = snapshot.data ?? [];

          return Column(
            children: [
              SizedBox(
                height: 300,
                child: Stack(
                  children: [
                    GoogleMap(
                      initialCameraPosition: const CameraPosition(
                        target: LatLng(41.0082, 28.9784),
                        zoom: 12,
                      ),
                      onMapCreated: (ctrl) {
                        if (!_mapController.isCompleted) {
                          _mapController.complete(ctrl);
                        }
                        WidgetsBinding.instance
                            .addPostFrameCallback((_) => _onNavChanged());
                      },
                      markers: {
                        ...fences.map((f) => Marker(
                              markerId: MarkerId('fence-${f.id}'),
                              position: LatLng(f.centerLat, f.centerLng),
                              infoWindow: InfoWindow(
                                title: f.name,
                                snippet:
                                    '${f.centerLat.toStringAsFixed(6)}, ${f.centerLng.toStringAsFixed(6)}',
                              ),
                              onTap: () => _focusFence(f),
                            )),
                        if (_newFenceCenter != null)
                          Marker(
                            markerId: const MarkerId('new-fence-center'),
                            position: _newFenceCenter!,
                            icon: BitmapDescriptor.defaultMarkerWithHue(
                              BitmapDescriptor.hueAzure,
                            ),
                            infoWindow: InfoWindow(
                              title: 'Yeni bölge merkezi',
                              snippet:
                                  '${_newFenceCenter!.latitude.toStringAsFixed(6)}, ${_newFenceCenter!.longitude.toStringAsFixed(6)}',
                            ),
                            onTap: () => _showFenceDialog(),
                          ),
                      },
                      circles: {
                        ...fences.map((f) => Circle(
                              circleId: CircleId(f.id),
                              center: LatLng(f.centerLat, f.centerLng),
                              radius: f.radiusMeters,
                              fillColor: Colors.green.withOpacity(0.2),
                              strokeColor: Colors.green,
                              strokeWidth: 2,
                            )),
                        if (_newFenceCenter != null)
                          Circle(
                            circleId: const CircleId('new'),
                            center: _newFenceCenter!,
                            radius: _newFenceRadius,
                            fillColor: Colors.blue.withOpacity(0.2),
                            strokeColor: Colors.blue,
                            strokeWidth: 2,
                          ),
                      },
                      onTap: (pos) => setState(() => _newFenceCenter = pos),
                    ),
                    Positioned(
                      left: 12,
                      right: 12,
                      top: 12,
                      child: Card(
                        color: Colors.white.withOpacity(0.92),
                        child: const Padding(
                          padding: EdgeInsets.all(10),
                          child: Text(
                            'Haritada bir noktaya dokun. Sonra mavi “+” ile güvenli bölge ekle. '
                            'Kayıtlı bölgeye dokunarak odaklan.',
                            style: TextStyle(fontSize: 12),
                          ),
                        ),
                      ),
                    ),
                    if (_newFenceCenter != null)
                      Positioned(
                        right: 16,
                        bottom: 16,
                        child: FloatingActionButton.extended(
                          heroTag: 'add-geofence-fab',
                          backgroundColor: const Color(0xFF2D6A4F),
                          foregroundColor: Colors.white,
                          icon: const Icon(Icons.add_location_alt),
                          label: const Text('Bu noktaya bölge ekle'),
                          onPressed: () => _showFenceDialog(),
                        ),
                      ),
                  ],
                ),
              ),
              Expanded(
                child: fences.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(Icons.location_off,
                                size: 60, color: Colors.grey),
                            const SizedBox(height: 16),
                            const Text('Henüz güvenli bölge eklenmedi'),
                            const SizedBox(height: 8),
                            ElevatedButton.icon(
                              icon: const Icon(Icons.add),
                              label: const Text('Bölge Ekle'),
                              onPressed: () => _showFenceDialog(),
                            ),
                          ],
                        ),
                      )
                    : ListView.builder(
                        itemCount: fences.length,
                        padding: const EdgeInsets.all(16),
                        itemBuilder: (context, i) {
                          final fence = fences[i];
                          final coords =
                              '${fence.centerLat.toStringAsFixed(5)}, ${fence.centerLng.toStringAsFixed(5)}';
                          return Card(
                            child: ListTile(
                              onTap: () => _focusFence(fence),
                              leading: const CircleAvatar(
                                backgroundColor: Color(0xFF2D6A4F),
                                child: Icon(Icons.place, color: Colors.white),
                              ),
                              title: Text(fence.name),
                              subtitle: Text(
                                '$coords\n'
                                '${fence.radiusMeters.toInt()}m yarıçap • '
                                '${fence.childIds.isEmpty ? 'Tüm çocuklar' : '${fence.childIds.length} çocuk'}',
                              ),
                              isThreeLine: true,
                              trailing: PopupMenuButton<String>(
                                tooltip: 'İşlemler',
                                onSelected: (action) async {
                                  switch (action) {
                                    case 'focus':
                                      await _focusFence(fence);
                                      break;
                                    case 'map':
                                      await _openOnMainMap(fence);
                                      break;
                                    case 'directions':
                                      await _openDirections(fence);
                                      break;
                                    case 'edit':
                                      await _showFenceDialog(existing: fence);
                                      break;
                                    case 'delete':
                                      _confirmDelete(fence, svc);
                                      break;
                                  }
                                },
                                itemBuilder: (ctx) => const [
                                  PopupMenuItem(
                                    value: 'focus',
                                    child: ListTile(
                                      dense: true,
                                      leading: Icon(Icons.my_location),
                                      title: Text('Haritada göster'),
                                      contentPadding: EdgeInsets.zero,
                                    ),
                                  ),
                                  PopupMenuItem(
                                    value: 'map',
                                    child: ListTile(
                                      dense: true,
                                      leading: Icon(Icons.map_outlined),
                                      title: Text('Ana haritada aç'),
                                      contentPadding: EdgeInsets.zero,
                                    ),
                                  ),
                                  PopupMenuItem(
                                    value: 'directions',
                                    child: ListTile(
                                      dense: true,
                                      leading: Icon(Icons.directions),
                                      title: Text('Haritalar ile rota'),
                                      contentPadding: EdgeInsets.zero,
                                    ),
                                  ),
                                  PopupMenuItem(
                                    value: 'edit',
                                    child: ListTile(
                                      dense: true,
                                      leading: Icon(Icons.edit_outlined),
                                      title: Text('Düzenle'),
                                      contentPadding: EdgeInsets.zero,
                                    ),
                                  ),
                                  PopupMenuItem(
                                    value: 'delete',
                                    child: ListTile(
                                      dense: true,
                                      leading: Icon(Icons.delete_outline,
                                          color: Colors.red),
                                      title: Text('Sil',
                                          style: TextStyle(color: Colors.red)),
                                      contentPadding: EdgeInsets.zero,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _showFenceDialog({Geofence? existing}) async {
    final svc = context.read<FirebaseService>();
    List<ChildSummary> children = [];
    try {
      children = await svc.watchChildren().first.timeout(
            const Duration(seconds: 5),
            onTimeout: () => [],
          );
    } catch (_) {
      children = [];
    }
    if (!mounted) return;

    LatLng? initialCenter = existing != null
        ? LatLng(existing.centerLat, existing.centerLng)
        : _newFenceCenter;

    if (initialCenter == null) {
      try {
        final ctrl = await _mapController.future;
        final region = await ctrl.getVisibleRegion();
        initialCenter = LatLng(
          (region.northeast.latitude + region.southwest.latitude) / 2,
          (region.northeast.longitude + region.southwest.longitude) / 2,
        );
        if (mounted) setState(() => _newFenceCenter = initialCenter);
      } catch (_) {}
    } else if (mounted) {
      setState(() {
        _newFenceCenter = initialCenter;
        if (existing != null) _newFenceRadius = existing.radiusMeters;
      });
    }
    if (!mounted) return;

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => _FenceEditorDialog(
        service: svc,
        children: children,
        existing: existing,
        initialCenter: initialCenter ?? _newFenceCenter,
        initialRadius: existing?.radiusMeters ?? _newFenceRadius,
        onPreviewChanged: (center, radius) {
          if (!mounted) return;
          setState(() {
            _newFenceCenter = center;
            _newFenceRadius = radius;
          });
        },
      ),
    );
    if (saved == true && mounted && existing == null) {
      setState(() => _newFenceCenter = null);
    }
  }

  void _confirmDelete(Geofence fence, FirebaseService svc) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Bölgeyi Sil'),
        content: Text('"${fence.name}" bölgesini silmek istiyor musun?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('İptal'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () async {
              Navigator.pop(ctx);
              try {
                await svc.deleteGeofence(fence.id);
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Bölge silindi.')),
                  );
                }
              } catch (e) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Silinemedi: $e')),
                  );
                }
              }
            },
            child: const Text('Sil', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }
}

class _FenceEditorDialog extends StatefulWidget {
  const _FenceEditorDialog({
    required this.service,
    required this.children,
    required this.initialCenter,
    required this.initialRadius,
    required this.onPreviewChanged,
    this.existing,
  });

  final FirebaseService service;
  final List<ChildSummary> children;
  final LatLng? initialCenter;
  final double initialRadius;
  final Geofence? existing;
  final void Function(LatLng? center, double radius) onPreviewChanged;

  @override
  State<_FenceEditorDialog> createState() => _FenceEditorDialogState();
}

class _FenceEditorDialogState extends State<_FenceEditorDialog> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _latCtrl;
  late final TextEditingController _lngCtrl;
  late final Set<String> _selectedChildIds;
  late double _radius;
  late bool _notifyOnExit;
  late bool _notifyOnEnter;
  bool _saving = false;
  LatLng? _center;

  bool get _isEdit => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    _center = widget.initialCenter;
    _radius = widget.initialRadius;
    _nameCtrl = TextEditingController(text: existing?.name ?? '');
    _latCtrl = TextEditingController(
      text: _center?.latitude.toStringAsFixed(6) ?? '',
    );
    _lngCtrl = TextEditingController(
      text: _center?.longitude.toStringAsFixed(6) ?? '',
    );
    _notifyOnExit = existing?.notifyOnExit ?? true;
    _notifyOnEnter = existing?.notifyOnEnter ?? true;
    if (existing != null && existing.childIds.isNotEmpty) {
      _selectedChildIds = existing.childIds.toSet();
    } else {
      _selectedChildIds = widget.children.map((c) => c.uid).toSet();
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _latCtrl.dispose();
    _lngCtrl.dispose();
    super.dispose();
  }

  bool _applyCoordinate() {
    final lat = double.tryParse(_latCtrl.text.trim().replaceAll(',', '.'));
    final lng = double.tryParse(_lngCtrl.text.trim().replaceAll(',', '.'));
    if (lat == null ||
        lng == null ||
        lat < -90 ||
        lat > 90 ||
        lng < -180 ||
        lng > 180) {
      _showError('Geçerli enlem/boylam girin.');
      return false;
    }
    setState(() => _center = LatLng(lat, lng));
    widget.onPreviewChanged(_center, _radius);
    return true;
  }

  Future<void> _save() async {
    if (!_applyCoordinate()) return;
    final center = _center;
    if (center == null) return;

    setState(() => _saving = true);
    final messenger = ScaffoldMessenger.of(context);
    final fence = Geofence(
      id: widget.existing?.id ?? '',
      name: _nameCtrl.text.trim().isEmpty
          ? 'Bölge ${DateTime.now().millisecondsSinceEpoch % 10000}'
          : _nameCtrl.text.trim(),
      centerLat: center.latitude,
      centerLng: center.longitude,
      radiusMeters: _radius,
      childIds: _selectedChildIds.toList(),
      notifyOnExit: _notifyOnExit,
      notifyOnEnter: _notifyOnEnter,
    );

    try {
      if (_isEdit) {
        await widget.service.updateGeofence(fence);
      } else {
        await widget.service.addGeofence(fence);
      }
      if (mounted) Navigator.pop(context, true);
      messenger.showSnackBar(
        SnackBar(
          content: Text(_isEdit ? 'Bölge güncellendi.' : 'Bölge eklendi.'),
        ),
      );
    } catch (e) {
      _showError(_isEdit ? 'Güncellenemedi: $e' : 'Bölge eklenemedi: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(_isEdit ? 'Bölgeyi Düzenle' : 'Güvenli Bölge Ekle'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _nameCtrl,
              decoration: const InputDecoration(
                labelText: 'Bölge Adı (örn: Ev, Okul)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _latCtrl,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                      labelText: 'Enlem',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _lngCtrl,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                      labelText: 'Boylam',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                icon: const Icon(Icons.my_location),
                label: const Text('Koordinatı Uygula'),
                onPressed: _applyCoordinate,
              ),
            ),
            if (_center != null) ...[
              const SizedBox(height: 8),
              Text(
                'Seçili: ${_center!.latitude.toStringAsFixed(6)}, '
                '${_center!.longitude.toStringAsFixed(6)}',
                style: TextStyle(color: Colors.green.shade700, fontSize: 12),
              ),
            ],
            const SizedBox(height: 16),
            Text('Yarıçap: ${_radius.toInt()} metre'),
            Slider(
              value: _radius,
              min: 50,
              max: 1000,
              divisions: 19,
              onChanged: (v) {
                setState(() => _radius = v);
                widget.onPreviewChanged(_center, v);
              },
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Uygulanacak çocuklar',
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            const SizedBox(height: 4),
            if (widget.children.isEmpty)
              const Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Henüz çocuk yok. Bu bölge aileye katılan çocuklara uygulanır.',
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                ),
              )
            else
              ...widget.children.map((child) {
                return CheckboxListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text(child.name),
                  value: _selectedChildIds.contains(child.uid),
                  onChanged: (checked) {
                    setState(() {
                      if (checked == true) {
                        _selectedChildIds.add(child.uid);
                      } else {
                        _selectedChildIds.remove(child.uid);
                      }
                    });
                  },
                );
              }),
            if (widget.children.isNotEmpty && _selectedChildIds.isEmpty)
              const Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Hiç çocuk seçilmezse bölge tüm çocuklara uygulanır.',
                  style: TextStyle(color: Colors.orange, fontSize: 12),
                ),
              ),
            SwitchListTile(
              title: const Text('Çıkışta bildir'),
              value: _notifyOnExit,
              onChanged: (v) => setState(() => _notifyOnExit = v),
            ),
            SwitchListTile(
              title: const Text('Girişte bildir'),
              value: _notifyOnEnter,
              onChanged: (v) => setState(() => _notifyOnEnter = v),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context, false),
          child: const Text('İptal'),
        ),
        ElevatedButton(
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(_isEdit ? 'Kaydet' : 'Ekle'),
        ),
      ],
    );
  }
}
