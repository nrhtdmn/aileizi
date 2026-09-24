/// Mesaj önizleme metni (bildirim / liste).
String chatPreviewText(String type, String text, {String? routeName}) {
  switch (type) {
    case 'location':
      return '📍 Konum paylaştı';
    case 'image':
      return '📷 Fotoğraf gönderdi';
    case 'route':
      return '🗺️ ${routeName ?? 'Rota'} gönderdi';
    default:
      return text.trim().isEmpty ? 'Yeni mesaj' : text.trim();
  }
}

const parentQuickReplies = <String>[
  'Nasılsın?',
  'İyi misin?',
  'Neredesin?',
  'Eve geliyor musun?',
  'Haber ver lütfen',
  'Seni seviyorum ❤️',
];

const childQuickReplies = <String>[
  'İyiyim',
  'Nasılsın?',
  'Eve geliyorum',
  'Biraz geç kalacağım',
  'Yardım lazım',
  'Tamam',
];
