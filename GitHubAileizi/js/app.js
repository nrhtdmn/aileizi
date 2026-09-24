import {
  auth,
  onAuthStateChanged,
  signInParent,
  registerParent,
  signInParentGoogle,
  sendPasswordResetEmail,
  ensureParentProfile,
  getDoc,
  doc,
  db,
  describeError,
} from './firebase-app.js';
import { Brand } from './config.js';
import { t, setLang, toast } from './utils.js';
import { mountMap, unmountMap, focusMapOn } from './views/map.js';
import { mountSos, unmountSos } from './views/sos.js';
import { mountMessages, unmountMessages } from './views/messages.js';
import { mountRecords, unmountRecords } from './views/records.js';
import { mountGeofence, unmountGeofence } from './views/geofence.js';
import { mountSettings, unmountSettings } from './views/settings.js';
import {
  mountChildAuth,
  mountChildHome,
  resolveChildSession,
  unmountChild,
} from './views/child.js';
import { startParentAlerts, stopParentAlerts } from './alerts.js';
import { setKeepAwake, clearKeepAwake } from './keep-awake.js';

const app = document.getElementById('app');
let currentTab = 0;
let unmountCurrent = null;
let deferredPrompt = null;
let chromeHidden = false;

const NAV = [
  { id: 'map', label: 'nav_map', ico: '🗺️' },
  { id: 'sos', label: 'nav_sos', ico: '🆘' },
  { id: 'messages', label: 'nav_messages', ico: '💬' },
  { id: 'records', label: 'nav_routes', ico: '📂' },
  { id: 'geofence', label: 'nav_geofence', ico: '📍' },
  { id: 'settings', label: 'nav_settings', ico: '⚙️' },
];

setLang('tr');

window.addEventListener('beforeinstallprompt', (e) => {
  e.preventDefault();
  deferredPrompt = e;
  const ban = document.getElementById('install-banner');
  if (ban) ban.classList.add('show');
});

function mode() {
  return localStorage.getItem('aileizi_mode') || 'parent';
}

onAuthStateChanged(auth, async (user) => {
  cleanup();
  if (!user) {
    if (mode() === 'child') {
      mountChildAuth(app, {
        onJoined: () => location.reload(),
      });
    } else {
      renderParentAuth();
    }
    return;
  }

  if (mode() === 'child') {
    const session = await resolveChildSession();
    if (session) {
      mountChildHome(app, session);
    } else {
      mountChildAuth(app, { onJoined: () => location.reload() });
    }
    return;
  }

  // Parent: anonymous child accounts shouldn't use parent shell
  try {
    const snap = await getDoc(doc(db, 'users', user.uid));
    if (snap.data()?.role === 'child') {
      localStorage.setItem('aileizi_mode', 'child');
      location.reload();
      return;
    }
  } catch (_) {}

  try {
    await ensureParentProfile(user);
  } catch (e) {
    toast(describeError(e), 'error');
  }

  if ('Notification' in window && Notification.permission === 'default') {
    Notification.requestPermission().catch(() => {});
  }

  startParentAlerts().catch(() => {});
  window.__aileiziGoTab = (i) => {
    currentTab = i;
    document
      .querySelectorAll('#bottom-nav button')
      .forEach((b) => b.classList.toggle('active', Number(b.dataset.i) === i));
    showTab(i);
  };

  renderParentShell();
});

function cleanup() {
  unmountCurrent?.();
  unmountCurrent = null;
  unmountMap();
  unmountSos();
  unmountMessages();
  unmountRecords();
  unmountGeofence();
  unmountSettings();
  unmountChild();
  stopParentAlerts();
  clearKeepAwake();
}

function renderParentAuth() {
  app.innerHTML = `
    <div class="auth-screen">
      <div class="auth-card">
        <div class="brand-hero">
          <img src="./assets/logo.png" alt="Aileİzi" width="64" height="64" />
          <h1>${Brand.name}</h1>
          <p>${t('parent')}</p>
        </div>
        <div class="tabs">
          <button type="button" class="active" data-tab="login">${t('login')}</button>
          <button type="button" data-tab="register">${t('register')}</button>
        </div>
        <div id="auth-err" class="error-box hidden"></div>
        <div id="reg-name" class="field hidden">
          <label>${t('name')}</label>
          <input id="auth-name" autocomplete="name" />
        </div>
        <div class="field">
          <label>${t('email')}</label>
          <input id="auth-email" type="email" autocomplete="email" />
        </div>
        <div class="field">
          <label>${t('password')}</label>
          <input id="auth-password" type="password" autocomplete="current-password" />
        </div>
        <button class="btn btn-primary" id="auth-submit">${t('login')}</button>
        <button class="btn btn-outline" id="auth-google" style="width:100%;margin-top:8px">${t('google')}</button>
        <button class="linkish" id="auth-forgot">${t('forgot')}</button>
        <div class="mode-switch">
          <button type="button" id="to-child">${t('child_mode')}</button>
        </div>
        <p class="dev-credit">
          <a href="https://www.instagram.com/nurhatduman/" target="_blank" rel="noopener noreferrer">Nurhat DUMAN</a>
          tarafından geliştirilmiştir.
        </p>
      </div>
    </div>
  `;

  let tab = 'login';
  const err = () => app.querySelector('#auth-err');
  const showErr = (m) => {
    const e = err();
    e.textContent = m;
    e.classList.toggle('hidden', !m);
  };

  app.querySelectorAll('.tabs button').forEach((b) => {
    b.onclick = () => {
      tab = b.dataset.tab;
      app.querySelectorAll('.tabs button').forEach((x) =>
        x.classList.toggle('active', x === b),
      );
      app.querySelector('#reg-name').classList.toggle('hidden', tab !== 'register');
      app.querySelector('#auth-submit').textContent =
        tab === 'login' ? t('login') : t('register');
    };
  });

  app.querySelector('#auth-submit').onclick = async () => {
    showErr('');
    const email = app.querySelector('#auth-email').value.trim();
    const password = app.querySelector('#auth-password').value;
    const name = app.querySelector('#auth-name').value.trim();
    const btn = app.querySelector('#auth-submit');
    btn.disabled = true;
    try {
      if (tab === 'register') {
        if (!name) throw new Error('Ad gerekli');
        await registerParent(email, password, name);
      } else {
        await signInParent(email, password);
      }
    } catch (e) {
      showErr(describeError(e));
    } finally {
      btn.disabled = false;
    }
  };

  app.querySelector('#auth-google').onclick = async () => {
    showErr('');
    try {
      await signInParentGoogle();
    } catch (e) {
      showErr(describeError(e));
    }
  };

  app.querySelector('#auth-forgot').onclick = async () => {
    const email = app.querySelector('#auth-email').value.trim();
    if (!email) {
      showErr('E-posta girin');
      return;
    }
    try {
      await sendPasswordResetEmail(auth, email);
      toast('Sıfırlama e-postası gönderildi', 'success');
    } catch (e) {
      showErr(describeError(e));
    }
  };

  app.querySelector('#to-child').onclick = async () => {
    localStorage.setItem('aileizi_mode', 'child');
    try {
      const { signOut } = await import('./firebase-app.js');
      await signOut(auth);
    } catch (_) {}
    location.reload();
  };
}

function renderParentShell() {
  app.innerHTML = `
    <div class="app-shell" id="app-shell">
      <header class="topbar" id="topbar">
        <div class="topbar-brand">
          <img src="./assets/logo.png" alt="" class="topbar-logo" width="36" height="36" />
          <div class="topbar-titles">
            <h2>${Brand.name}</h2>
          </div>
          <select id="top-child" class="top-child-select" aria-label="Çocuk">
            <option value="">Tüm çocuklar</option>
          </select>
        </div>
      </header>
      <main id="view-root"></main>
      <nav class="bottom-nav" id="bottom-nav">
        ${NAV.map(
          (n, i) => `
          <button type="button" data-i="${i}" class="${i === currentTab ? 'active' : ''}">
            <span class="ico">${n.ico}</span>
            <span>${t(n.label)}</span>
          </button>`,
        ).join('')}
      </nav>
      <button type="button" class="chrome-toggle-fab hidden" id="btn-chrome-toggle">Gizle</button>
      <div class="install-banner" id="install-banner">
        <span>${t('install')}</span>
        <button class="btn btn-sm" id="install-btn" style="background:#fff;color:var(--green)">Yükle</button>
      </div>
    </div>
  `;

  const applyChrome = () => {
    const shell = document.getElementById('app-shell');
    const toggle = document.getElementById('btn-chrome-toggle');
    shell?.classList.toggle('chrome-hidden', chromeHidden);
    if (toggle) {
      toggle.textContent = chromeHidden ? 'Göster' : 'Gizle';
      toggle.title = chromeHidden ? 'Menüyü göster' : 'Sadece harita';
    }
    setKeepAwake('chrome', chromeHidden);
    setTimeout(() => {
      window.dispatchEvent(new Event('resize'));
      // Leaflet needs a second pass after layout settles
      setTimeout(() => window.dispatchEvent(new Event('resize')), 120);
    }, 40);
  };

  app.querySelector('#btn-chrome-toggle').onclick = () => {
    chromeHidden = !chromeHidden;
    applyChrome();
  };

  app.querySelector('#bottom-nav').onclick = (e) => {
    const btn = e.target.closest('button[data-i]');
    if (!btn) return;
    currentTab = Number(btn.dataset.i);
    app.querySelectorAll('#bottom-nav button').forEach((b) =>
      b.classList.toggle('active', b === btn),
    );
    if (currentTab !== 0 && chromeHidden) {
      chromeHidden = false;
      applyChrome();
    }
    showTab(currentTab);
    syncTopChildVisibility();
  };

  app.querySelector('#install-btn')?.addEventListener('click', async () => {
    if (!deferredPrompt) return;
    deferredPrompt.prompt();
    await deferredPrompt.userChoice;
    deferredPrompt = null;
    document.getElementById('install-banner')?.classList.remove('show');
  });

  showTab(currentTab);
  syncTopChildVisibility();
  applyChrome();
}

function syncTopChildVisibility() {
  const sel = document.getElementById('top-child');
  const toggle = document.getElementById('btn-chrome-toggle');
  const mapTab = currentTab === 0;
  const mapLike = currentTab === 0 || currentTab === 4;
  if (sel) sel.classList.toggle('hidden', !mapLike);
  if (toggle) toggle.classList.toggle('hidden', !mapTab);
}

function escape(s) {
  return String(s)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;');
}

function showTab(i) {
  const root = document.getElementById('view-root');
  if (!root) return;
  unmountCurrent?.();
  unmountMap();
  unmountSos();
  unmountMessages();
  unmountRecords();
  unmountGeofence();
  unmountSettings();

  switch (i) {
    case 0:
      mountMap(root);
      unmountCurrent = unmountMap;
      break;
    case 1:
      mountSos(root, {
        onOpenMap: (lat, lng) => {
          currentTab = 0;
          document
            .querySelectorAll('#bottom-nav button')
            .forEach((b) =>
              b.classList.toggle('active', Number(b.dataset.i) === 0),
            );
          showTab(0);
          setTimeout(() => focusMapOn(lat, lng), 300);
        },
      });
      unmountCurrent = unmountSos;
      break;
    case 2:
      mountMessages(root);
      unmountCurrent = unmountMessages;
      break;
    case 3:
      mountRecords(root);
      unmountCurrent = unmountRecords;
      break;
    case 4:
      mountGeofence(root);
      unmountCurrent = unmountGeofence;
      break;
    case 5:
      mountSettings(root);
      unmountCurrent = unmountSettings;
      break;
    default:
      break;
  }
  syncTopChildVisibility();
}

// PWA service worker
if ('serviceWorker' in navigator) {
  window.addEventListener('load', () => {
    navigator.serviceWorker.register('./sw.js').catch(() => {});
  });
}
