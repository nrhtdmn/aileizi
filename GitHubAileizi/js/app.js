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
import { t, setLang, getLang, toast } from './utils.js';
import { mountMap, unmountMap, focusMapOn } from './views/map.js';
import { mountSos, unmountSos } from './views/sos.js';
import { mountMessages, unmountMessages } from './views/messages.js';
import { mountStats, unmountStats } from './views/stats.js';
import { mountGeofence, unmountGeofence } from './views/geofence.js';
import { mountSettings, unmountSettings } from './views/settings.js';
import {
  mountChildAuth,
  mountChildHome,
  resolveChildSession,
  unmountChild,
} from './views/child.js';

const app = document.getElementById('app');
let currentTab = 0;
let unmountCurrent = null;
let deferredPrompt = null;

const NAV = [
  { id: 'map', label: 'nav_map', ico: '🗺' },
  { id: 'sos', label: 'nav_sos', ico: '🆘' },
  { id: 'messages', label: 'nav_messages', ico: '💬' },
  { id: 'screen', label: 'nav_screen', ico: '📱' },
  { id: 'geofence', label: 'nav_geofence', ico: '📍' },
  { id: 'settings', label: 'nav_settings', ico: '⚙' },
];

setLang(getLang());

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

  renderParentShell();
});

function cleanup() {
  unmountCurrent?.();
  unmountCurrent = null;
  unmountMap();
  unmountSos();
  unmountMessages();
  unmountStats();
  unmountGeofence();
  unmountSettings();
  unmountChild();
}

function renderParentAuth() {
  app.innerHTML = `
    <div class="auth-screen">
      <div class="auth-card">
        <div class="brand-hero">
          <img src="./assets/logo.png" alt="Aileİzi" width="96" height="96" />
          <h1>${Brand.name}</h1>
          <p>${Brand.tagline}</p>
          <p>${t('parent')} · Web</p>
        </div>
        <div class="lang-row">
          <button type="button" class="chip ${getLang() === 'tr' ? 'active' : ''}" data-lang="tr">TR</button>
          <button type="button" class="chip ${getLang() === 'en' ? 'active' : ''}" data-lang="en">EN</button>
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
        <button class="btn btn-ghost" id="auth-google">${t('google')}</button>
        <button class="linkish" id="auth-forgot">${t('forgot')}</button>
        <div class="mode-switch">
          <button type="button" id="to-child">${t('child_mode')}</button>
        </div>
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

  app.querySelectorAll('[data-lang]').forEach((b) => {
    b.onclick = () => {
      setLang(b.dataset.lang);
      renderParentAuth();
    };
  });

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
    <div class="app-shell">
      <header class="topbar">
        <div>
          <h2>${Brand.name}</h2>
          <div class="sub">${t('parent')} · ${escape(auth.currentUser?.displayName || auth.currentUser?.email || '')}</div>
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
      <div class="install-banner" id="install-banner">
        <span>${t('install')}</span>
        <button class="btn btn-sm" id="install-btn" style="background:#fff;color:var(--parent-primary)">${t('install')}</button>
      </div>
    </div>
  `;

  app.querySelector('#bottom-nav').onclick = (e) => {
    const btn = e.target.closest('button[data-i]');
    if (!btn) return;
    currentTab = Number(btn.dataset.i);
    app.querySelectorAll('#bottom-nav button').forEach((b) =>
      b.classList.toggle('active', b === btn),
    );
    showTab(currentTab);
  };

  app.querySelector('#install-btn')?.addEventListener('click', async () => {
    if (!deferredPrompt) return;
    deferredPrompt.prompt();
    await deferredPrompt.userChoice;
    deferredPrompt = null;
    document.getElementById('install-banner')?.classList.remove('show');
  });

  showTab(currentTab);
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
  unmountStats();
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
      mountStats(root);
      unmountCurrent = unmountStats;
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
}

// PWA service worker
if ('serviceWorker' in navigator) {
  window.addEventListener('load', () => {
    navigator.serviceWorker.register('./sw.js').catch(() => {});
  });
}
