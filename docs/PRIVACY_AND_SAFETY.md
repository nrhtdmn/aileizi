# Gizlilik, Güvenlik ve Mağaza Uyumu

Bu proje aile güvenliği ve varlık takibi amacıyla tasarlanmıştır. Takip özelliği kötüye kullanılabileceği için ürün kararları açık rıza, görünür bildirim ve minimum veri ilkeleriyle ilerlemelidir.

## Temel ilkeler

- Takip edilen kişi/cihaz uygulamanın konum gönderdiğini açıkça görmelidir.
- Çocuk cihazında konum paylaşımı kapatılabilir olmalıdır.
- Arka plan konum bildirimi Android'de görünür foreground notification ile çalışmalıdır.
- SOS, düşük pil, güvenli bölge ihlali gibi kritik uyarılar ebeveyne hızlı iletilmelidir.
- Konum geçmişi sınırsız tutulmamalıdır; Firestore TTL veya düzenli temizlik eklenmelidir.
- Veriler aile üyeleri dışındaki kullanıcılara açılmamalıdır.
- Eş, çalışan veya üçüncü kişileri habersiz takip etme senaryosu ürün tarafından teşvik edilmemelidir.

## Mağaza politikası notları

Google Play ve App Store arka plan konum, SMS/arama erişimi ve "ebeveyn kontrolü" özelliklerinde hassastır.

- Arka plan konum için açık açıklama ekranı ve izin öncesi bilgilendirme gerekir.
- SMS/arama izleme çoğu durumda mağaza tarafından reddedilebilir veya özel izin ister.
- Web filtreleme için Android'de VPN/DNS/Accessibility gibi ek yerel katmanlar gerekir.
- "Gizli takip" veya "stalkerware" izlenimi veren metinlerden kaçınılmalıdır.

## Veri saklama önerisi

- Canlı konum: `families/{familyId}/locations/{childId}`
- Geçmiş konum: en fazla 7-30 gün
- SOS olayları: en fazla 90 gün veya ebeveyn silene kadar
- Ekran istatistikleri: günlük toplamlar, ayrıntılı uygulama listesi isteğe bağlı
- Cihaz durumu: son durum belgesi, geçmiş tutmaya gerek yok

## Yayın öncesi kontrol listesi

- Gizlilik politikası URL'si hazırlandı.
- Uygulama içinde arka plan konum açıklaması var.
- Firebase kuralları test edildi.
- Kayıt/davet akışı gerçek cihazda test edildi.
- Konum paylaşımını kapatma gerçek veri akışını durduruyor.
- SOS ve geofence bildirimleri kapalı/açık uygulama durumlarında test edildi.
