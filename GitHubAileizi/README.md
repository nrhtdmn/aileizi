# Aileİzi — GitHub Pages PWA

Flutter uygulamalarını **bozmadan** eklenen web sürümü. Aynı Firebase projesini kullanır: `aile-takip-8bf84`.

## Özellikler

### Ebeveyn
- Giriş / kayıt (e-posta + Google)
- Canlı harita (Leaflet + OSM), çocuk konumları, 24 saat iz
- Rota çizme + OSRM otomatik rota
- SOS listesi (onay / sil / haritada aç) + tarayıcı bildirimi
- Mesajlar (metin, konum, fotoğraf — Storage)
- Ekran kullanım istatistikleri + 7 günlük grafik
- Güvenli bölgeler (geofence) + olaylar
- Davet kodu, çocuk yönetimi, dijital ebeveynlik politikası, şifre değiştirme
- Türkçe arayüz

### Çocuk (web)
- Davet koduyla katılım (anonim Auth)
- Konum paylaşımı (Geolocation API)
- 3 saniye basılı tut SOS
- Mesajlaşma + fotoğraf

### PWA
- `manifest.webmanifest` + service worker
- Ana ekrana kurulum banner’ı
- Offline kabuk önbelleği (Firebase verisi çevrimiçi gerekir)

## Yerel önizleme

GitHub Pages gibi HTTPS gerekir (konum / PWA için). Yerelde:

```bash
cd GitHubAileizi
npx --yes serve -p 5173
```

Tarayıcıda: `http://localhost:5173`

## GitHub Pages yayınlama

1. Bu klasörü repoya push edin (mevcut Flutter klasörlerine dokunmayın).
2. Repo → **Settings → Pages**:
   - Source: `Deploy from a branch`
   - Branch: `main` (veya `gh-pages`)
   - Folder: `/GitHubAileizi` **veya** bu klasörün içeriğini `gh-pages` dalının köküne koyun
3. Site URL örneği: `https://<kullanici>.github.io/<repo>/GitHubAileizi/`

### Firebase zorunlu ayarlar

Firebase Console → **Authentication → Settings → Authorized domains**:

- `localhost`
- `<kullanici>.github.io`

Google giriş için **Authentication → Sign-in method → Google** açık olmalı.

Web uygulaması zaten oluşturuldu:

- App ID: `1:151476278678:web:9de0e9674290c4513ff9b7`
- Yapılandırma: `js/config.js`

## Notlar

- Mobil Flutter uygulamaları (`parent_app`, `child_app`) aynen çalışmaya devam eder; veri ortak Firestore’dadır.
- Çocuk web modunda arka plan konum / ekran süresi kısıtlıdır (tarayıcı limitleri). Tam arka plan için Flutter çocuk uygulaması önerilir.
- Harita Google Maps yerine OpenStreetMap kullanır (API anahtarı gerekmez).

## Klasör yapısı

```
GitHubAileizi/
  index.html
  manifest.webmanifest
  sw.js
  css/app.css
  js/…          # Firebase + ekranlar
  assets/…      # logo & ikonlar
```
