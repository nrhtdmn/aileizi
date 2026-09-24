import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

  static const Map<String, Map<String, String>> _tables = {
    'tr': {
      'join_title': 'Aileye Katıl',
      'child_name': 'Çocuğun adı',
      'invite_code': 'Davet kodu',
      'join': 'Katıl',
      'consent': 'Takip ve konum paylaşımını onaylıyorum',
      'fill_all': 'Lütfen tüm alanları doldurun',
      'consent_required':
          'Takip ve konum paylaşımı bilgilendirmesini onaylayın',
    },
    'en': {
      'join_title': 'Join Family',
      'child_name': "Child's name",
      'invite_code': 'Invite code',
      'join': 'Join',
      'consent': 'I agree to tracking and location sharing',
      'fill_all': 'Please fill in all fields',
      'consent_required': 'Please accept the tracking consent',
    },
  };
}
