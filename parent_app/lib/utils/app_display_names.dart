/// Paket adından okunabilir uygulama adı üretir (eski kayıtlar için).
class AppDisplayNames {
  static const _known = <String, String>{
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
  };

  static String resolve({
    required String packageName,
    String? appName,
  }) {
    final stored = (appName ?? '').trim();
    final pkg = packageName.trim();

    // Gerçek uygulama adı gibi duruyorsa (paket / son segment değil)
    if (stored.isNotEmpty && !_looksLikePackageFragment(stored, pkg)) {
      return stored;
    }

    final known = _known[pkg];
    if (known != null) return known;

    if (stored.isNotEmpty) {
      return _titleCase(stored);
    }
    if (pkg.isEmpty) return 'Uygulama';
    return _titleCase(pkg.split('.').last);
  }

  static bool _looksLikePackageFragment(String name, String packageName) {
    final lower = name.toLowerCase();
    if (lower.contains('.')) return true;
    if (packageName.isEmpty) return false;
    final last = packageName.split('.').last.toLowerCase();
    return lower == last || lower == packageName.toLowerCase();
  }

  static String _titleCase(String s) {
    if (s.isEmpty) return s;
    return s[0].toUpperCase() + s.substring(1);
  }
}
