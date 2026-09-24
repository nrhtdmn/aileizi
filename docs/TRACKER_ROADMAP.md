# Takip Ürünü Yol Haritası

Amaç sadece çocuk telefonu takip etmek değil; çocuk, eşya, araç, evcil hayvan veya özel takip cihazlarını tek aile panelinde korumaktır.

## Ortak kavram: Tracked Entity

Mevcut kodda merkez kavram `child` olarak geçiyor. Ürün büyürken bu model `TrackedEntity` yapısına çevrilmelidir.

Önerilen alanlar:

- `id`
- `familyId`
- `type`: `child`, `item`, `vehicle`, `pet`, `sim_tracker`, `ble_tag`
- `name`
- `photoUrl`
- `linkedUserId`: telefon uygulamasıyla izleniyorsa kullanıcı UID
- `hardwareId`: IMEI, seri no veya BLE device id
- `isActive`
- `createdAt`

Konum formatı aynı kalabilir:

- `entityId`
- `latitude`
- `longitude`
- `accuracy`
- `speed`
- `heading`
- `batteryLevel`
- `source`: `phone`, `sim_tracker`, `ble`, `manual`, `qr`
- `timestamp`
- `isOnline`

## Faz A: Telefon ile çocuk takibi

Durum: Mevcut uygulamanın ana hedefi budur.

Kalan iyileştirmeler:

- Firebase gerçek proje bağlantısı
- Cloud Functions ile push bildirimleri
- Offline/son görülme uyarısı
- Pil tüketimi için mesafe bazlı konum güncelleme
- Konum geçmişine TTL/temizlik
- Çoklu ebeveyn desteği

## Faz B: SIM kartlı küçük takip cihazı

SIM'li GPS anahtarlık cihazları genellikle GPS + GSM/GPRS ile veri yollar.

En doğru mimari:

1. Cihaz GPS konumunu üretir.
2. Cihaz üretici protokolüyle sunucuya gönderir.
3. Alıcı servis paketi çözer.
4. Firestore `locations` ve `location_history` koleksiyonlarına yazar.
5. Ebeveyn uygulaması aynı harita ekranında gösterir.

Desteklenecek entegrasyon tipleri:

- Üretici API entegrasyonu
- GT06 / Concox gibi TCP protokol alıcısı
- SMS tabanlı cihazlar için opsiyonel SMS parse köprüsü

Gerekli backend bileşenleri:

- `tracker_devices` koleksiyonu
- IMEI/seri no eşleştirme ekranı
- Cihazdan gelen veriyi doğrulayan imza/token
- Rate limit ve veri doğrulama
- Düşük pil ve cihaz offline uyarıları

## Faz C: SIM ihtiyacı olmadan takip

Önemli gerçek: SIM'siz ve internetsiz bir cihaz gerçek zamanlı uzak takip yapamaz. Alternatifler farklı beklentiyle sunulmalıdır.

Seçenekler:

- BLE etiket: telefon yakındayken algılar, son görülen konumu kaydeder.
- QR/NFC etiket: bulan kişi okutunca konum veya iletişim kaydı oluşur.
- Wi-Fi destekli cihaz: internete bağlanabiliyorsa konum gönderebilir.
- Ekosistem cihazları: AirTag/SmartTag gibi çözümler kapalı ekosistemdir; doğrudan entegrasyon sınırlıdır.

Önerilen ürün dili:

- "Canlı takip": telefon veya SIM'li GPS cihazı.
- "Son görülen yer": BLE etiketi.
- "Bulana ulaştır": QR/NFC etiketi.

## Faz D: Araç takibi

Araç için ek özellikler:

- Hız takibi
- Rota geçmişi
- Kontak/park durumu (donanım destekliyorsa)
- Belirli hız üstünde uyarı
- Çekilme/hareket algılama
- Güvenli park bölgesi

## Öncelikli geliştirme sırası

1. Telefon tabanlı akışı gerçek Firebase ve cihaz testleriyle stabil hale getir.
2. Cloud Functions push bildirimlerini ekle.
3. `child` merkezli isimleri kademeli olarak `entity` modeline taşı.
4. SIM'li cihaz entegrasyonu için önce üretici API destekli bir cihaz seç.
5. BLE/QR/NFC etiketleri "son görülen yer" ürünü olarak ekle.
