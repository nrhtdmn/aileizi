import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/services.dart';
import 'package:usage_stats/usage_stats.dart';

class ScreenStatsService {
  static final _db = FirebaseFirestore.instance;
  static final _auth = FirebaseAuth.instance;
  static const _appsChannel = MethodChannel('com.senin.child/apps');

  /// Bilinen paket → görünen ad (cihazda etiket bulunamazsa)
  static const _knownNames = <String, String>{
    'com.android.chrome': 'Chrome',
    'com.google.android.youtube': 'YouTube',
    'com.google.android.apps.maps': 'Haritalar',
    'com.google.android.gm': 'Gmail',
    'com.google.android.apps.messaging': 'Mesajlar',
    'com.google.android.apps.photos': 'Fotoğraflar',
    'com.google.android.googlequicksearchbox': 'Google',
    'com.google.android.apps.docs': 'Drive',
    'com.instagram.android': 'Instagram',
    'com.whatsapp': 'WhatsApp',
    'com.facebook.katana': 'Facebook',
    'com.facebook.orca': 'Messenger',
    'com.twitter.android': 'X (Twitter)',
    'com.zhiliaoapp.musically': 'TikTok',
    'com.ss.android.ugc.trill': 'TikTok',
    'com.snapchat.android': 'Snapchat',
    'com.spotify.music': 'Spotify',
    'com.netflix.mediaclient': 'Netflix',
    'com.discord': 'Discord',
    'org.telegram.messenger': 'Telegram',
    'org.mozilla.firefox': 'Firefox',
    'com.android.vending': 'Play Store',
    'com.samsung.android.app.contacts': 'Kişiler',
    'com.samsung.android.messaging': 'Mesajlar',
    'com.android.settings': 'Ayarlar',
    'com.android.systemui': 'Sistem',
    'com.google.android.permissioncontroller': 'İzinler',
  };

  static int _foregroundMs(dynamic v) {
    if (v == null) return 0;
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v.toString()) ?? 0;
  }

  static Future<Map<String, String>> _resolveAppLabels(
      Iterable<String> packages) async {
    final unique = packages.where((p) => p.isNotEmpty).toSet().toList();
    final out = <String, String>{
      for (final p in unique) p: _fallbackName(p),
    };
    if (unique.isEmpty) return out;
    try {
      final raw = await _appsChannel.invokeMethod<Map>('getAppLabels', unique);
      if (raw != null) {
        raw.forEach((key, value) {
          final pkg = key.toString();
          final label = value?.toString().trim() ?? '';
          if (label.isNotEmpty) out[pkg] = label;
        });
      }
    } catch (_) {
      // Platform kanalı yoksa bilinen isimler / fallback
    }
    return out;
  }

  static String _fallbackName(String packageName) {
    final known = _knownNames[packageName];
    if (known != null) return known;
    final last = packageName.split('.').last;
    if (last.isEmpty) return packageName;
    return last[0].toUpperCase() + last.substring(1);
  }

  /// Bugünün ekran istatistiklerini Firebase'e yükle (sadece Android).
  /// true = yüklendi, false = izin yok / veri yok / hata.
  static Future<bool> uploadDailyStats() async {
    final user = _auth.currentUser;
    if (user == null) return false;

    final granted = await UsageStats.checkUsagePermission();
    if (granted != true) return false;

    final now = DateTime.now();
    final startOfDay = DateTime(now.year, now.month, now.day);
    final stats = await UsageStats.queryUsageStats(startOfDay, now);

    // 30 sn ve üzeri kullanımları al
    final filteredStats = stats.where((s) {
      final ms = _foregroundMs(s.totalTimeInForeground);
      return ms >= 30000;
    }).toList();

    final userDoc = await _db.collection('users').doc(user.uid).get();
    final familyId = userDoc.data()?['familyId'] as String?;
    if (familyId == null) return false;

    final dateStr =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';

    final packages = filteredStats
        .map((s) => s.packageName ?? 'bilinmeyen')
        .toList();
    final labels = await _resolveAppLabels(packages);

    final appsData = filteredStats.map((s) {
      final minutes = (_foregroundMs(s.totalTimeInForeground) / 60000)
          .ceil()
          .clamp(1, 24 * 60)
          .toInt();
      final pkg = s.packageName ?? 'bilinmeyen';
      return {
        'packageName': pkg,
        'appName': labels[pkg] ?? _fallbackName(pkg),
        'totalTimeMinutes': minutes,
      };
    }).toList()
      ..sort((a, b) =>
          (b['totalTimeMinutes'] as int).compareTo(a['totalTimeMinutes'] as int));

    await _db
        .collection('families')
        .doc(familyId)
        .collection('screen_stats')
        .doc(user.uid)
        .collection('daily')
        .doc(dateStr)
        .set({
      'apps': appsData,
      'uploadedAt': FieldValue.serverTimestamp(),
      'totalMinutes': appsData.fold<int>(
          0, (total, a) => total + (a['totalTimeMinutes'] as int)),
    });
    return true;
  }

  static Future<bool> requestPermissionCheckOnly() async {
    final granted = await UsageStats.checkUsagePermission();
    return granted == true;
  }

  /// Kullanıcıya izin isteği göster (ayarlara yönlendirir)
  static Future<bool> requestPermission() async {
    final granted = await UsageStats.checkUsagePermission();
    if (granted != true) {
      await UsageStats.grantUsagePermission();
      return false;
    }
    return true;
  }
}
