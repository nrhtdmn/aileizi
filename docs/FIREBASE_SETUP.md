# Firebase ve Google Kurulum Rehberi

Bu proje yerel kod olarak hazırlandı; gerçek Firebase hesabı, Android uygulama kayıtları ve Google Maps API anahtarı kullanıcı hesabıyla tamamlanmalıdır.

## 1. Firebase giriş

PowerShell'de proje kökünde çalıştır:

```powershell
firebase login
```

Tarayıcıdan Google hesabıyla giriş yap.

## 2. Firebase projesi oluştur veya seç

Firebase Console'da şu servisleri aç:

- Authentication: Email/Password ve Anonymous
- Firestore Database: production mode
- Cloud Messaging

Android uygulamaları:

- Ebeveyn: `com.senin.parent`
- Çocuk: `com.senin.child`

## 3. FlutterFire dosyalarını üret

FlutterFire CLI yüklü değilse:

```powershell
dart pub global activate flutterfire_cli
```

Komut PATH'e ekli değilse tam yol:

```powershell
$env:Path += ";$env:LOCALAPPDATA\Pub\Cache\bin"
```

Ebeveyn uygulaması:

```powershell
cd parent_app
flutterfire configure --platforms=android --android-package-name=com.senin.parent
```

Çocuk uygulaması:

```powershell
cd ..\child_app
flutterfire configure --platforms=android --android-package-name=com.senin.child
```

Beklenen dosyalar:

- `parent_app/lib/firebase_options.dart`
- `parent_app/android/app/google-services.json`
- `child_app/lib/firebase_options.dart`
- `child_app/android/app/google-services.json`

## 4. Google Maps API anahtarı

Google Cloud Console'da `Maps SDK for Android` etkinleştir.

`parent_app/android/app/src/main/AndroidManifest.xml` içinde:

```xml
<meta-data
    android:name="com.google.android.geo.API_KEY"
    android:value="YOUR_GOOGLE_MAPS_API_KEY" />
```

`YOUR_GOOGLE_MAPS_API_KEY` değerini gerçek anahtarla değiştir.

## 5. Firestore kurallarını deploy et

**Önemli:** Kurallar yalnızca repoda durursa uygulama `permission-denied` alır; konum, isim düzenleme, davet kodu, mesaj vs. çalışmaz.

Proje kökünde (bir kez giriş):

```powershell
firebase login
firebase use aile-takip-8bf84
firebase deploy --only firestore:rules,storage
```

`.firebaserc` varsayılan projeyi `aile-takip-8bf84` olarak ayarlar.

Firebase Console → Firestore → Rules ve Storage → Rules sekmelerinde kuralların yayınlandığını kontrol et.

### Kota dolduysa (Spark / ücretsiz)

Günde ~50k okuma / 20k yazma. Aşınca `RESOURCE_EXHAUSTED` — işlemler durur.

1. **Bekle:** Kota Pasifik gece yarısında (~10:00 Türkiye) sıfırlanır.
2. **Hemen devam:** Firebase’de **Blaze (pay-as-you-go)** aç; bütçe uyarısı koy (ör. 5–10 USD). Ücretsiz kotanın üstü ücretlenir, küçük kullanımda genelde düşük kalır.
3. Uygulama artık konumu daha seyrek yazar (kota dostu).

`firebase.json` kuralları `firebase_rules/` altından alır.

## 6. Kontrol

Her iki uygulama için:

```powershell
flutter pub get
flutter analyze
flutter test
flutter run
```

Gerçek cihaz testi sırası:

1. Ebeveyn uygulamasında kayıt ol.
2. Ayarlar ekranından davet kodu oluştur.
3. Çocuk uygulamasında ad + davet kodu ile katıl.
4. Konum iznini "Her zaman izin ver" yap.
5. Ebeveyn haritasında çocuğun konumunu doğrula.
6. Güvenli bölge oluştur, çocuk seç ve giriş/çıkış olayını test et.
7. SOS butonunu test et.
