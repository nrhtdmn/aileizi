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

const childQuickReplies = <String>[
  'İyiyim',
  'Nasılsın?',
  'Eve geliyorum',
  'Biraz geç kalacağım',
  'Yardım lazım',
  'Tamam',
];
