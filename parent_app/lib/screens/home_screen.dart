import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:provider/provider.dart';
import '../models/models.dart';
import '../services/firebase_service.dart';
import '../services/parent_nav.dart';
import '../services/notification_service.dart';
import '../services/geofence_service.dart';
import '../services/alert_background_service.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../utils/chat_helpers.dart';
import '../l10n/app_locale.dart';
import 'map_screen.dart';
import 'sos_screen.dart';
import 'messages_screen.dart';
import 'screen_stats_screen.dart';
import 'geofence_screen.dart';
import 'settings_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  StreamSubscription<List<GeofenceEvent>>? _geoSub;
  StreamSubscription<List<RouteEvent>>? _routeSub;
  StreamSubscription<List<SosEvent>>? _sosSub;
  StreamSubscription<List<ChildSummary>>? _childrenSub;
  StreamSubscription<List<Geofence>>? _fenceListSub;
  StreamSubscription<List<LocationData>>? _locGeoSub;
  final List<StreamSubscription<List<ChatMessage>>> _chatSubs = [];
  StreamSubscription<RemoteMessage>? _fcmSub;
  StreamSubscription<RemoteMessage>? _fcmOpenedSub;
  bool _sosSeeded = false;
  final Set<String> _sosSeen = {};
  final Set<String> _chatSeededChildren = {};
  final Set<String> _chatSeen = {};
  List<Geofence> _fences = [];
  final Map<String, LocationData> _prevLocForGeo = {};
  final Map<String, String> _childNameById = {};
  bool _locGeoSeeded = false;

  final List<Widget> _screens = const [
    MapScreen(),
    SosScreen(),
    MessagesScreen(),
    ScreenStatsScreen(),
    GeofenceScreen(),
    SettingsScreen(),
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final svc = context.read<FirebaseService>();
      final nav = context.read<ParentNav>();
      try {
        await svc.ensureParentProfile();
      } catch (_) {}
      if (!mounted) return;

      await ParentNotificationService.instance.init();
      ParentNotificationService.onPayload = (payload) {
        if (!mounted) return;
        context.read<ParentNav>().openFromNotificationPayload(payload);
      };

      final pending = ParentNotificationService.instance.takePendingPayload();
      if (pending != null) {
        nav.openFromNotificationPayload(pending);
      }

      await svc.initNotifications();
      await _bindAlertStreams();
      await initParentAlertBackgroundService();
      await startParentAlertBackgroundService();

      _fcmSub = FirebaseMessaging.onMessage.listen((msg) async {
        await ParentNotificationService.instance.showFromRemote(msg);
      });
      _fcmOpenedSub =
          FirebaseMessaging.onMessageOpenedApp.listen((msg) {
        final payload = msg.data['payload']?.toString() ??
            msg.data['type']?.toString() ??
            'sos';
        if (!mounted) return;
        context.read<ParentNav>().openFromNotificationPayload(payload);
      });

      final initial = await FirebaseMessaging.instance.getInitialMessage();
      if (initial != null && mounted) {
        final payload = initial.data['payload']?.toString() ??
            initial.data['type']?.toString() ??
            'sos';
        context.read<ParentNav>().openFromNotificationPayload(payload);
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      final pending = ParentNotificationService.instance.takePendingPayload();
      if (pending != null && mounted) {
        context.read<ParentNav>().openFromNotificationPayload(pending);
      }
    }
  }

  Future<void> _bindAlertStreams() async {
    final svc = context.read<FirebaseService>();
    final notif = ParentNotificationService.instance;

    await _geoSub?.cancel();
    _geoSub = svc.watchUnnotifiedGeofenceEvents().listen((events) async {
      for (final e in events) {
        final key = 'geo_${e.id}';
        if (await notif.wasShown(key)) {
          await svc.markGeofenceEventNotified(e.id);
          continue;
        }
        await notif.showGeofence(
          eventId: e.id,
          childName: e.childName,
          fenceName: e.fenceName,
          eventType: e.eventType,
        );
        await notif.markShown(key);
        await svc.markGeofenceEventNotified(e.id);
      }
    });

    // Ebeveyn tarafında konum → geofence (çocuk yazmasa da bildirim)
    await _fenceListSub?.cancel();
    _fenceListSub = svc.watchGeofences().listen((f) {
      _fences = f;
    });
    await _locGeoSub?.cancel();
    _locGeoSeeded = false;
    _prevLocForGeo.clear();
    _locGeoSub = svc.watchChildLocations().listen((locations) async {
      final fid = svc.familyId;
      if (fid == null || _fences.isEmpty) return;

      if (!_locGeoSeeded) {
        for (final loc in locations) {
          if (loc.latitude.abs() < 0.00001 && loc.longitude.abs() < 0.00001) {
            continue;
          }
          _prevLocForGeo[loc.childId] = loc;
        }
        _locGeoSeeded = true;
        return;
      }

      for (final loc in locations) {
        if (loc.latitude.abs() < 0.00001 && loc.longitude.abs() < 0.00001) {
          continue;
        }
        final prev = _prevLocForGeo[loc.childId];
        if (prev == null) {
          _prevLocForGeo[loc.childId] = loc;
          continue;
        }
        final name = _childNameById[loc.childId] ?? 'Çocuk';
        try {
          await GeofenceService.checkGeofences(
            geofences: _fences,
            newLocation: loc,
            previousLocation: prev,
            childName: name,
            familyId: fid,
            db: FirebaseFirestore.instance,
          );
        } catch (_) {}
        _prevLocForGeo[loc.childId] = loc;
      }
    });

    await _routeSub?.cancel();
    _routeSub = svc.watchUnnotifiedRouteEvents().listen((events) async {
      for (final e in events) {
        final key = 'route_${e.id}';
        if (await notif.wasShown(key)) {
          await svc.markRouteEventNotified(e.id);
          continue;
        }
        await notif.showRoute(
          eventId: e.id,
          childName: e.childName,
          routeName: e.routeName,
          eventType: e.eventType,
          meters: e.distanceMeters,
          thresholdMeters: e.thresholdMeters,
        );
        await notif.markShown(key);
        await svc.markRouteEventNotified(e.id);
      }
    });

    await _sosSub?.cancel();
    _sosSub = svc.watchSosEvents().listen((events) async {
      final active = events.where((e) => !e.acknowledged).toList();
      if (!_sosSeeded) {
        for (final e in active) {
          _sosSeen.add(e.id);
        }
        _sosSeeded = true;
        return;
      }
      for (final e in active) {
        if (_sosSeen.contains(e.id)) continue;
        _sosSeen.add(e.id);
        final key = 'sos_${e.id}';
        if (await notif.wasShown(key)) continue;
        await notif.showSos(eventId: e.id, childName: e.childName);
        await notif.markShown(key);
      }
    });

    await _childrenSub?.cancel();
    for (final s in _chatSubs) {
      await s.cancel();
    }
    _chatSubs.clear();
    _childrenSub = svc.watchChildren().listen((children) {
      for (final c in children) {
        _childNameById[c.uid] = c.name;
      }
      _rebindChatSubs(svc, notif, children);
    });
  }

  void _rebindChatSubs(
    FirebaseService svc,
    ParentNotificationService notif,
    List<ChildSummary> children,
  ) {
    for (final s in _chatSubs) {
      s.cancel();
    }
    _chatSubs.clear();
    for (final child in children) {
      final sub = svc.watchUnreadChatFromChild(child.uid).listen((msgs) async {
        if (!_chatSeededChildren.contains(child.uid)) {
          for (final m in msgs) {
            _chatSeen.add(m.id);
          }
          _chatSeededChildren.add(child.uid);
          return;
        }
        for (final m in msgs) {
          if (_chatSeen.contains(m.id)) continue;
          _chatSeen.add(m.id);
          final key = 'chat_${m.id}';
          if (await notif.wasShown(key)) continue;
          await notif.showChat(
            messageId: m.id,
            childName: child.name,
            preview: chatPreviewText(m.type, m.text, routeName: m.routeName),
            childId: child.uid,
          );
          await notif.markShown(key);
        }
      });
      _chatSubs.add(sub);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    ParentNotificationService.onPayload = null;
    _geoSub?.cancel();
    _routeSub?.cancel();
    _sosSub?.cancel();
    _childrenSub?.cancel();
    _fenceListSub?.cancel();
    _locGeoSub?.cancel();
    for (final s in _chatSubs) {
      s.cancel();
    }
    _fcmSub?.cancel();
    _fcmOpenedSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final nav = context.watch<ParentNav>();
    final l10n = context.watch<AppLocale>();

    return Scaffold(
      body: IndexedStack(
        index: nav.tabIndex,
        children: _screens,
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: nav.tabIndex,
        onDestinationSelected: nav.selectTab,
        // 6 sekme + uzun TR etiketleri taşmayı / tıklama bozulmasını önler
        labelBehavior: NavigationDestinationLabelBehavior.onlyShowSelected,
        destinations: [
          NavigationDestination(
            icon: const Icon(Icons.map_outlined),
            selectedIcon: const Icon(Icons.map),
            label: l10n.t('nav_map'),
          ),
          NavigationDestination(
            icon: const Icon(Icons.emergency_outlined),
            selectedIcon: const Icon(Icons.emergency),
            label: l10n.t('nav_sos'),
          ),
          NavigationDestination(
            icon: const Icon(Icons.chat_bubble_outline),
            selectedIcon: const Icon(Icons.chat_bubble),
            label: l10n.t('nav_messages'),
          ),
          NavigationDestination(
            icon: const Icon(Icons.phone_android_outlined),
            selectedIcon: const Icon(Icons.phone_android),
            label: l10n.t('nav_screen'),
          ),
          NavigationDestination(
            icon: const Icon(Icons.place_outlined),
            selectedIcon: const Icon(Icons.place),
            label: l10n.t('nav_geofence'),
          ),
          NavigationDestination(
            icon: const Icon(Icons.settings_outlined),
            selectedIcon: const Icon(Icons.settings),
            label: l10n.t('nav_settings'),
          ),
        ],
      ),
    );
  }
}
