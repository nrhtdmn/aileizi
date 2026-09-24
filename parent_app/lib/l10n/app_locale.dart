import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Basit TR/EN metin katmanı (ilk ekrandan seçilir).
class AppLocale extends ChangeNotifier {
  static const _prefKey = 'app_locale_code';

  Locale _locale = const Locale('tr');
  Locale get locale => _locale;
  bool get isTr => _locale.languageCode == 'tr';

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final code = prefs.getString(_prefKey) ?? 'tr';
    _locale = Locale(code == 'en' ? 'en' : 'tr');
  }

  Future<void> setLanguageCode(String code) async {
    final next = code == 'en' ? 'en' : 'tr';
    if (_locale.languageCode == next) return;
    _locale = Locale(next);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefKey, next);
    notifyListeners();
  }

  String t(String key) {
    final table = _tables[_locale.languageCode] ?? _tables['tr']!;
    return table[key] ?? _tables['tr']![key] ?? key;
  }

  /// Firebase / Google hatalarını okunabilir metne çevir.
  String authError(Object e) {
    if (e is Exception || e is Error) {
      // firebase_auth
      final code = _firebaseCode(e);
      switch (code) {
        case 'email-already-in-use':
          return t('err_email_in_use');
        case 'invalid-email':
          return t('err_invalid_email');
        case 'weak-password':
          return t('err_weak_password');
        case 'wrong-password':
        case 'invalid-credential':
        case 'INVALID_LOGIN_CREDENTIALS':
          return t('err_wrong_password');
        case 'user-not-found':
          return t('err_user_not_found');
        case 'user-disabled':
          return t('err_user_disabled');
        case 'too-many-requests':
          return t('err_too_many');
        case 'network-request-failed':
          return t('err_network');
        case 'requires-recent-login':
          return t('err_recent_login');
      }
    }
    final s = e.toString();
    if (s.contains('PigeonUserDetails') || s.contains("List<Object?>")) {
      return t('err_auth_plugin');
    }
    // Google Play Services DEVELOPER_ERROR = 10
    if (s.contains('gms') &&
        (s.contains('ApiException: 10') ||
            s.contains(': 10:') ||
            s.contains(':10:') ||
            s.contains('statusCode=10'))) {
      return t('err_google_sha');
    }
    if (s.contains('sign_in_canceled') ||
        s.contains('sign_in_cancelled') ||
        s.toLowerCase().contains('canceled')) {
      return t('err_google_canceled');
    }
    return '${t('error')}: $e';
  }

  String? _firebaseCode(Object e) {
    try {
      final dynamic d = e;
      final c = d.code;
      if (c is String) return c;
    } catch (_) {}
    final m = RegExp(r'\[([^\]]+)\]').firstMatch(e.toString());
    final raw = m?.group(1);
    if (raw == null) return null;
    if (raw.contains('/')) return raw.split('/').last;
    return raw;
  }

  static const Map<String, Map<String, String>> _tables = {
    'tr': {
      'error': 'Hata',
      'login': 'Giriş Yap',
      'register': 'Kayıt Ol',
      'continue_google': 'Google ile devam et',
      'or': 'veya',
      'name': 'Adın',
      'email': 'E-posta',
      'password': 'Şifre',
      'no_account': 'Hesabın yok mu? Kayıt ol',
      'have_account': 'Zaten hesabın var mı? Giriş yap',
      'forgot_password': 'Şifremi unuttum',
      'send_reset': 'Sıfırlama e-postası gönder',
      'reset_sent': 'Şifre sıfırlama bağlantısı e-postana gönderildi.',
      'enter_email_first': 'Önce e-posta adresini gir.',
      'language': 'Dil',
      'turkish': 'Türkçe',
      'english': 'English',
      'settings': 'Ayarlar',
      'change_password': 'Şifre değiştir',
      'current_password': 'Mevcut şifre',
      'new_password': 'Yeni şifre',
      'confirm_password': 'Yeni şifre (tekrar)',
      'save': 'Kaydet',
      'cancel': 'İptal',
      'password_changed': 'Şifren güncellendi.',
      'password_mismatch': 'Yeni şifreler eşleşmiyor.',
      'password_too_short': 'Yeni şifre en az 6 karakter olmalı.',
      'google_only_password':
          'Bu hesap Google ile açıldı. Şifre değiştirme e-posta hesabı için geçerlidir.',
      'map_normal': 'Harita',
      'map_hybrid': 'Uydu',
      'live_location': 'Canlı Konum',
      'err_email_in_use':
          'Bu e-posta zaten kayıtlı. Giriş yapmayı dene veya Şifremi unuttum ile sıfırla.',
      'err_invalid_email': 'E-posta adresi geçersiz.',
      'err_weak_password': 'Şifre çok zayıf. En az 6 karakter kullan.',
      'err_wrong_password': 'E-posta veya şifre hatalı.',
      'err_user_not_found': 'Bu e-posta ile kayıtlı hesap bulunamadı.',
      'err_user_disabled': 'Bu hesap devre dışı bırakılmış.',
      'err_too_many': 'Çok fazla deneme. Bir süre sonra tekrar dene.',
      'err_network': 'İnternet bağlantısı yok veya zayıf.',
      'err_recent_login': 'Güvenlik için tekrar giriş yapıp şifreyi değiştir.',
      'err_auth_plugin':
          'Giriş tamamlandı (eklenti uyarısı yok sayıldı). Uygulamayı kullanmaya devam edebilirsin.',
      'err_google_sha':
          'Google girişi yapılandırılmamış (hata 10). Firebase Console → Project settings → Your apps → SHA-1 ekle, sonra google-services.json’u yenile.',
      'err_google_canceled': 'Google girişi iptal edildi.',
      'err_google_failed': 'Google ile giriş başarısız',
      'fill_email_password': 'E-posta ve şifre gerekli.',
      'nav_map': 'Harita',
      'nav_sos': 'SOS',
      'nav_messages': 'Mesaj',
      'nav_screen': 'Ekran',
      'nav_geofence': 'Bölgeler',
      'nav_settings': 'Ayarlar',
      'title_sos': 'SOS Olayları',
      'title_messages': 'Mesajlar',
      'title_screen': 'Ekran Süresi',
      'title_geofence': 'Güvenli Bölgeler',
      'title_settings': 'Ayarlar',
      'parent': 'Ebeveyn',
      'logout': 'Çıkış Yap',
      'connected_children': 'Bağlı Çocuklar',
      'tap_child_edit': 'Düzenle veya silmek için çocuğa dokun.',
      'invite_created': 'Davet kodu oluşturuldu.',
      'invite_failed': 'Davet kodu oluşturulamadı',
      'delete': 'Sil',
      'delete_failed': 'Silinemedi',
      'trace_active': 'İz takibi',
      'route_draft': 'Rota çiz',
      'delete_child_title': 'Çocuğu sil?',
      'delete_child_body':
          '“{name}” aileden çıkarılacak. Konum ve cihaz durumu silinir. Tekrar eklemek için yeni davet kodu gerekir.',
      'child_removed': '“{name}” silindi',
      'logout_confirm': 'Hesabından çıkmak istiyor musun?',
      'edit_name': 'Adı düzenle',
    },
    'en': {
      'error': 'Error',
      'login': 'Sign In',
      'register': 'Sign Up',
      'continue_google': 'Continue with Google',
      'or': 'or',
      'name': 'Your name',
      'email': 'Email',
      'password': 'Password',
      'no_account': 'No account? Sign up',
      'have_account': 'Already have an account? Sign in',
      'forgot_password': 'Forgot password',
      'send_reset': 'Send reset email',
      'reset_sent': 'Password reset link sent to your email.',
      'enter_email_first': 'Enter your email first.',
      'language': 'Language',
      'turkish': 'Türkçe',
      'english': 'English',
      'settings': 'Settings',
      'change_password': 'Change password',
      'current_password': 'Current password',
      'new_password': 'New password',
      'confirm_password': 'Confirm new password',
      'save': 'Save',
      'cancel': 'Cancel',
      'password_changed': 'Password updated.',
      'password_mismatch': 'New passwords do not match.',
      'password_too_short': 'New password must be at least 6 characters.',
      'google_only_password':
          'This account uses Google Sign-In. Password change is for email accounts.',
      'map_normal': 'Map',
      'map_hybrid': 'Satellite',
      'live_location': 'Live Location',
      'err_email_in_use':
          'This email is already registered. Sign in, or use Forgot password.',
      'err_invalid_email': 'Invalid email address.',
      'err_weak_password': 'Password is too weak. Use at least 6 characters.',
      'err_wrong_password': 'Incorrect email or password.',
      'err_user_not_found': 'No account found with this email.',
      'err_user_disabled': 'This account has been disabled.',
      'err_too_many': 'Too many attempts. Try again later.',
      'err_network': 'No internet connection or network is weak.',
      'err_recent_login': 'For security, sign in again and then change password.',
      'err_auth_plugin':
          'Sign-in completed (plugin warning ignored). You can continue.',
      'err_google_sha':
          'Google Sign-In is not configured (error 10). Firebase Console → Project settings → Your apps → add SHA-1, then refresh google-services.json.',
      'err_google_canceled': 'Google sign-in was canceled.',
      'err_google_failed': 'Google sign-in failed',
      'fill_email_password': 'Email and password are required.',
      'nav_map': 'Map',
      'nav_sos': 'SOS',
      'nav_messages': 'Chat',
      'nav_screen': 'Screen',
      'nav_geofence': 'Zones',
      'nav_settings': 'Settings',
      'title_sos': 'SOS Events',
      'title_messages': 'Messages',
      'title_screen': 'Screen Time',
      'title_geofence': 'Safe Zones',
      'title_settings': 'Settings',
      'parent': 'Parent',
      'logout': 'Sign Out',
      'connected_children': 'Linked Children',
      'tap_child_edit': 'Tap a child to edit or remove.',
      'invite_created': 'Invite code created.',
      'invite_failed': 'Could not create invite code',
      'delete': 'Delete',
      'delete_failed': 'Could not delete',
      'trace_active': 'Trail tracking',
      'route_draft': 'Draw route',
      'delete_child_title': 'Remove child?',
      'delete_child_body':
          '“{name}” will be removed from the family. Location and device status are cleared. A new invite code is needed to add again.',
      'child_removed': '“{name}” removed',
      'logout_confirm': 'Do you want to sign out?',
      'edit_name': 'Edit name',
    },
  };
}
