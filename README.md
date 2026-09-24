# 📱 Aile Takip — Ebeveyn Takip Uygulaması

Flutter ile yazılmış, Firebase tabanlı bir aile takip sistemi.  
İki ayrı uygulamadan oluşur: **Ebeveyn** ve **Çocuk**.

---

## 📂 Proje Yapısı

```
family_tracker/
├── parent_app/          ← Ebeveyn uygulaması
│   └── lib/
│       ├── main.dart
│       ├── models/
│       │   └── models.dart          # Tüm veri modelleri
│       ├── services/
│       │   ├── firebase_service.dart   # Firebase CRUD
│       │   └── geofence_service.dart   # Mesafe hesaplama
│       └── screens/
│           ├── auth_screen.dart        # Giriş / Kayıt
│           ├── home_screen.dart        # Ana ekran (bottom nav)
│           ├── map_screen.dart         # Canlı harita
│           ├── sos_screen.dart         # SOS olayları
│           ├── screen_stats_screen.dart # Ekran istatistikleri
│           ├── geofence_screen.dart    # Güvenli bölgeler
│           └── settings_screen.dart   # Ayarlar / davet kodu
│
├── child_app/           ← Çocuk uygulaması
│   └── lib/
│       ├── main.dart
│       ├── services/
│       │   ├── background_service.dart  # Arka plan konum
│       │   └── screen_stats_service.dart # Ekran istatistikleri
│       └── screens/
│           ├── join_screen.dart         # Davet koduyla katılım
│           └── child_home_screen.dart   # SOS butonu
│
└── firebase_rules/
    └── firestore.rules  ← Güvenlik kuralları
```

---

## 🔥 Firebase Kurulumu

### 1. Firebase Projesi Oluştur
1. [console.firebase.google.com](https://console.firebase.google.com) → Yeni Proje
2. **Authentication** → E-posta/Şifre ve Anonim giriş etkinleştir
3. **Firestore** → Veritabanı oluştur (production mode)
4. **Cloud Messaging** → Etkinleştir

### 2. Uygulamaları Ekle
Firebase Console'da:
- **parent_app** için: `com.senin.parent` paketi ile Android uygulaması ekle
- **child_app** için: `com.senin.child` paketi ile Android uygulaması ekle
- Her ikisi için `google-services.json` indir → `android/app/` klasörüne koy

### 3. Firestore Kurallarını Yükle
```bash
firebase deploy --only firestore:rules
```

---

## 📦 Kurulum

### Ebeveyn Uygulaması
```bash
cd parent_app
flutter pub get
flutter run
```

### Çocuk Uygulaması
```bash
cd child_app
flutter pub get
flutter run
```

---

## 🗺️ Google Maps Kurulumu

`parent_app/android/app/src/main/AndroidManifest.xml` içine ekle:
```xml
<meta-data
    android:name="com.google.android.geo.API_KEY"
    android:value="BURAYA_MAPS_API_KEY"/>
```

Google Cloud Console'dan Maps SDK for Android etkinleştir.

---

## 🚀 Kullanım Akışı

### Ebeveyn Tarafı
1. Uygulamayı aç → **Kayıt Ol**
2. **Ayarlar** → **Davet Kodu Oluştur** (6 haneli kod)
3. Kodu çocuğa ilet

### Çocuk Tarafı
1. Çocuk uygulamasını aç
2. Adını yaz + ebeveynden aldığı kodu gir → **Aileye Katıl**
3. Ana ekranda SOS butonu görünür, konum otomatik paylaşılır

---

## ⚙️ Özellikler

| Özellik | Ebeveyn | Çocuk |
|---------|---------|-------|
| Canlı konum haritası | ✅ Görür | ✅ Gönderir |
| Konum geçmişi (24s) | ✅ Görür | — |
| SOS gönderme | ✅ Alır | ✅ Gönderir |
| Geofence bölgesi | ✅ Tanımlar | — |
| Ekran istatistikleri | ✅ Görür | ✅ Gönderir |
| Davet kodu | ✅ Oluşturur | ✅ Kullanır |

---

## 📝 TODO (Sonraki Adımlar)

- [ ] Cloud Functions ile gerçek FCM push bildirimleri (SOS, geofence ihlali)
- [ ] Çocuk profil fotoğrafı
- [x] Çoklu çocuk seçimi geofence'de
- [ ] iOS uyumu testi
- [ ] Pil tüketimi optimizasyonu
- [x] Ekran süresi limiti belirleme özelliği
- [ ] Firebase gerçek proje bağlantısı ve cihaz testi

---

## 📚 Ek Dokümanlar

- [Firebase ve Google kurulum rehberi](docs/FIREBASE_SETUP.md)
- [Gizlilik, güvenlik ve mağaza uyumu](docs/PRIVACY_AND_SAFETY.md)
- [SIM'li / SIM'siz takip yol haritası](docs/TRACKER_ROADMAP.md)

---

## ⚠️ Önemli Notlar

- **Arka plan konum** (Android 10+): Kullanıcı "Her zaman izin ver" seçmelidir
- **Ekran istatistikleri**: Android'de `UsageStats` izni gerekir, iOS'ta kısıtlıdır
- **iOS**: Arka plan servisi Android kadar güçlü değil, significant location change API kullanılmalı
