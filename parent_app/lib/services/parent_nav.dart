import 'package:flutter/foundation.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

/// Alt sekmeler ve harita/bölge odak koordinatları arasında köprü.
class ParentNav extends ChangeNotifier {
  int tabIndex = 0;

  LatLng? mapTarget;
  String? mapTitle;
  MarkerId? mapMarkerId;

  LatLng? geofenceTarget;
  bool openGeofenceDialog = false;

  /// Bildirimden açılacak sohbet
  String? pendingChatChildId;
  String? pendingChatChildName;

  void selectTab(int index) {
    if (tabIndex == index) return;
    tabIndex = index;
    notifyListeners();
  }

  /// Bildirim tıklaması: sos | route | geofence | chat | chat:{childId}
  void openFromNotificationPayload(String? payload) {
    if (payload == null || payload.isEmpty) return;
    if (payload.startsWith('chat:')) {
      openChat(childId: payload.substring(5));
      return;
    }
    switch (payload) {
      case 'sos':
        selectTab(1);
        break;
      case 'route':
        selectTab(0);
        break;
      case 'chat':
        selectTab(2);
        break;
      case 'geofence':
        selectTab(4);
        break;
      default:
        if (payload.startsWith('tab:')) {
          final i = int.tryParse(payload.substring(4));
          if (i != null) selectTab(i);
        }
        break;
    }
  }

  void openChat({required String childId, String? childName}) {
    pendingChatChildId = childId;
    pendingChatChildName = childName;
    tabIndex = 2;
    notifyListeners();
  }

  ({String childId, String? childName})? takePendingChat() {
    final id = pendingChatChildId;
    if (id == null || id.isEmpty) return null;
    final name = pendingChatChildName;
    pendingChatChildId = null;
    pendingChatChildName = null;
    return (childId: id, childName: name);
  }

  void openMapAt({
    required double latitude,
    required double longitude,
    String? title,
  }) {
    mapTarget = LatLng(latitude, longitude);
    mapTitle = title;
    mapMarkerId = const MarkerId('sos-focus');
    tabIndex = 0;
    notifyListeners();
  }

  void consumeMapTarget() {
    mapTarget = null;
    mapTitle = null;
  }

  void openGeofenceComposerAt({
    required double latitude,
    required double longitude,
    bool openDialog = true,
  }) {
    geofenceTarget = LatLng(latitude, longitude);
    openGeofenceDialog = openDialog;
    tabIndex = 4;
    notifyListeners();
  }

  void consumeGeofenceTarget() {
    geofenceTarget = null;
    openGeofenceDialog = false;
  }
}
