const dict = {
  tr: {
    brand: 'Aileİzi',
    tagline: 'Aile ve Çocuk Takip',
    parent: 'Ebeveyn',
    child: 'Çocuk',
    login: 'Giriş yap',
    register: 'Kayıt ol',
    email: 'E-posta',
    password: 'Şifre',
    name: 'Adınız',
    forgot: 'Şifremi unuttum',
    google: 'Google ile devam et',
    nav_map: 'Harita',
    nav_sos: 'SOS',
    nav_messages: 'Mesaj',
    nav_routes: 'Rota',
    nav_geofence: 'Bölge',
    nav_settings: 'Ayar',
    logout: 'Çıkış',
    invite: 'Davet kodu oluştur',
    children: 'Bağlı çocuklar',
    online: 'Çevrimiçi',
    offline: 'Çevrimdışı',
    battery: 'Pil',
    acknowledge: 'Onayla',
    delete: 'Sil',
    save: 'Kaydet',
    cancel: 'İptal',
    send: 'Gönder',
    install: 'Uygulamayı yükle',
    child_join: 'Davet koduyla katıl',
    child_mode: 'Çocuk modu',
    parent_mode: 'Ebeveyn modu',
    sos_hold: 'SOS için basılı tut',
    sharing_on: 'Konum paylaşımı açık',
    sharing_off: 'Konum paylaşımı kapalı',
    no_data: 'Veri yok',
    loading: 'Yükleniyor…',
  },
  en: {
    brand: 'Aileİzi',
    tagline: 'Family & Child Tracking',
    parent: 'Parent',
    child: 'Child',
    login: 'Sign in',
    register: 'Sign up',
    email: 'Email',
    password: 'Password',
    name: 'Your name',
    forgot: 'Forgot password',
    google: 'Continue with Google',
    nav_map: 'Map',
    nav_sos: 'SOS',
    nav_messages: 'Chat',
    nav_routes: 'Routes',
    nav_geofence: 'Zones',
    nav_settings: 'More',
    logout: 'Sign out',
    invite: 'Create invite code',
    children: 'Connected children',
    online: 'Online',
    offline: 'Offline',
    battery: 'Battery',
    acknowledge: 'Acknowledge',
    delete: 'Delete',
    save: 'Save',
    cancel: 'Cancel',
    send: 'Send',
    install: 'Install app',
    child_join: 'Join with invite',
    child_mode: 'Child mode',
    parent_mode: 'Parent mode',
    sos_hold: 'Hold for SOS',
    sharing_on: 'Location sharing on',
    sharing_off: 'Location sharing off',
    no_data: 'No data',
    loading: 'Loading…',
  },
};

let lang = localStorage.getItem('aileizi_lang') || 'tr';

export function getLang() {
  return lang;
}

export function setLang(code) {
  lang = code === 'en' ? 'en' : 'tr';
  localStorage.setItem('aileizi_lang', lang);
  document.documentElement.lang = lang;
}

export function t(key) {
  return dict[lang]?.[key] ?? dict.tr[key] ?? key;
}

export function fmtTime(d) {
  if (!d) return '—';
  const date = d instanceof Date ? d : new Date(d);
  return date.toLocaleString(lang === 'en' ? 'en-US' : 'tr-TR', {
    day: '2-digit',
    month: 'short',
    hour: '2-digit',
    minute: '2-digit',
  });
}

export function haversineM(lat1, lng1, lat2, lng2) {
  const R = 6371000;
  const toR = (x) => (x * Math.PI) / 180;
  const dLat = toR(lat2 - lat1);
  const dLng = toR(lng2 - lng1);
  const a =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(toR(lat1)) * Math.cos(toR(lat2)) * Math.sin(dLng / 2) ** 2;
  return 2 * R * Math.asin(Math.sqrt(a));
}

export function toast(msg, type = 'info') {
  let el = document.getElementById('toast');
  if (!el) {
    el = document.createElement('div');
    el.id = 'toast';
    el.className = 'toast';
    document.body.appendChild(el);
  }
  el.textContent = msg;
  el.dataset.type = type;
  el.classList.add('show');
  clearTimeout(el._t);
  el._t = setTimeout(() => el.classList.remove('show'), 3200);
}

export async function notifyBrowser(title, body, tag) {
  try {
    if (!('Notification' in window)) return;
    if (Notification.permission === 'default') {
      await Notification.requestPermission();
    }
    if (Notification.permission === 'granted') {
      new Notification(title, { body, tag, icon: './assets/icons/icon-192.png' });
    }
  } catch (_) {}
}

export function escapeHtml(s) {
  return String(s ?? '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}
