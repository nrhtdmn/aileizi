import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import '../services/firebase_service.dart';
import '../services/parent_nav.dart';
import '../services/route_service.dart';
import '../models/models.dart';
import '../utils/map_launch.dart';
import '../widgets/safe_name_dialog.dart';
import '../l10n/app_locale.dart';

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  final Completer<GoogleMapController> _mapController = Completer();
  final GlobalKey _mapKey = GlobalKey();
  List<LocationData> _lastChildLocations = [];
  Marker? _parentMarker;
  Marker? _focusMarker;
  bool _showHistory = false;
  String? _selectedChildId;
  LatLng? _selectedCoordinate;
  String? _selectedCoordinateTitle;
  Set<Polyline> _historyPolylines = {};
  ParentNav? _nav;

  bool _routeDraftMode = false;
  final List<LatLng> _draftPoints = [];
  List<LatLng> _previewRoute = [];
  bool _routeBusy = false;
  /// pen | tap | auto
  String _drawMode = 'pen';
  double _deviationMeters = 20;
  static const _deviationOptions = <double>[20, 30, 50, 75, 100, 150, 200];
  DateTime? _lastPenSampleAt;
  bool _penBusy = false;
  /// true = harita kaydır/zoom (çizim yok)
  bool _mapNavigateMode = false;
  /// uzun basınca geçici kaydırma
  bool _tempNavigateByHold = false;
  final Set<int> _penPointers = {};
  Timer? _penHoldTimer;
  Offset? _penDownPos;
  /// Kayıtlı rotayı haritada odakla / görüntüle
  String? _focusedRouteId;
  bool _saveStartTracking = true;

  /// Ebeveyn: çocuğun canlı yol izi (kaçırma / nereden nereye)
  bool _traceActive = false;
  String? _traceChildId;
  String? _traceChildName;
  final List<LatLng> _tracePoints = [];
  DateTime? _traceStartedAt;
  double _traceDistanceM = 0;
  static const _traceMinDistanceM = 8.0;

  /// Harita merkezi (gezinirken canlı koordinat)
  final ValueNotifier<LatLng> _mapCenter = ValueNotifier(
    const LatLng(41.0082, 28.9784),
  );
  /// Seçili çocuğu haritada takip ederken son odak noktası
  LatLng? _lastFollowedChildPos;
  MapType _mapType = MapType.normal;

  static const _initialPosition = CameraPosition(
    target: LatLng(41.0082, 28.9784), // İstanbul
    zoom: 12,
  );

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
    _penHoldTimer?.cancel();
    _mapCenter.dispose();
    _nav?.removeListener(_onNavChanged);
    super.dispose();
  }

  Future<void> _onNavChanged() async {
    final nav = _nav;
    if (nav == null || nav.mapTarget == null || !mounted) return;
    final target = nav.mapTarget!;
    final title = nav.mapTitle ?? 'Seçilen konum';
    setState(() {
      _focusMarker = Marker(
        markerId: const MarkerId('sos-focus'),
        position: target,
        icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed),
        infoWindow: InfoWindow(title: title),
      );
      _selectedCoordinate = target;
      _selectedCoordinateTitle = title;
      _selectedChildId = null;
    });
    try {
      final ctrl = await _mapController.future;
      await ctrl.animateCamera(CameraUpdate.newLatLngZoom(target, 16));
    } catch (_) {}
    nav.consumeMapTarget();
  }

  @override
  Widget build(BuildContext context) {
    final svc = context.read<FirebaseService>();
    final l10n = context.watch<AppLocale>();

    return Scaffold(
      appBar: AppBar(
        title: Text(_routeDraftMode
            ? l10n.t('route_draft')
            : (_traceActive ? l10n.t('trace_active') : l10n.t('live_location'))),
        actions: [
          if (!_routeDraftMode)
            IconButton(
              icon: Icon(
                Icons.directions_walk,
                color: _traceActive ? Colors.orangeAccent : null,
              ),
              tooltip: _traceActive ? 'İz takibini yönet' : 'Çocuk iz takibi',
              onPressed: () => _openTraceMenu(svc),
            ),
          IconButton(
            icon: Icon(
              _routeDraftMode ? Icons.close : Icons.route,
              color: _routeDraftMode ? Colors.amber : null,
            ),
            tooltip: _routeDraftMode ? 'Rota modunu kapat' : 'Rota çiz',
            onPressed: _toggleRouteDraftMode,
          ),
          if (_selectedChildId != null && !_routeDraftMode)
            IconButton(
              icon: Icon(_showHistory ? Icons.location_on : Icons.history),
              tooltip: _showHistory ? 'Geçmişi gizle' : 'Geçmiş yolu göster',
              onPressed: _showPathHistorySheet,
            ),
          IconButton(
            icon: Icon(
              _mapType == MapType.normal
                  ? Icons.satellite_alt
                  : Icons.map_outlined,
            ),
            tooltip: _mapType == MapType.normal ? 'Uydu' : 'Harita',
            onPressed: () {
              setState(() {
                _mapType = _mapType == MapType.normal
                    ? MapType.hybrid
                    : MapType.normal;
              });
            },
          ),
          IconButton(
            icon: const Icon(Icons.my_location),
            onPressed: _centerOnChildren,
          ),
          IconButton(
            icon: const Icon(Icons.add_location_alt),
            tooltip: 'Güvenli bölge ekle',
            onPressed: _openGeofenceAtSelection,
          ),
        ],
      ),
      body: StreamBuilder<List<ChildSummary>>(
        stream: svc.watchChildren(),
        builder: (context, childrenSnapshot) {
          if (childrenSnapshot.hasError) {
            return _errorPane(
              'Çocuk listesi okunamadı',
              '${childrenSnapshot.error}',
            );
          }

          final children = childrenSnapshot.data ?? <ChildSummary>[];
          final childNames = {
            for (final child in children) child.uid: child.name,
          };

          return StreamBuilder<List<TrackedRoute>>(
            stream: svc.watchRoutes(),
            builder: (context, routesSnap) {
              final routes = routesSnap.data ?? [];
              return StreamBuilder<List<LocationData>>(
                stream: svc.watchChildLocations(),
                builder: (context, snapshot) {
                  if (snapshot.hasError) {
                    return _errorPane(
                      'Konumlar okunamadı',
                      '${snapshot.error}',
                    );
                  }

                  final locations = snapshot.data ?? [];
                  _lastChildLocations = locations;
                  _ingestLiveLocationsForTrace(locations);
                  _scheduleFollowSelectedChild(locations, childNames);
                  final markers = _buildMarkers(locations, childNames);
                  final locationByChild = {
                    for (final loc in locations) loc.childId: loc,
                  };
                  final routePolylines = _buildRoutePolylines(routes);
                  final routeMarkers = _buildRouteMarkers(routes);
                  final draftMarkers = <Marker>{
                    for (var i = 0; i < _draftPoints.length; i++)
                      Marker(
                        markerId: MarkerId('draft-$i'),
                        position: _draftPoints[i],
                        icon: BitmapDescriptor.defaultMarkerWithHue(
                          i == 0
                              ? BitmapDescriptor.hueGreen
                              : (i == _draftPoints.length - 1
                                  ? BitmapDescriptor.hueRed
                                  : BitmapDescriptor.hueAzure),
                        ),
                        infoWindow: InfoWindow(
                          title: i == 0
                              ? 'Başlangıç'
                              : (i == _draftPoints.length - 1
                                  ? 'Bitiş'
                                  : 'Nokta ${i + 1}'),
                        ),
                      ),
                  };

                  return StreamBuilder<List<Geofence>>(
                    stream: svc.watchGeofences(),
                    builder: (context, fenceSnap) {
                      final fences = fenceSnap.data ?? const <Geofence>[];
                      final fenceCircles = <Circle>{
                        for (final f in fences)
                          Circle(
                            circleId: CircleId('gf-${f.id}'),
                            center: LatLng(f.centerLat, f.centerLng),
                            radius: f.radiusMeters,
                            fillColor: const Color(0xFF2D6A4F).withOpacity(0.12),
                            strokeColor: const Color(0xFF2D6A4F),
                            strokeWidth: 2,
                          ),
                      };
                      final fenceMarkers = <Marker>{
                        for (final f in fences)
                          Marker(
                            markerId: MarkerId('gf-m-${f.id}'),
                            position: LatLng(f.centerLat, f.centerLng),
                            icon: BitmapDescriptor.defaultMarkerWithHue(
                              BitmapDescriptor.hueGreen,
                            ),
                            infoWindow: InfoWindow(
                              title: f.name,
                              snippet:
                                  '${f.centerLat.toStringAsFixed(5)}, ${f.centerLng.toStringAsFixed(5)} • ${f.radiusMeters.toInt()} m',
                            ),
                            onTap: () => _selectCoordinate(
                              title: f.name,
                              coordinate: LatLng(f.centerLat, f.centerLng),
                            ),
                          ),
                      };

                      return Stack(
                    key: _mapKey,
                    children: [
                      GoogleMap(
                        initialCameraPosition: _initialPosition,
                        mapType: _mapType,
                        onMapCreated: (ctrl) {
                          if (!_mapController.isCompleted) {
                            _mapController.complete(ctrl);
                          }
                          WidgetsBinding.instance
                              .addPostFrameCallback((_) => _onNavChanged());
                        },
                        onCameraMove: (pos) {
                          _mapCenter.value = pos.target;
                        },
                        onCameraIdle: () {
                          if (_selectedChildId != null) return;
                          if (_selectedCoordinate != null &&
                              _selectedCoordinateTitle != 'Harita merkezi') {
                            return;
                          }
                          final c = _mapCenter.value;
                          final prev = _selectedCoordinate;
                          if (prev != null &&
                              (prev.latitude - c.latitude).abs() < 0.00001 &&
                              (prev.longitude - c.longitude).abs() < 0.00001) {
                            return;
                          }
                          _selectCoordinate(
                            title: 'Harita merkezi',
                            coordinate: c,
                          );
                        },
                        markers: {
                          ...markers,
                          ...routeMarkers,
                          ...fenceMarkers,
                          if (_drawMode != 'pen') ...draftMarkers,
                          if (_parentMarker != null) _parentMarker!,
                          if (_focusMarker != null) _focusMarker!,
                        },
                        circles: fenceCircles,
                        polylines: {
                          ..._historyPolylines,
                          ...routePolylines,
                          if (_tracePoints.length >= 2)
                            Polyline(
                              polylineId: const PolylineId('parent-live-trace'),
                              points: List.of(_tracePoints),
                              color: const Color(0xFFE85D04),
                              width: 6,
                            ),
                          if (_previewRoute.length >= 2)
                            Polyline(
                              polylineId: const PolylineId('preview-route'),
                              points: _previewRoute,
                              color: Colors.deepOrange,
                              width: 5,
                            ),
                          if (_routeDraftMode &&
                              _draftPoints.length >= 2 &&
                              _previewRoute.isEmpty)
                            Polyline(
                              polylineId: const PolylineId('draft-manual'),
                              points: _draftPoints,
                              color: Colors.blue,
                              width: 4,
                            ),
                        },
                        myLocationButtonEnabled: false,
                        zoomControlsEnabled: false,
                        // Kalem modunda da zoom/kaydır açık; overlay IgnorePointer ile yönetilir
                        scrollGesturesEnabled: true,
                        zoomGesturesEnabled: true,
                        rotateGesturesEnabled: true,
                        tiltGesturesEnabled: false,
                        padding: EdgeInsets.only(
                          bottom: _selectedCoordinate != null ? 120 : 72,
                          right: 48,
                        ),
                        onTap: _onMapTap,
                      ),
                      if (!_routeDraftMode)
                        Positioned(
                          right: 10,
                          bottom: _selectedCoordinate != null
                              ? (_traceActive ? 108 : 68)
                              : (_traceActive ? 100 : 72),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Material(
                                elevation: 2,
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(8),
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(8),
                                  onTap: () async {
                                    try {
                                      final c = await _mapController.future;
                                      await c.animateCamera(
                                          CameraUpdate.zoomIn());
                                    } catch (_) {}
                                  },
                                  child: const SizedBox(
                                    width: 34,
                                    height: 34,
                                    child: Icon(Icons.add, size: 18),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 4),
                              Material(
                                elevation: 2,
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(8),
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(8),
                                  onTap: () async {
                                    try {
                                      final c = await _mapController.future;
                                      await c.animateCamera(
                                          CameraUpdate.zoomOut());
                                    } catch (_) {}
                                  },
                                  child: const SizedBox(
                                    width: 34,
                                    height: 34,
                                    child: Icon(Icons.remove, size: 18),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      // Harita merkezi işareti + canlı koordinat
                      if (!_routeDraftMode)
                        IgnorePointer(
                          child: Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(
                                  Icons.add,
                                  size: 28,
                                  color: Color(0xCC1F2937),
                                  shadows: [
                                    Shadow(
                                      color: Colors.white,
                                      blurRadius: 4,
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 2),
                                ValueListenableBuilder<LatLng>(
                                  valueListenable: _mapCenter,
                                  builder: (context, center, _) {
                                    final text =
                                        '${center.latitude.toStringAsFixed(5)}, ${center.longitude.toStringAsFixed(5)}';
                                    return Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                        vertical: 2,
                                      ),
                                      decoration: BoxDecoration(
                                        color: Colors.black.withOpacity(0.55),
                                        borderRadius: BorderRadius.circular(6),
                                      ),
                                      child: Text(
                                        text,
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 10,
                                          fontWeight: FontWeight.w600,
                                          letterSpacing: 0.2,
                                        ),
                                      ),
                                    );
                                  },
                                ),
                              ],
                            ),
                          ),
                        ),
                      if (_routeDraftMode && _drawMode == 'pen')
                        Positioned.fill(
                          child: IgnorePointer(
                            // 2+ parmak veya Kaydır modu → olaylar haritaya gider
                            ignoring: _shouldPassGesturesToMap,
                            child: Listener(
                              behavior: HitTestBehavior.opaque,
                              onPointerDown: _onPenPointerDown,
                              onPointerMove: _onPenPointerMove,
                              onPointerUp: _onPenPointerUp,
                              onPointerCancel: _onPenPointerUp,
                            ),
                          ),
                        ),
                      if (_routeDraftMode)
                        Positioned(
                          left: 12,
                          right: 12,
                          top: 12,
                          child: Material(
                            elevation: 4,
                            borderRadius: BorderRadius.circular(12),
                            child: _buildRouteDraftPanel(children),
                          ),
                        ),
                      if (!_routeDraftMode &&
                          children.isEmpty &&
                          locations.isEmpty)
                        Positioned(
                          top: 12,
                          left: 12,
                          right: 12,
                          child: Card(
                            color: Colors.orange.shade50,
                            child: const Padding(
                              padding: EdgeInsets.all(12),
                              child: Text(
                                'Henüz bağlı çocuk yok veya konum gelmedi. '
                                'Ayarlar’dan davet kodu ile çocuk cihazını ekleyin.',
                                style: TextStyle(fontSize: 13),
                              ),
                            ),
                          ),
                        ),
                      if (_traceActive && !_routeDraftMode)
                        Positioned(
                          top: 56,
                          left: 12,
                          right: 12,
                          child: _buildTraceBanner(),
                        ),
                      if (!_routeDraftMode &&
                          (children.isNotEmpty || locations.isNotEmpty))
                        Positioned(
                          bottom: _selectedCoordinate == null
                              ? (_traceActive ? 56 : 10)
                              : 52,
                          left: 10,
                          right: 52,
                          child: _buildChildCards(
                            children: children,
                            locations: locations,
                            locationByChild: locationByChild,
                            childNames: childNames,
                          ),
                        ),
                      if (_traceActive && !_routeDraftMode)
                        Positioned(
                          bottom: 10,
                          left: 10,
                          right: 52,
                          child: _buildTraceActions(),
                        ),
                      if (!_routeDraftMode &&
                          !_traceActive &&
                          _selectedCoordinate != null)
                        Positioned(
                          bottom: 8,
                          left: 10,
                          right: 52,
                          child: _buildCoordinateCard(),
                        ),
                      if (!_routeDraftMode)
                        Positioned(
                          top: 12,
                          left: 12,
                          child: Material(
                            color: Colors.white.withOpacity(0.95),
                            borderRadius: BorderRadius.circular(20),
                            child: InkWell(
                              borderRadius: BorderRadius.circular(20),
                              onTap: () => _showRoutesSheet(routes, childNames),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 12, vertical: 8),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Icon(Icons.route, size: 18),
                                    const SizedBox(width: 6),
                                    Text(
                                      routes.isEmpty
                                          ? 'Rotalar'
                                          : '${routes.length} rota'
                                              '${routes.where((r) => r.recording).isEmpty ? '' : ' • ${routes.where((r) => r.recording).length} canlı'}'
                                              '${routes.where((r) => r.active).isEmpty ? '' : ' • ${routes.where((r) => r.active).length} takip'}',
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  );
                    },
                  );
                },
              );
            },
          );
        },
      ),
    );
  }

  void _toggleRouteDraftMode() {
    setState(() {
      _routeDraftMode = !_routeDraftMode;
      if (!_routeDraftMode) {
        _draftPoints.clear();
        _previewRoute = [];
        _mapNavigateMode = false;
        _tempNavigateByHold = false;
        _penPointers.clear();
        _penHoldTimer?.cancel();
      } else {
        _drawMode = 'pen';
        _mapNavigateMode = false;
      }
    });
  }

  bool get _shouldPassGesturesToMap =>
      _mapNavigateMode || _tempNavigateByHold || _penPointers.length >= 2;

  void _onPenPointerDown(PointerDownEvent e) {
    _penPointers.add(e.pointer);
    if (_penPointers.length >= 2) {
      _penHoldTimer?.cancel();
      setState(() {}); // IgnorePointer → harita (pinch/kaydır)
      return;
    }

    _penDownPos = e.position;
    _penHoldTimer?.cancel();
    _penHoldTimer = Timer(const Duration(milliseconds: 380), () {
      if (!mounted) return;
      if (_penPointers.length == 1 && !_mapNavigateMode) {
        setState(() => _tempNavigateByHold = true);
        // Bundan sonra parmak haritayı kaydırır
      }
    });

    if (!_shouldPassGesturesToMap) {
      _onPenGlobalPoint(e.position);
    } else {
      setState(() {});
    }
  }

  void _onPenPointerMove(PointerMoveEvent e) {
    if (!_penPointers.contains(e.pointer)) return;

    if (_penPointers.length >= 2 || _mapNavigateMode || _tempNavigateByHold) {
      return;
    }

    if (_penDownPos != null &&
        (e.position - _penDownPos!).distance > 14) {
      // Hareket etti → uzun bas kaydırma iptal, çizim devam
      _penHoldTimer?.cancel();
    }

    _onPenGlobalPoint(e.position);
  }

  void _onPenPointerUp(PointerEvent e) {
    _penPointers.remove(e.pointer);
    _penHoldTimer?.cancel();

    if (_penPointers.isEmpty) {
      final wasTemp = _tempNavigateByHold;
      _tempNavigateByHold = false;
      _penDownPos = null;
      if (_draftPoints.length >= 2) {
        _previewRoute = List.of(_draftPoints);
      }
      if (wasTemp || mounted) setState(() {});
    } else if (_penPointers.length < 2) {
      setState(() {}); // tekrar çizim katmanı
    }
  }

  void _onMapTap(LatLng pos) {
    if (_routeDraftMode) {
      if (_drawMode == 'pen') return;
      setState(() {
        _draftPoints.add(pos);
        if (_drawMode == 'tap') {
          _previewRoute = List.of(_draftPoints);
        } else {
          _previewRoute = [];
        }
        _selectedCoordinate = pos;
        _selectedCoordinateTitle = 'Rota noktası ${_draftPoints.length}';
      });
      return;
    }
    _selectCoordinate(title: 'Seçilen nokta', coordinate: pos);
  }

  Future<void> _onPenGlobalPoint(Offset globalPosition) async {
    if (!_routeDraftMode || _drawMode != 'pen' || !mounted) return;
    if (_shouldPassGesturesToMap) return;

    // Üst panelin üzerindeyse çizme (butonlar çalışsın).
    final panelTop = MediaQuery.paddingOf(context).top + 12;
    if (globalPosition.dy < panelTop + 160) return;

    final now = DateTime.now();
    if (_lastPenSampleAt != null &&
        now.difference(_lastPenSampleAt!) < const Duration(milliseconds: 35)) {
      return;
    }
    if (_penBusy) return;
    _lastPenSampleAt = now;
    _penBusy = true;

    try {
      final box = _mapKey.currentContext?.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize) return;

      final local = box.globalToLocal(globalPosition);
      if (local.dx < 0 ||
          local.dy < 0 ||
          local.dx > box.size.width ||
          local.dy > box.size.height) {
        return;
      }

      final dpr = MediaQuery.devicePixelRatioOf(context);
      final ctrl = await _mapController.future;
      final latLng = await ctrl.getLatLng(ScreenCoordinate(
        x: (local.dx * dpr).round(),
        y: (local.dy * dpr).round(),
      ));

      if (_draftPoints.isNotEmpty) {
        final last = _draftPoints.last;
        final dist = Geolocator.distanceBetween(
          last.latitude,
          last.longitude,
          latLng.latitude,
          latLng.longitude,
        );
        if (dist < 3) return;
      }

      if (!mounted) return;
      setState(() {
        _draftPoints.add(latLng);
        _previewRoute = List.of(_draftPoints);
      });
    } catch (_) {
    } finally {
      _penBusy = false;
    }
  }

  Set<Marker> _buildRouteMarkers(List<TrackedRoute> routes) {
    final out = <Marker>{};
    for (final r in routes) {
      if (r.points.isEmpty) continue;
      if (!(r.active || r.recording || r.id == _focusedRouteId)) continue;
      out.add(Marker(
        markerId: MarkerId('route-start-${r.id}'),
        position: LatLng(r.points.first.latitude, r.points.first.longitude),
        infoWindow: InfoWindow(title: '${r.name} — A'),
        icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueGreen),
      ));
      if (r.points.length > 1) {
        out.add(Marker(
          markerId: MarkerId('route-end-${r.id}'),
          position: LatLng(r.points.last.latitude, r.points.last.longitude),
          infoWindow: InfoWindow(
            title: r.recording ? '${r.name} — canlı' : '${r.name} — B',
          ),
          icon: BitmapDescriptor.defaultMarkerWithHue(
            r.recording
                ? BitmapDescriptor.hueOrange
                : BitmapDescriptor.hueRed,
          ),
        ));
      }
    }
    return out;
  }

  Set<Polyline> _buildRoutePolylines(List<TrackedRoute> routes) {
    // Takip aktif, canlı kayıt veya odaklanan rota
    return routes.where((r) {
      if (r.points.length < 2) return false;
      return r.active || r.recording || r.id == _focusedRouteId;
    }).map((r) {
      final focused = r.id == _focusedRouteId;
      final Color color;
      if (r.isDeviated) {
        color = Colors.red;
      } else if (r.recording) {
        color = const Color(0xFFE85D04);
      } else if (r.active) {
        color = const Color(0xFF1D3557);
      } else {
        color = Colors.deepPurple.shade300;
      }
      return Polyline(
        polylineId: PolylineId('route-${r.id}'),
        points: r.points.map((p) => LatLng(p.latitude, p.longitude)).toList(),
        color: color,
        width: focused || r.recording ? 7 : (r.active ? 5 : 4),
        patterns: (r.active || r.recording)
            ? const []
            : [PatternItem.dash(20), PatternItem.gap(12)],
      );
    }).toSet();
  }

  Future<void> _focusRouteOnMap(TrackedRoute route) async {
    if (route.points.length < 2) return;
    setState(() => _focusedRouteId = route.id);
    try {
      final ctrl = await _mapController.future;
      double minLat = route.points.first.latitude;
      double maxLat = route.points.first.latitude;
      double minLng = route.points.first.longitude;
      double maxLng = route.points.first.longitude;
      for (final p in route.points) {
        if (p.latitude < minLat) minLat = p.latitude;
        if (p.latitude > maxLat) maxLat = p.latitude;
        if (p.longitude < minLng) minLng = p.longitude;
        if (p.longitude > maxLng) maxLng = p.longitude;
      }
      await ctrl.animateCamera(CameraUpdate.newLatLngBounds(
        LatLngBounds(
          southwest: LatLng(minLat - 0.002, minLng - 0.002),
          northeast: LatLng(maxLat + 0.002, maxLng + 0.002),
        ),
        60,
      ));
    } catch (_) {}
  }

  Widget _buildRouteDraftPanel(List<ChildSummary> children) {
    final String hint;
    if (_drawMode == 'pen') {
      if (_mapNavigateMode || _tempNavigateByHold) {
        hint = 'Kaydırma açık — haritayı sürükle / iki parmakla yakınlaştır';
      } else if (_draftPoints.isEmpty) {
        hint =
            'Tek parmak: çiz • İki parmak / uzun bas: kaydır • veya Kaydır tuşu';
      } else {
        hint = 'Çizim: ${_draftPoints.length} nokta';
      }
    } else if (_drawMode == 'auto') {
      hint = _draftPoints.length < 2
          ? 'Başlangıç ve bitişe dokun, sonra yol rotası oluştur'
          : 'Uçlar seçildi — yol rotası oluşturabilirsin';
    } else {
      hint = _draftPoints.isEmpty
          ? 'Haritaya dokunarak rota noktalarını ekle'
          : '${_draftPoints.length} nokta seçildi';
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(hint, style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(
                  value: 'pen',
                  label: Text('Kalem'),
                  icon: Icon(Icons.draw, size: 18),
                ),
                ButtonSegment(
                  value: 'tap',
                  label: Text('Nokta'),
                  icon: Icon(Icons.touch_app, size: 18),
                ),
                ButtonSegment(
                  value: 'auto',
                  label: Text('Otomatik'),
                  icon: Icon(Icons.auto_fix_high, size: 18),
                ),
              ],
              selected: {_drawMode},
              onSelectionChanged: (s) {
                setState(() {
                  _drawMode = s.first;
                  _draftPoints.clear();
                  _previewRoute = [];
                  _mapNavigateMode = false;
                  _tempNavigateByHold = false;
                });
              },
            ),
            if (_drawMode == 'pen') ...[
              const SizedBox(height: 8),
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(
                    value: false,
                    label: Text('Çiz'),
                    icon: Icon(Icons.draw, size: 18),
                  ),
                  ButtonSegment(
                    value: true,
                    label: Text('Kaydır'),
                    icon: Icon(Icons.open_with, size: 18),
                  ),
                ],
                selected: {_mapNavigateMode},
                onSelectionChanged: (s) {
                  setState(() {
                    _mapNavigateMode = s.first;
                    _tempNavigateByHold = false;
                  });
                },
              ),
            ],
            const SizedBox(height: 10),
            Row(
              children: [
                const Text('Sapma:', style: TextStyle(fontSize: 13)),
                const SizedBox(width: 8),
                Expanded(
                  child: DropdownButtonFormField<double>(
                    value: _deviationMeters,
                    isDense: true,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      contentPadding:
                          EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    ),
                    items: _deviationOptions
                        .map((m) => DropdownMenuItem(
                              value: m,
                              child: Text('${m.toInt()} metre'),
                            ))
                        .toList(),
                    onChanged: (v) {
                      if (v != null) setState(() => _deviationMeters = v);
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (_drawMode == 'auto')
                  OutlinedButton.icon(
                    onPressed: _draftPoints.length >= 2 && !_routeBusy
                        ? _buildAutoRoute
                        : null,
                    icon: _routeBusy
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.route),
                    label: const Text('Yol rotası oluştur'),
                  ),
                TextButton(
                  onPressed: _draftPoints.isEmpty
                      ? null
                      : () => setState(() {
                            _draftPoints.clear();
                            _previewRoute = [];
                          }),
                  child: const Text('Temizle'),
                ),
                FilledButton.icon(
                  onPressed: (_previewRoute.length >= 2 ||
                              (_drawMode != 'auto' &&
                                  _draftPoints.length >= 2)) &&
                          children.isNotEmpty
                      ? () => _saveRoute(children)
                      : null,
                  icon: const Icon(Icons.save),
                  label: const Text('Kaydet'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _buildAutoRoute() async {
    if (_draftPoints.length < 2) return;
    setState(() => _routeBusy = true);
    try {
      final start = _draftPoints.first;
      final end = _draftPoints.last;
      final points = await RouteService.fetchDrivingRoute(
        startLat: start.latitude,
        startLng: start.longitude,
        endLat: end.latitude,
        endLng: end.longitude,
      );
      if (!mounted) return;
      setState(() {
        _previewRoute =
            points.map((p) => LatLng(p.latitude, p.longitude)).toList();
      });
      _showSnack('Otomatik rota hazır (${points.length} nokta).');
    } catch (e) {
      _showSnack('Otomatik rota alınamadı: $e');
    } finally {
      if (mounted) setState(() => _routeBusy = false);
    }
  }

  Future<void> _saveRoute(List<ChildSummary> children) async {
    final path = _previewRoute.length >= 2 ? _previewRoute : _draftPoints;
    if (path.length < 2) return;

    final mode = _drawMode == 'auto' ? 'auto' : 'manual';
    final defaultName =
        'Rota ${DateTime.now().day}.${DateTime.now().month} ${DateTime.now().hour}:${DateTime.now().minute.toString().padLeft(2, '0')}';

    final result = await showDialog<_SaveRouteDialogResult>(
      context: context,
      builder: (ctx) => _SaveRouteDialog(
        children: children,
        initialName: defaultName,
        initialDeviation: _deviationMeters,
        initialStartTracking: _saveStartTracking,
        drawMode: _drawMode,
        pointCount: path.length,
        deviationOptions: _deviationOptions,
      ),
    );
    if (result == null || !mounted) return;

    try {
      final svc = context.read<FirebaseService>();
      final id = await svc.addRoute(TrackedRoute(
        id: '',
        name: result.name,
        childId: result.childId,
        mode: mode,
        points: path
            .map((p) =>
                RoutePoint(latitude: p.latitude, longitude: p.longitude))
            .toList(),
        deviationMeters: result.deviation,
        active: result.startTracking,
      ));
      if (!mounted) return;
      setState(() {
        _routeDraftMode = false;
        _draftPoints.clear();
        _previewRoute = [];
        _deviationMeters = result.deviation;
        _saveStartTracking = result.startTracking;
        _focusedRouteId = id;
      });
      await _focusRouteOnMap(TrackedRoute(
        id: id,
        name: result.name,
        childId: result.childId,
        mode: mode,
        points: path
            .map((p) =>
                RoutePoint(latitude: p.latitude, longitude: p.longitude))
            .toList(),
        deviationMeters: result.deviation,
        active: result.startTracking,
      ));
      _showSnack(result.startTracking
          ? '“${result.name}” kaydedildi — takip aktif (${result.deviation.toInt()} m sapma).'
          : '“${result.name}” kaydedildi. İstediğin zaman listeden açıp takip başlat.');
    } catch (e) {
      _showSnack('Rota kaydedilemedi: $e');
    }
  }

  Future<void> _renameRoute(TrackedRoute route) async {
    final name = await showSafeNameDialog(
      context: context,
      title: 'Rota adını düzenle',
      initialName: route.name,
      label: 'Rota adı',
    );
    if (name == null || name.isEmpty || !mounted) return;
    try {
      await context.read<FirebaseService>().renameRoute(route.id, name);
      if (mounted) _showSnack('İsim güncellendi: $name');
    } catch (e) {
      if (mounted) _showSnack('Güncellenemedi: $e');
    }
  }

  Future<void> _editRouteDeviation(TrackedRoute route) async {
    var deviation = route.deviationMeters;
    if (!_deviationOptions.contains(deviation)) {
      deviation = _deviationOptions.reduce(
          (a, b) => (a - deviation).abs() < (b - deviation).abs() ? a : b);
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: Text('${route.name} — sapma'),
          content: DropdownButtonFormField<double>(
            value: deviation,
            decoration: const InputDecoration(
              labelText: 'Sapma eşiği',
              border: OutlineInputBorder(),
              helperText: 'Bu mesafeden fazla sapınca bildirim',
            ),
            items: _deviationOptions
                .map((m) => DropdownMenuItem(
                      value: m,
                      child: Text('${m.toInt()} metre'),
                    ))
                .toList(),
            onChanged: (v) {
              if (v != null) setLocal(() => deviation = v);
            },
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('İptal')),
            ElevatedButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Kaydet')),
          ],
        ),
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await context
          .read<FirebaseService>()
          .setRouteDeviation(route.id, deviation);
      _showSnack('Sapma ${deviation.toInt()} m olarak güncellendi.');
    } catch (e) {
      _showSnack('Güncellenemedi: $e');
    }
  }

  Future<void> _showRoutesSheet(
    List<TrackedRoute> routes,
    Map<String, String> childNames,
  ) async {
    final svc = context.read<FirebaseService>();
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        return SafeArea(
          child: DraggableScrollableSheet(
            expand: false,
            initialChildSize: 0.6,
            minChildSize: 0.35,
            maxChildSize: 0.92,
            builder: (ctx, scrollCtrl) {
              return StreamBuilder<List<TrackedRoute>>(
                stream: svc.watchRoutes(),
                initialData: routes,
                builder: (context, snap) {
                  final list = snap.data ?? routes;
                  return ListView(
                    controller: scrollCtrl,
                    children: [
                      const ListTile(
                        title: Text(
                          'Kayıtlı rotalar',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                        subtitle: Text(
                          'Görüntüle • Ad • Rota takip • Sapma • Sil',
                        ),
                      ),
                      if (list.isEmpty)
                        const Padding(
                          padding: EdgeInsets.all(24),
                          child: Text(
                            'Henüz kayıtlı rota yok.\nHaritada rota ikonuyla çizip Kaydet de.',
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ...list.map((r) {
                        final childLabel =
                            childNames[r.childId] ?? r.childId;
                        final focused = _focusedRouteId == r.id;
                        return Card(
                          margin: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 6),
                          color: focused ? Colors.blue.shade50 : null,
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Icon(
                                      Icons.route,
                                      color: r.isDeviated
                                          ? Colors.red
                                          : (r.active
                                              ? const Color(0xFF2D6A4F)
                                              : Colors.grey),
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        r.name,
                                        style: const TextStyle(
                                            fontWeight: FontWeight.w600),
                                      ),
                                    ),
                                    IconButton(
                                      tooltip: 'Haritada gör',
                                      icon: Icon(
                                        Icons.visibility,
                                        color: focused
                                            ? Colors.blue
                                            : Colors.black54,
                                      ),
                                      onPressed: () {
                                        Navigator.pop(ctx);
                                        _focusRouteOnMap(r);
                                        _showSnack(
                                            '“${r.name}” haritada gösteriliyor');
                                      },
                                    ),
                                    IconButton(
                                      tooltip: 'Adı düzenle',
                                      icon: const Icon(Icons.edit_outlined),
                                      onPressed: () {
                                        Navigator.pop(ctx);
                                        _renameRoute(r);
                                      },
                                    ),
                                    IconButton(
                                      tooltip: 'Sapma eşiği',
                                      icon: const Icon(Icons.straighten),
                                      onPressed: () {
                                        Navigator.pop(ctx);
                                        _editRouteDeviation(r);
                                      },
                                    ),
                                    IconButton(
                                      tooltip: 'Sil',
                                      icon: const Icon(Icons.delete_outline,
                                          color: Colors.red),
                                      onPressed: () =>
                                          _confirmDeleteRoute(ctx, r),
                                    ),
                                  ],
                                ),
                                Text(
                                  '$childLabel • '
                                  '${r.recording ? 'Canlı kayıt' : (r.mode == 'auto' ? 'Otomatik' : (r.mode == 'recorded' ? 'Yürüyüş' : 'Manuel'))} • '
                                  'Sapma ${r.deviationMeters.toInt()} m • '
                                  '${r.points.length} nokta'
                                  '${r.isDeviated ? ' • SAPIYOR' : ''}'
                                  '${r.cancelledBy == 'child' ? ' • Çocuk iptal etti' : ''}',
                                  style: const TextStyle(
                                      fontSize: 12, color: Colors.black54),
                                ),
                                if (r.recording)
                                  const Padding(
                                    padding: EdgeInsets.only(bottom: 4),
                                    child: Text(
                                      'Çocuk yürüyor — rota canlı çiziliyor',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: Color(0xFFE85D04),
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                SwitchListTile(
                                  contentPadding: EdgeInsets.zero,
                                  title: Text(
                                    r.active
                                        ? 'Rota takip aktif'
                                        : 'Rota takip kapalı',
                                    style: const TextStyle(fontSize: 14),
                                  ),
                                  subtitle: Text(
                                    r.active
                                        ? 'Haritada çizili; ${r.deviationMeters.toInt()} m sapınca bildirim. Çocuk iptal edene kadar devam eder.'
                                        : 'Açınca takip başlar ve haritada görünür.',
                                    style: const TextStyle(fontSize: 11),
                                  ),
                                  value: r.active,
                                  onChanged: (v) async {
                                    try {
                                      await svc.setRouteActive(r.id, v);
                                      if (v && mounted) {
                                        setState(
                                            () => _focusedRouteId = r.id);
                                      }
                                      if (mounted) {
                                        _showSnack(v
                                            ? '“${r.name}” takip aktif'
                                            : '“${r.name}” takip kapatıldı');
                                      }
                                    } catch (e) {
                                      if (mounted) {
                                        _showSnack(
                                            'Takip güncellenemedi: $e');
                                      }
                                    }
                                  },
                                ),
                              ],
                            ),
                          ),
                        );
                      }),
                      const SizedBox(height: 16),
                    ],
                  );
                },
              );
            },
          ),
        );
      },
    );
  }

  Future<void> _confirmDeleteRoute(
      BuildContext sheetCtx, TrackedRoute route) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rota silinsin mi?'),
        content: Text('“${route.name}” kalıcı silinecek.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('İptal'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child:
                const Text('Sil', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await context.read<FirebaseService>().deleteRoute(route.id);
      if (_focusedRouteId == route.id && mounted) {
        setState(() => _focusedRouteId = null);
      }
      if (mounted) _showSnack('Rota silindi.');
    } catch (e) {
      if (mounted) _showSnack('Silinemedi: $e');
    }
  }

  Widget _errorPane(String title, String detail) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, color: Colors.red, size: 48),
            const SizedBox(height: 12),
            Text(title,
                style:
                    const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            const SizedBox(height: 8),
            Text(detail,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.grey, fontSize: 12)),
            const SizedBox(height: 12),
            const Text(
              'Firebase Console → Firestore → Rules güncel mi kontrol et.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  Set<Marker> _buildMarkers(
      List<LocationData> locations, Map<String, String> childNames) {
    return locations.where(_hasRealLocation).map((loc) {
      final childName = childNames[loc.childId] ?? _shortId(loc.childId);
      return Marker(
        markerId: MarkerId(loc.childId),
        position: LatLng(loc.latitude, loc.longitude),
        infoWindow: InfoWindow(
          title: childName,
          snippet:
              'Batarya: ${loc.batteryLevel}% • ${_formatSpeedKmh(loc.speed, speedKmh: loc.speedKmh)} • ${_formatTime(loc.timestamp)}',
        ),
        icon: BitmapDescriptor.defaultMarkerWithHue(
          _isChildOnline(loc)
              ? BitmapDescriptor.hueGreen
              : BitmapDescriptor.hueOrange,
        ),
        onTap: () => _selectCoordinate(
          title: childName,
          coordinate: LatLng(loc.latitude, loc.longitude),
          childId: loc.childId,
        ),
      );
    }).toSet();
  }

  bool _hasRealLocation(LocationData loc) {
    // 0,0 placeholder değilse gerçek konum kabul et.
    final nonZero = loc.latitude.abs() > 0.00001 || loc.longitude.abs() > 0.00001;
    return nonZero;
  }

  Future<void> _showPathHistorySheet() async {
    if (_selectedChildId == null) {
      _showSnack('Önce haritadan bir çocuk seç.');
      return;
    }
    final hours = await showModalBottomSheet<int>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(
              title: Text('Geçmiş yolu göster',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              subtitle: Text(
                  'Çocuğun nereden nereye gittiğini konum geçmişinden çiz'),
            ),
            ListTile(
              leading: const Icon(Icons.timelapse),
              title: const Text('Son 1 saat'),
              onTap: () => Navigator.pop(ctx, 1),
            ),
            ListTile(
              leading: const Icon(Icons.schedule),
              title: const Text('Son 6 saat'),
              onTap: () => Navigator.pop(ctx, 6),
            ),
            ListTile(
              leading: const Icon(Icons.history),
              title: const Text('Son 24 saat'),
              onTap: () => Navigator.pop(ctx, 24),
            ),
            if (_showHistory)
              ListTile(
                leading: const Icon(Icons.visibility_off),
                title: const Text('Geçmiş yolu gizle'),
                onTap: () => Navigator.pop(ctx, 0),
              ),
            ListTile(
              leading: const Icon(Icons.save_alt, color: Color(0xFF2D6A4F)),
              title: const Text('Görünen geçmişi rota olarak kaydet'),
              onTap: () => Navigator.pop(ctx, -1),
            ),
          ],
        ),
      ),
    );
    if (hours == null || !mounted) return;
    if (hours == 0) {
      setState(() {
        _showHistory = false;
        _historyPolylines = {};
      });
      return;
    }
    if (hours == -1) {
      await _saveHistoryAsRoute();
      return;
    }
    await _loadPathHistory(hours: hours);
  }

  Future<void> _loadPathHistory({required int hours}) async {
    if (_selectedChildId == null) return;
    final svc = context.read<FirebaseService>();
    try {
      final history =
          await svc.getLocationHistory(_selectedChildId!, hours: hours);
      final points = history
          .where((h) =>
              h.latitude.abs() > 0.00001 || h.longitude.abs() > 0.00001)
          .map((h) => LatLng(h.latitude, h.longitude))
          .toList();
      if (!mounted) return;
      setState(() {
        _showHistory = true;
        _historyPolylines = points.length >= 2
            ? {
                Polyline(
                  polylineId: const PolylineId('history'),
                  points: points,
                  color: const Color(0xFF1D3557),
                  width: 5,
                ),
              }
            : {};
      });
      if (points.length < 2) {
        _showSnack('Bu sürede yeterli konum kaydı yok.');
        return;
      }
      await _fitPoints(points);
      _showSnack('Son $hours saatin yolu haritada (${points.length} nokta).');
    } catch (e) {
      _showSnack('Geçmiş yüklenemedi: $e');
    }
  }

  Future<void> _saveHistoryAsRoute() async {
    List<LatLng> points = const [];
    for (final p in _historyPolylines) {
      if (p.polylineId.value == 'history') {
        points = p.points;
        break;
      }
    }
    if (points.length < 2 || _selectedChildId == null) {
      _showSnack('Önce geçmiş yolu göster, sonra kaydet.');
      return;
    }
    await _savePointsAsRoute(
      childId: _selectedChildId!,
      childName: _selectedCoordinateTitle ?? 'Çocuk',
      points: points,
      defaultName:
          'Geçmiş yol ${DateTime.now().day}.${DateTime.now().month}',
    );
  }

  Future<void> _openTraceMenu(FirebaseService svc) async {
    if (_traceActive) {
      await showModalBottomSheet<void>(
        context: context,
        builder: (ctx) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                title: Text('İz takibi: ${_traceChildName ?? 'Çocuk'}'),
                subtitle: Text(
                    '${_tracePoints.length} nokta • ${_formatTraceDistance()}'),
              ),
              ListTile(
                leading: const Icon(Icons.stop, color: Colors.orange),
                title: const Text('Bitir ve kaydet'),
                onTap: () {
                  Navigator.pop(ctx);
                  _finishTraceAndSave();
                },
              ),
              ListTile(
                leading: const Icon(Icons.close, color: Colors.red),
                title: const Text('İptal et (kaydetme)'),
                onTap: () {
                  Navigator.pop(ctx);
                  _cancelTrace();
                },
              ),
            ],
          ),
        ),
      );
      return;
    }

    List<ChildSummary> children = [];
    try {
      children =
          await svc.watchChildren().first.timeout(const Duration(seconds: 5));
    } catch (_) {}
    if (!mounted) return;
    if (children.isEmpty) {
      _showSnack('Önce bir çocuk aileye katılmalı.');
      return;
    }

    final selected = await showModalBottomSheet<({String id, String name, int hours})>(
      context: context,
      builder: (ctx) {
        String childId = _selectedChildId ?? children.first.uid;
        var hours = 2;
        return StatefulBuilder(
          builder: (ctx, setLocal) => SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'Çocuk iz takibi',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Çocuğun canlı konumundan yol çizilir. '
                    'İstersen son saatleri de başlangıca ekle — '
                    'nereden nereye gittiğini görürsün.',
                    style: TextStyle(fontSize: 13, color: Colors.black54),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    value: childId,
                    decoration: const InputDecoration(
                      labelText: 'Çocuk',
                      border: OutlineInputBorder(),
                    ),
                    items: children
                        .map((c) => DropdownMenuItem(
                              value: c.uid,
                              child: Text(c.name),
                            ))
                        .toList(),
                    onChanged: (v) {
                      if (v != null) setLocal(() => childId = v);
                    },
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<int>(
                    value: hours,
                    decoration: const InputDecoration(
                      labelText: 'Geçmişi de yükle',
                      border: OutlineInputBorder(),
                    ),
                    items: const [
                      DropdownMenuItem(value: 0, child: Text('Sadece bundan sonra')),
                      DropdownMenuItem(value: 1, child: Text('Son 1 saat + canlı')),
                      DropdownMenuItem(value: 2, child: Text('Son 2 saat + canlı')),
                      DropdownMenuItem(value: 6, child: Text('Son 6 saat + canlı')),
                      DropdownMenuItem(value: 24, child: Text('Son 24 saat + canlı')),
                    ],
                    onChanged: (v) {
                      if (v != null) setLocal(() => hours = v);
                    },
                  ),
                  const SizedBox(height: 16),
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFE85D04),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    onPressed: () {
                      final name = children
                          .firstWhere((c) => c.uid == childId,
                              orElse: () => children.first)
                          .name;
                      Navigator.pop(ctx, (id: childId, name: name, hours: hours));
                    },
                    icon: const Icon(Icons.fiber_manual_record),
                    label: const Text('İz takibini başlat'),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
    if (selected == null || !mounted) return;
    await _startTrace(
      childId: selected.id,
      childName: selected.name,
      historyHours: selected.hours,
    );
  }

  Future<void> _startTrace({
    required String childId,
    required String childName,
    required int historyHours,
  }) async {
    final points = <LatLng>[];
    if (historyHours > 0) {
      try {
        final hist = await context
            .read<FirebaseService>()
            .getLocationHistory(childId, hours: historyHours);
        for (final h in hist) {
          if (h.latitude.abs() > 0.00001 || h.longitude.abs() > 0.00001) {
            points.add(LatLng(h.latitude, h.longitude));
          }
        }
      } catch (_) {}
    }

    final live = _lastChildLocations.where((l) => l.childId == childId);
    if (live.isNotEmpty) {
      final loc = live.first;
      if (loc.latitude.abs() > 0.00001 || loc.longitude.abs() > 0.00001) {
        final livePt = LatLng(loc.latitude, loc.longitude);
        if (points.isEmpty ||
            Geolocator.distanceBetween(
                  points.last.latitude,
                  points.last.longitude,
                  livePt.latitude,
                  livePt.longitude,
                ) >=
                _traceMinDistanceM) {
          points.add(livePt);
        }
      }
    }

    double dist = 0;
    for (var i = 1; i < points.length; i++) {
      dist += Geolocator.distanceBetween(
        points[i - 1].latitude,
        points[i - 1].longitude,
        points[i].latitude,
        points[i].longitude,
      );
    }

    setState(() {
      _traceActive = true;
      _traceChildId = childId;
      _traceChildName = childName;
      _selectedChildId = childId;
      _tracePoints
        ..clear()
        ..addAll(points);
      _traceDistanceM = dist;
      _traceStartedAt = DateTime.now();
      _routeDraftMode = false;
    });

    if (_tracePoints.length >= 2) {
      await _fitPoints(_tracePoints);
    } else if (_tracePoints.length == 1) {
      try {
        final c = await _mapController.future;
        await c.animateCamera(
            CameraUpdate.newLatLngZoom(_tracePoints.first, 16));
      } catch (_) {}
    }
    _showSnack(
      '“$childName” iz takibi açık — hareket ettikçe yol çizilecek.',
    );
  }

  void _ingestLiveLocationsForTrace(List<LocationData> locations) {
    if (!_traceActive || _traceChildId == null) return;
    LocationData? loc;
    for (final l in locations) {
      if (l.childId == _traceChildId) {
        loc = l;
        break;
      }
    }
    if (loc == null || !_hasRealLocation(loc)) return;
    final next = LatLng(loc.latitude, loc.longitude);
    if (_tracePoints.isNotEmpty) {
      final last = _tracePoints.last;
      final d = Geolocator.distanceBetween(
        last.latitude,
        last.longitude,
        next.latitude,
        next.longitude,
      );
      if (d < _traceMinDistanceM) return;
    }
    final childId = _traceChildId;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_traceActive || _traceChildId != childId) return;
      if (_tracePoints.isNotEmpty) {
        final last = _tracePoints.last;
        final d = Geolocator.distanceBetween(
          last.latitude,
          last.longitude,
          next.latitude,
          next.longitude,
        );
        if (d < _traceMinDistanceM) return;
        setState(() {
          _traceDistanceM += d;
          _tracePoints.add(next);
        });
      } else {
        setState(() => _tracePoints.add(next));
      }
    });
  }

  void _cancelTrace() {
    setState(() {
      _traceActive = false;
      _traceChildId = null;
      _traceChildName = null;
      _tracePoints.clear();
      _traceDistanceM = 0;
      _traceStartedAt = null;
    });
    _showSnack('İz takibi iptal edildi.');
  }

  Future<void> _finishTraceAndSave() async {
    if (_tracePoints.length < 2 || _traceChildId == null) {
      _showSnack('Kaydetmek için en az iki nokta lazım (çocuk biraz yürüsün).');
      return;
    }
    final childId = _traceChildId!;
    final childName = _traceChildName ?? 'Çocuk';
    final points = List<LatLng>.from(_tracePoints);
    await _savePointsAsRoute(
      childId: childId,
      childName: childName,
      points: points,
      defaultName:
          'İz $childName ${DateTime.now().day}.${DateTime.now().month} ${DateTime.now().hour}:${DateTime.now().minute.toString().padLeft(2, '0')}',
    );
    if (!mounted) return;
    setState(() {
      _traceActive = false;
      _traceChildId = null;
      _traceChildName = null;
      _tracePoints.clear();
      _traceDistanceM = 0;
      _traceStartedAt = null;
    });
  }

  Future<void> _savePointsAsRoute({
    required String childId,
    required String childName,
    required List<LatLng> points,
    required String defaultName,
  }) async {
    final result = await showDialog<_SaveTraceDialogResult>(
      context: context,
      builder: (ctx) => _SaveTraceDialog(
        childName: childName,
        pointCount: points.length,
        initialName: defaultName,
        deviationOptions: _deviationOptions,
      ),
    );
    if (result == null || !mounted) return;

    try {
      final id = await context.read<FirebaseService>().addRoute(TrackedRoute(
            id: '',
            name: result.name,
            childId: childId,
            mode: 'recorded',
            points: points
                .map((p) =>
                    RoutePoint(latitude: p.latitude, longitude: p.longitude))
                .toList(),
            deviationMeters: result.deviation,
            active: result.startTracking,
            recording: false,
          ));
      if (!mounted) return;
      setState(() => _focusedRouteId = id);
      _showSnack(
          '“${result.name}” kaydedildi. Rotalar listesinden istediğin an açabilirsin.');
    } catch (e) {
      _showSnack('Kaydedilemedi: $e');
    }
  }

  Future<void> _fitPoints(List<LatLng> points) async {
    if (points.isEmpty) return;
    try {
      final ctrl = await _mapController.future;
      if (points.length == 1) {
        await ctrl.animateCamera(CameraUpdate.newLatLngZoom(points.first, 16));
        return;
      }
      double minLat = points.first.latitude;
      double maxLat = points.first.latitude;
      double minLng = points.first.longitude;
      double maxLng = points.first.longitude;
      for (final p in points) {
        if (p.latitude < minLat) minLat = p.latitude;
        if (p.latitude > maxLat) maxLat = p.latitude;
        if (p.longitude < minLng) minLng = p.longitude;
        if (p.longitude > maxLng) maxLng = p.longitude;
      }
      await ctrl.animateCamera(CameraUpdate.newLatLngBounds(
        LatLngBounds(
          southwest: LatLng(minLat - 0.002, minLng - 0.002),
          northeast: LatLng(maxLat + 0.002, maxLng + 0.002),
        ),
        60,
      ));
    } catch (_) {}
  }

  String _formatTraceDistance() {
    if (_traceDistanceM < 1000) {
      return '${_traceDistanceM.toStringAsFixed(0)} m';
    }
    return '${(_traceDistanceM / 1000).toStringAsFixed(2)} km';
  }

  Widget _buildTraceBanner() {
    final elapsed = _traceStartedAt == null
        ? '00:00'
        : () {
            final s = DateTime.now().difference(_traceStartedAt!).inSeconds;
            final mm = (s ~/ 60).toString().padLeft(2, '0');
            final ss = (s % 60).toString().padLeft(2, '0');
            return '$mm:$ss';
          }();
    return Material(
      elevation: 3,
      borderRadius: BorderRadius.circular(12),
      color: const Color(0xFFFFF3E8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            const Icon(Icons.directions_walk, color: Color(0xFFE85D04)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'İz: ${_traceChildName ?? 'Çocuk'} • '
                '${_tracePoints.length} nokta • ${_formatTraceDistance()} • $elapsed',
                style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTraceActions() {
    return Material(
      elevation: 6,
      borderRadius: BorderRadius.circular(14),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: _cancelTrace,
                child: const Text('İptal'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              flex: 2,
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFE85D04),
                  foregroundColor: Colors.white,
                ),
                onPressed: _finishTraceAndSave,
                icon: const Icon(Icons.save),
                label: const Text('Bitir ve kaydet'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _centerOnChildren() async {
    final ctrl = await _mapController.future;

    // Çocuk konumu yoksa ebeveynin kendi konumuna git.
    if (_lastChildLocations.isEmpty) {
      await _centerOnMyLocation(ctrl);
      return;
    }

    if (_lastChildLocations.length == 1) {
      ctrl.animateCamera(CameraUpdate.newLatLngZoom(
        LatLng(_lastChildLocations[0].latitude, _lastChildLocations[0].longitude),
        15,
      ));
    } else {
      double minLat = _lastChildLocations[0].latitude;
      double maxLat = _lastChildLocations[0].latitude;
      double minLng = _lastChildLocations[0].longitude;
      double maxLng = _lastChildLocations[0].longitude;

      for (final loc in _lastChildLocations) {
        if (loc.latitude < minLat) minLat = loc.latitude;
        if (loc.latitude > maxLat) maxLat = loc.latitude;
        if (loc.longitude < minLng) minLng = loc.longitude;
        if (loc.longitude > maxLng) maxLng = loc.longitude;
      }

      ctrl.animateCamera(CameraUpdate.newLatLngBounds(
        LatLngBounds(
          southwest: LatLng(minLat - 0.01, minLng - 0.01),
          northeast: LatLng(maxLat + 0.01, maxLng + 0.01),
        ),
        60,
      ));
    }
  }

  Future<void> _centerOnMyLocation(GoogleMapController ctrl) async {
    try {
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        _showSnack('Konum servisi kapalı. Lütfen açın.');
        return;
      }

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        _showSnack('Konum izni verilmedi.');
        return;
      }

      final pos = await Geolocator.getCurrentPosition(
        locationSettings:
            const LocationSettings(accuracy: LocationAccuracy.high),
      );
      final coordinate = LatLng(pos.latitude, pos.longitude);
      setState(() {
        _parentMarker = Marker(
          markerId: const MarkerId('parent-current-location'),
          position: coordinate,
          icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure),
          infoWindow: const InfoWindow(title: 'Benim konumum'),
        );
        _selectedChildId = null;
        _selectedCoordinate = coordinate;
        _selectedCoordinateTitle = 'Benim konumum';
      });
      await ctrl.animateCamera(
        CameraUpdate.newLatLngZoom(coordinate, 16),
      );
      _showSnack('Henüz paylaşılan çocuk konumu yok, kendi konumun gösteriliyor.');
    } catch (e) {
      _showSnack('Konum alınamadı: $e');
    }
  }

  void _selectCoordinate({
    required String title,
    required LatLng coordinate,
    String? childId,
  }) {
    setState(() {
      _selectedChildId = childId;
      _selectedCoordinate = coordinate;
      _selectedCoordinateTitle = title;
      if (childId == null) _lastFollowedChildPos = null;
    });
  }

  /// Seçili çocuğun yeni konumu gelince haritayı/kartı senkron tut.
  void _scheduleFollowSelectedChild(
    List<LocationData> locations,
    Map<String, String> childNames,
  ) {
    final id = _selectedChildId;
    if (id == null || _routeDraftMode || _traceActive) return;
    LocationData? loc;
    for (final l in locations) {
      if (l.childId == id) {
        loc = l;
        break;
      }
    }
    if (loc == null || !_hasRealLocation(loc)) return;
    final pos = LatLng(loc.latitude, loc.longitude);
    final prev = _lastFollowedChildPos;
    final movedM = prev == null
        ? 999.0
        : Geolocator.distanceBetween(
            prev.latitude, prev.longitude, pos.latitude, pos.longitude);

    final needCardUpdate = _selectedCoordinate == null ||
        (_selectedCoordinate!.latitude - pos.latitude).abs() > 0.00001 ||
        (_selectedCoordinate!.longitude - pos.longitude).abs() > 0.00001;

    if (!needCardUpdate && movedM < 5) return;

    final name = childNames[id] ?? _shortId(id);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || _selectedChildId != id) return;
      _lastFollowedChildPos = pos;
      if (needCardUpdate) {
        setState(() {
          _selectedCoordinate = pos;
          _selectedCoordinateTitle = name;
        });
      }
      if (movedM >= 8) {
        try {
          final ctrl = await _mapController.future;
          await ctrl.animateCamera(CameraUpdate.newLatLng(pos));
        } catch (_) {}
      }
    });
  }

  bool _isChildOnline(LocationData? loc) {
    if (loc == null) return false;
    if (!loc.isOnline) return false;
    // 90 sn'den eski heartbeat = çevrimdışı
    final age = DateTime.now().difference(loc.timestamp);
    return age.inSeconds < 90;
  }

  Widget _buildCoordinateCard() {
    final coordinate = _selectedCoordinate!;
    final text =
        '${coordinate.latitude.toStringAsFixed(5)}, ${coordinate.longitude.toStringAsFixed(5)}';

    Widget iconBtn({
      required String tooltip,
      required IconData icon,
      required Color color,
      required VoidCallback onPressed,
    }) {
      return IconButton(
        tooltip: tooltip,
        icon: Icon(icon, size: 18, color: color),
        visualDensity: VisualDensity.compact,
        constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
        padding: EdgeInsets.zero,
        onPressed: onPressed,
      );
    }

    return Material(
      elevation: 3,
      borderRadius: BorderRadius.circular(10),
      color: Colors.white,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 4, 4, 4),
        child: Row(
          children: [
            const Icon(Icons.place, size: 16, color: Color(0xFF2D6A4F)),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                '${_selectedCoordinateTitle ?? 'Konum'} · $text',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            iconBtn(
              tooltip: 'Koordinatı kopyala',
              icon: Icons.copy,
              color: Colors.black54,
              onPressed: () {
                Clipboard.setData(ClipboardData(text: text));
                _showSnack('Koordinat kopyalandı.');
              },
            ),
            iconBtn(
              tooltip: 'Konuma git',
              icon: Icons.directions,
              color: const Color(0xFF1D4ED8),
              onPressed: () async {
                final ok = await MapLaunch.openDirections(
                  coordinate.latitude,
                  coordinate.longitude,
                  label: _selectedCoordinateTitle,
                );
                if (!ok && mounted) {
                  _showSnack('Harita uygulaması açılamadı.');
                }
              },
            ),
            iconBtn(
              tooltip: 'Güvenli bölge ekle',
              icon: Icons.add_location_alt,
              color: const Color(0xFF2D6A4F),
              onPressed: () {
                context.read<ParentNav>().openGeofenceComposerAt(
                      latitude: coordinate.latitude,
                      longitude: coordinate.longitude,
                    );
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openGeofenceAtSelection() async {
    LatLng? target = _selectedCoordinate;
    if (target == null) {
      try {
        final ctrl = await _mapController.future;
        final bounds = await ctrl.getVisibleRegion();
        target = LatLng(
          (bounds.northeast.latitude + bounds.southwest.latitude) / 2,
          (bounds.northeast.longitude + bounds.southwest.longitude) / 2,
        );
      } catch (_) {
        target = const LatLng(41.0082, 28.9784);
      }
    }
    if (!mounted) return;
    context.read<ParentNav>().openGeofenceComposerAt(
          latitude: target.latitude,
          longitude: target.longitude,
        );
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Widget _buildChildCards({
    required List<ChildSummary> children,
    required List<LocationData> locations,
    required Map<String, LocationData> locationByChild,
    required Map<String, String> childNames,
  }) {
    final ids = <String>[
      ...children.map((c) => c.uid),
      ...locations
          .map((l) => l.childId)
          .where((id) => !children.any((c) => c.uid == id)),
    ];

    return SizedBox(
      height: 44,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: ids.length,
        itemBuilder: (context, i) {
          final childId = ids[i];
          final loc = locationByChild[childId];
          final hasLocation = loc != null && _hasRealLocation(loc);
          final online = _isChildOnline(loc);
          final isSelected = _selectedChildId == childId;
          final nameColor = isSelected ? Colors.white : Colors.black87;
          final subColor = isSelected ? Colors.white70 : Colors.black45;
          final name = childNames[childId] ?? _shortId(childId);
          return GestureDetector(
            onTap: !hasLocation
                ? null
                : () async {
                    _lastFollowedChildPos =
                        LatLng(loc.latitude, loc.longitude);
                    _selectCoordinate(
                      title: name,
                      coordinate: LatLng(loc.latitude, loc.longitude),
                      childId: loc.childId,
                    );
                    final ctrl = await _mapController.future;
                    ctrl.animateCamera(CameraUpdate.newLatLngZoom(
                      LatLng(loc.latitude, loc.longitude),
                      16,
                    ));
                  },
            child: Container(
              constraints: const BoxConstraints(minWidth: 96, maxWidth: 132),
              margin: const EdgeInsets.only(right: 6),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              decoration: BoxDecoration(
                color: isSelected ? const Color(0xFF2D6A4F) : Colors.white,
                borderRadius: BorderRadius.circular(22),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.12),
                    blurRadius: 4,
                    offset: const Offset(0, 1),
                  ),
                ],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Icon(
                        Icons.person,
                        size: 18,
                        color: isSelected
                            ? Colors.white
                            : const Color(0xFF2D6A4F),
                      ),
                      Positioned(
                        right: -2,
                        bottom: -1,
                        child: Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: online
                                ? const Color(0xFF22C55E)
                                : Colors.grey.shade400,
                            border: Border.all(
                              color: isSelected
                                  ? const Color(0xFF2D6A4F)
                                  : Colors.white,
                              width: 1.2,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: nameColor,
                      ),
                    ),
                  ),
                  if (hasLocation) ...[
                    const SizedBox(width: 4),
                    Icon(Icons.battery_std, size: 12, color: subColor),
                    Text(
                      '${loc.batteryLevel}',
                      style: TextStyle(fontSize: 10, color: subColor),
                    ),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  String _formatTime(DateTime dt) {
    return DateFormat('HH:mm').format(dt);
  }

  String _formatSpeedKmh(double? speedMps, {double? speedKmh}) {
    if (speedKmh != null && speedKmh.isFinite && speedKmh >= 0) {
      if (speedKmh < 0.8) return '0 km/sa';
      return '${speedKmh.toStringAsFixed(0)} km/sa';
    }
    if (speedMps == null || !speedMps.isFinite || speedMps < 0) return '—';
    final kmh = speedMps * 3.6;
    if (kmh < 0.8) return '0 km/sa';
    return '${kmh.toStringAsFixed(0)} km/sa';
  }

  String _shortId(String id) => id.length <= 6 ? id : id.substring(0, 6);
}

class _SaveRouteDialogResult {
  final String name;
  final String childId;
  final double deviation;
  final bool startTracking;

  const _SaveRouteDialogResult({
    required this.name,
    required this.childId,
    required this.deviation,
    required this.startTracking,
  });
}

class _SaveRouteDialog extends StatefulWidget {
  final List<ChildSummary> children;
  final String initialName;
  final double initialDeviation;
  final bool initialStartTracking;
  final String drawMode;
  final int pointCount;
  final List<double> deviationOptions;

  const _SaveRouteDialog({
    required this.children,
    required this.initialName,
    required this.initialDeviation,
    required this.initialStartTracking,
    required this.drawMode,
    required this.pointCount,
    required this.deviationOptions,
  });

  @override
  State<_SaveRouteDialog> createState() => _SaveRouteDialogState();
}

class _SaveRouteDialogState extends State<_SaveRouteDialog> {
  late final TextEditingController _nameCtrl;
  late String _childId;
  late double _deviation;
  late bool _startTracking;

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: widget.initialName);
    _childId = widget.children.first.uid;
    _deviation = widget.initialDeviation;
    _startTracking = widget.initialStartTracking;
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    final name =
        _nameCtrl.text.trim().isEmpty ? 'Rota' : _nameCtrl.text.trim();
    Navigator.pop(
      context,
      _SaveRouteDialogResult(
        name: name,
        childId: _childId,
        deviation: _deviation,
        startTracking: _startTracking,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final modeLabel = widget.drawMode == 'auto'
        ? 'Otomatik yol'
        : (widget.drawMode == 'pen' ? 'Kalem çizimi' : 'Nokta nokta');
    return AlertDialog(
      title: const Text('Rotayı kaydet'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _nameCtrl,
              decoration: const InputDecoration(
                labelText: 'Rota adı',
                border: OutlineInputBorder(),
                helperText: 'İstediğin zaman listeden açıp görebilirsin',
              ),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              value: _childId,
              decoration: const InputDecoration(
                labelText: 'Çocuk',
                border: OutlineInputBorder(),
              ),
              items: widget.children
                  .map((c) =>
                      DropdownMenuItem(value: c.uid, child: Text(c.name)))
                  .toList(),
              onChanged: (v) {
                if (v != null) setState(() => _childId = v);
              },
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<double>(
              value: _deviation,
              decoration: const InputDecoration(
                labelText: 'Sapma eşiği (bildirim)',
                border: OutlineInputBorder(),
                helperText: 'Çocuk bu mesafeden fazla çıkınca bildirim',
              ),
              items: widget.deviationOptions
                  .map((m) => DropdownMenuItem(
                        value: m,
                        child: Text('${m.toInt()} metre'),
                      ))
                  .toList(),
              onChanged: (v) {
                if (v != null) setState(() => _deviation = v);
              },
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Rota takip aktif'),
              subtitle: const Text(
                'Açıksa çocuk rotayı izler; sapınca bildirim gelir. '
                'Çocuk iptal edene veya sen kapatana kadar haritada kalır.',
              ),
              value: _startTracking,
              onChanged: (v) => setState(() => _startTracking = v),
            ),
            Text(
              'Mod: $modeLabel • ${widget.pointCount} nokta',
              style: const TextStyle(fontSize: 12, color: Colors.black54),
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

class _SaveTraceDialogResult {
  final String name;
  final double deviation;
  final bool startTracking;

  const _SaveTraceDialogResult({
    required this.name,
    required this.deviation,
    required this.startTracking,
  });
}

class _SaveTraceDialog extends StatefulWidget {
  final String childName;
  final int pointCount;
  final String initialName;
  final List<double> deviationOptions;

  const _SaveTraceDialog({
    required this.childName,
    required this.pointCount,
    required this.initialName,
    required this.deviationOptions,
  });

  @override
  State<_SaveTraceDialog> createState() => _SaveTraceDialogState();
}

class _SaveTraceDialogState extends State<_SaveTraceDialog> {
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
        ? widget.initialName
        : _nameCtrl.text.trim();
    Navigator.pop(
      context,
      _SaveTraceDialogResult(
        name: name,
        deviation: _deviation,
        startTracking: _startTracking,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Yolu kaydet'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '${widget.pointCount} nokta • ${widget.childName}',
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
              subtitle: const Text('Sonraki sapmalarda bildirim'),
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
                items: widget.deviationOptions
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
        ElevatedButton(
          onPressed: _submit,
          child: const Text('Kaydet'),
        ),
      ],
    );
  }
}

