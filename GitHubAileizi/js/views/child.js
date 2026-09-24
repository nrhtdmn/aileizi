import {
  auth,
  db,
  doc,
  setDoc,
  getDoc,
  getDocs,
  updateDoc,
  addDoc,
  collection,
  onSnapshot,
  signInAnonymously,
  serverTimestamp,
  arrayUnion,
  tsToDate,
  describeError,
  storage,
  storageRef,
  uploadBytes,
  getDownloadURL,
} from '../firebase-app.js';
import { Brand } from '../config.js';
import { t, toast, escapeHtml, haversineM, fmtTime } from '../utils.js';
import { setKeepAwake } from '../keep-awake.js';

const PREF_FAMILY = 'aileizi_child_family';
const PREF_NAME = 'aileizi_child_name';
const PREF_GEO_STATE = 'aileizi_geo_inside';

let watchId = null;
let chatUnsub = null;
let locTimer = null;
let lastLat = null;
let lastLng = null;
let lastWrite = 0;
let childSessionName = '';
/** @type {{ familyId: string, uid: string, name?: string } | null} */
let activeLocSession = null;
/** @type {Record<string, boolean>} fenceId → wasInside */
let geoInsideCache = {};

try {
  geoInsideCache = JSON.parse(localStorage.getItem(PREF_GEO_STATE) || '{}') || {};
} catch (_) {
  geoInsideCache = {};
}

function persistGeoState() {
  try {
    localStorage.setItem(PREF_GEO_STATE, JSON.stringify(geoInsideCache));
  } catch (_) {}
}

document.addEventListener('visibilitychange', () => {
  if (document.visibilityState !== 'visible' || !activeLocSession) return;
  writeLocation(activeLocSession.familyId, activeLocSession.uid, true).catch(
    () => {},
  );
});

export function mountChildAuth(root, { onJoined }) {
  root.innerHTML = `
    <div class="auth-screen child-theme">
      <div class="auth-card">
        <div class="brand-hero">
          <img src="./assets/logo.png" alt="Aileİzi" />
          <h1>${Brand.name}</h1>
          <p>${t('child')}</p>
        </div>
        <div id="child-err" class="error-box hidden"></div>
        <div class="field">
          <label>${t('name')}</label>
          <input id="child-name" autocomplete="name" />
        </div>
        <div class="field">
          <label>Davet kodu</label>
          <input id="child-code" inputmode="numeric" maxlength="6" placeholder="123456" />
        </div>
        <label class="consent">
          <input type="checkbox" id="child-consent" />
          <span>Konum paylaşımına ve aile takibine izin veriyorum.</span>
        </label>
        <button class="btn btn-primary" id="child-join">${t('child_join')}</button>
        <div class="mode-switch">
          <button type="button" id="to-parent">${t('parent_mode')}</button>
        </div>
        <p class="dev-credit">
          <a href="https://www.instagram.com/nurhatduman/" target="_blank" rel="noopener noreferrer">Nurhat DUMAN</a>
          tarafından geliştirilmiştir.
        </p>
      </div>
    </div>
  `;

  root.querySelector('#to-parent').onclick = async () => {
    localStorage.setItem('aileizi_mode', 'parent');
    try {
      const { signOut } = await import('../firebase-app.js');
      await signOut(auth);
    } catch (_) {}
    location.reload();
  };

  root.querySelector('#child-join').onclick = async () => {
    const name = root.querySelector('#child-name').value.trim();
    const code = root.querySelector('#child-code').value.trim();
    const consent = root.querySelector('#child-consent').checked;
    const err = root.querySelector('#child-err');
    err.classList.add('hidden');
    if (!name || !code) {
      err.textContent = 'Tüm alanları doldurun';
      err.classList.remove('hidden');
      return;
    }
    if (!consent) {
      err.textContent = 'Onay gerekli';
      err.classList.remove('hidden');
      return;
    }
    const btn = root.querySelector('#child-join');
    btn.disabled = true;
    try {
      let user = auth.currentUser;
      if (!user) {
        const cred = await signInAnonymously(auth);
        user = cred.user;
      }
      const inviteSnap = await getDoc(doc(db, 'invites', code));
      if (!inviteSnap.exists()) throw new Error('Geçersiz davet kodu');
      const invite = inviteSnap.data();
      if (invite.used) throw new Error('Bu kod zaten kullanılmış');
      const exp = tsToDate(invite.expiresAt);
      if (exp && Date.now() > exp.getTime()) throw new Error('Kodun süresi dolmuş');
      const familyId = invite.familyId;
      if (!familyId) throw new Error('Aile bilgisi yok');

      await setDoc(
        doc(db, 'users', user.uid),
        {
          uid: user.uid,
          name,
          role: 'child',
          familyId,
          locationSharingEnabled: true,
          createdAt: serverTimestamp(),
          updatedAt: serverTimestamp(),
        },
        { merge: true },
      );

      await updateDoc(doc(db, 'families', familyId), {
        childIds: arrayUnion(user.uid),
        memberIds: arrayUnion(user.uid),
      });

      try {
        await updateDoc(doc(db, 'invites', code), { used: true });
      } catch (_) {}

      await writeLocation(familyId, user.uid, true);

      localStorage.setItem(PREF_FAMILY, familyId);
      localStorage.setItem(PREF_NAME, name);
      localStorage.setItem('aileizi_mode', 'child');
      toast('Aileye katıldın!', 'success');
      onJoined?.();
    } catch (e) {
      err.textContent = describeError(e);
      err.classList.remove('hidden');
    } finally {
      btn.disabled = false;
    }
  };
}

export async function resolveChildSession() {
  const user = auth.currentUser;
  if (!user) return null;
  try {
    const snap = await getDoc(doc(db, 'users', user.uid));
    const data = snap.data();
    if (data?.role === 'child' && data.familyId) {
      return { uid: user.uid, familyId: data.familyId, name: data.name || 'Çocuk', sharing: data.locationSharingEnabled !== false };
    }
  } catch (_) {}
  return null;
}

export function mountChildHome(root, session) {
  let sharing = session.sharing;
  childSessionName = session.name || 'Çocuk';

  root.innerHTML = `
    <div class="app-shell child">
      <header class="topbar">
        <div>
          <h2>${Brand.name}</h2>
          <div class="sub">Merhaba, ${escapeHtml(session.name)}</div>
        </div>
      </header>

      <div class="view child-home-view" id="child-tab-home">
        <div class="row section">
          <div class="meta" id="child-status">${t('loading')}</div>
          <div class="row-actions">
            <button class="btn btn-sm btn-outline" id="toggle-share" type="button">${sharing ? t('sharing_on') : t('sharing_off')}</button>
            <button class="btn btn-sm btn-outline" id="refresh-loc" type="button">Yenile</button>
          </div>
        </div>
        <div class="sos-wrap">
          <button class="sos-btn" id="sos-btn" type="button">SOS</button>
          <p class="meta" style="margin-top:14px">${t('sos_hold')}</p>
        </div>
        <p class="meta" style="margin:12px 16px 0;line-height:1.4">
          Konumun güncel kalması için bu sekmeyi açık bırakın. Uygulama ekranı uyutmaması için açık tutar.
          En güvenilir takip için <b>Aileİzi Çocuk</b> uygulamasını kullanın (arka plan + ekran kapalı).
        </p>
      </div>

      <div class="view child-chat-view hidden" id="child-tab-chat">
        <div class="panel-title"><h2>Mesajlar</h2></div>
        <div class="chat-pane child-chat-full">
          <div class="chat-msgs" id="child-msgs"><div class="empty">Henüz mesaj yok</div></div>
          <div class="chat-compose">
            <input type="file" id="child-file" accept="image/*" hidden />
            <button class="btn btn-sm btn-outline" id="child-img" type="button">Foto</button>
            <input id="child-input" type="text" placeholder="Mesaj yaz…" autocomplete="off" />
            <button class="btn btn-sm btn-primary" id="child-send" type="button">${t('send')}</button>
          </div>
        </div>
      </div>

      <nav class="bottom-nav child-nav" id="child-nav">
        <button type="button" data-tab="home" class="active">
          <span class="ico">🏠</span>
          <span>Ana</span>
        </button>
        <button type="button" data-tab="chat">
          <span class="ico">💬</span>
          <span>Mesaj</span>
        </button>
      </nav>
    </div>
  `;

  const status = () => root.querySelector('#child-status');
  const homeEl = root.querySelector('#child-tab-home');
  const chatEl = root.querySelector('#child-tab-chat');

  const showTab = (next) => {
    homeEl.classList.toggle('hidden', next !== 'home');
    chatEl.classList.toggle('hidden', next !== 'chat');
    root.querySelectorAll('#child-nav button').forEach((b) => {
      b.classList.toggle('active', b.dataset.tab === next);
    });
    if (next === 'chat') openChildChat(session);
  };

  root.querySelector('#child-nav').onclick = (e) => {
    const btn = e.target.closest('button[data-tab]');
    if (btn) showTab(btn.dataset.tab);
  };

  startLocationWatch(session, sharing, (msg) => {
    if (status()) status().textContent = msg;
  });

  root.querySelector('#toggle-share').onclick = async () => {
    sharing = !sharing;
    try {
      await updateDoc(doc(db, 'users', session.uid), {
        locationSharingEnabled: sharing,
        updatedAt: serverTimestamp(),
      });
      root.querySelector('#toggle-share').textContent = sharing
        ? t('sharing_on')
        : t('sharing_off');
      if (sharing) {
        startLocationWatch(session, true, (msg) => {
          if (status()) status().textContent = msg;
        });
      } else {
        stopLocationWatch();
        await setDoc(
          doc(db, 'families', session.familyId, 'locations', session.uid),
          {
            childId: session.uid,
            isOnline: false,
            hasLocation: false,
            timestamp: serverTimestamp(),
          },
          { merge: true },
        );
        if (status()) status().textContent = t('sharing_off');
      }
    } catch (e) {
      toast(describeError(e), 'error');
    }
  };

  root.querySelector('#refresh-loc').onclick = () =>
    writeLocation(session.familyId, session.uid, sharing).then(() =>
      toast('Konum güncellendi', 'success'),
    );

  const sos = root.querySelector('#sos-btn');
  let holdTimer = null;
  let holdStart = 0;
  const startHold = (e) => {
    e.preventDefault();
    holdStart = Date.now();
    sos.classList.add('holding');
    holdTimer = setInterval(async () => {
      if (Date.now() - holdStart >= 3000) {
        clearInterval(holdTimer);
        holdTimer = null;
        sos.classList.remove('holding');
        await sendSos(session);
      }
    }, 200);
  };
  const endHold = () => {
    if (holdTimer) clearInterval(holdTimer);
    holdTimer = null;
    sos.classList.remove('holding');
  };
  sos.addEventListener('mousedown', startHold);
  sos.addEventListener('touchstart', startHold, { passive: false });
  sos.addEventListener('mouseup', endHold);
  sos.addEventListener('mouseleave', endHold);
  sos.addEventListener('touchend', endHold);

  root.querySelector('#child-send').onclick = () => sendChildText(session);
  root.querySelector('#child-input').onkeydown = (e) => {
    if (e.key === 'Enter') sendChildText(session);
  };
  root.querySelector('#child-img').onclick = () =>
    root.querySelector('#child-file').click();
  root.querySelector('#child-file').onchange = (e) => {
    const f = e.target.files?.[0];
    if (f) sendChildImage(session, f);
    e.target.value = '';
  };
}

function startLocationWatch(session, sharing, onStatus) {
  stopLocationWatch();
  if (!sharing || !navigator.geolocation) {
    setKeepAwake('child-loc', false);
    onStatus?.('Konum kullanılamıyor');
    return;
  }
  activeLocSession = session;
  // Ekran/sekme uyumasın — arka planda tarayıcı GPS'i kısıtlar
  setKeepAwake('child-loc', true);
  onStatus?.('Konum alınıyor…');
  watchId = navigator.geolocation.watchPosition(
    async (pos) => {
      const { latitude, longitude, accuracy, speed, heading } = pos.coords;
      const now = Date.now();
      const moved =
        lastLat == null ||
        haversineM(lastLat, lastLng, latitude, longitude) >= 12;
      if (!moved && now - lastWrite < 20000) {
        onStatus?.(
          `Paylaşılıyor · ±${Math.round(accuracy || 0)} m · ${new Date().toLocaleTimeString('tr-TR')}`,
        );
        return;
      }
      if (accuracy && accuracy > 80 && lastLat != null) {
        onStatus?.(`Düşük doğruluk (±${Math.round(accuracy)} m), bekleniyor…`);
        return;
      }
      const prevLat = lastLat;
      const prevLng = lastLng;
      lastLat = latitude;
      lastLng = longitude;
      lastWrite = now;
      await writeLocation(session.familyId, session.uid, true, {
        latitude,
        longitude,
        accuracy: accuracy || 0,
        speed: speed || 0,
        heading: heading || 0,
      });
      try {
        await evaluateGeofences(session, latitude, longitude, prevLat, prevLng);
      } catch (_) {}
      onStatus?.(
        `Paylaşılıyor · ±${Math.round(accuracy || 0)} m · ${new Date().toLocaleTimeString('tr-TR')}`,
      );
    },
    (err) => onStatus?.(`Konum hatası: ${err.message}`),
    { enableHighAccuracy: true, maximumAge: 5000, timeout: 20000 },
  );

  locTimer = setInterval(() => {
    if (document.visibilityState === 'hidden') return;
    if (lastLat != null) {
      writeLocation(session.familyId, session.uid, true, {
        latitude: lastLat,
        longitude: lastLng,
        accuracy: 0,
        speed: 0,
        heading: 0,
      });
    } else {
      writeLocation(session.familyId, session.uid, true).catch(() => {});
    }
  }, 45000);
}

function stopLocationWatch() {
  if (watchId != null) {
    navigator.geolocation.clearWatch(watchId);
    watchId = null;
  }
  if (locTimer) {
    clearInterval(locTimer);
    locTimer = null;
  }
  activeLocSession = null;
  setKeepAwake('child-loc', false);
}

/**
 * Güvenli bölge giriş/çıkış → geofence_events (ebeveyn bildirimi).
 * Kalıcı inside durumu kullanır; önceki konum yoksa sadece durumu başlatır.
 */
async function evaluateGeofences(session, lat, lng, prevLat, prevLng) {
  const snap = await getDocs(
    collection(db, 'families', session.familyId, 'geofences'),
  );
  if (snap.empty) return;

  const childName = session.name || childSessionName || 'Çocuk';
  let changed = false;

  for (const d of snap.docs) {
    const m = d.data();
    const childIds = Array.isArray(m.childIds) ? m.childIds : [];
    if (childIds.length && !childIds.includes(session.uid)) continue;

    const centerLat = Number(m.centerLat);
    const centerLng = Number(m.centerLng);
    const radius = Number(m.radiusMeters) || 200;
    if (!Number.isFinite(centerLat) || !Number.isFinite(centerLng)) continue;

    const notifyExit = m.notifyOnExit !== false;
    const notifyEnter = m.notifyOnEnter !== false;
    const name = m.name || 'Bölge';
    const buffer = Math.min(25, Math.max(10, radius * 0.08));
    const distNow = haversineM(lat, lng, centerLat, centerLng);
    const isInside = distNow <= radius;
    const stateKey = `${session.familyId}_${session.uid}_${d.id}`;

    let wasInside = geoInsideCache[stateKey];
    if (typeof wasInside !== 'boolean') {
      if (
        prevLat != null &&
        prevLng != null &&
        Number.isFinite(prevLat) &&
        Number.isFinite(prevLng)
      ) {
        wasInside = haversineM(prevLat, prevLng, centerLat, centerLng) <= radius;
      } else {
        geoInsideCache[stateKey] = isInside;
        changed = true;
        continue;
      }
    }

    const exited = wasInside && distNow > radius + buffer;
    const entered = !wasInside && distNow < radius - buffer;

    if (exited && notifyExit) {
      await addDoc(
        collection(db, 'families', session.familyId, 'geofence_events'),
        {
          childId: session.uid,
          childName,
          fenceName: name,
          eventType: 'exit',
          latitude: lat,
          longitude: lng,
          timestamp: serverTimestamp(),
          notified: false,
        },
      );
    }
    if (entered && notifyEnter) {
      await addDoc(
        collection(db, 'families', session.familyId, 'geofence_events'),
        {
          childId: session.uid,
          childName,
          fenceName: name,
          eventType: 'enter',
          latitude: lat,
          longitude: lng,
          timestamp: serverTimestamp(),
          notified: false,
        },
      );
    }

    const nextInside = exited ? false : entered ? true : wasInside;
    if (geoInsideCache[stateKey] !== nextInside) {
      geoInsideCache[stateKey] = nextInside;
      changed = true;
    }
    // Stabil bölgede de güncel durumu tut
    if (!exited && !entered && geoInsideCache[stateKey] !== isInside) {
      // Histerezis bandındaysa eski durumu koru
      if (distNow <= radius - buffer || distNow >= radius + buffer) {
        geoInsideCache[stateKey] = isInside;
        changed = true;
      }
    }
  }

  if (changed) persistGeoState();
}

async function writeLocation(familyId, childId, sharing, coords) {
  let c = coords;
  if (!c) {
    c = await new Promise((resolve, reject) => {
      navigator.geolocation.getCurrentPosition(
        (p) =>
          resolve({
            latitude: p.coords.latitude,
            longitude: p.coords.longitude,
            accuracy: p.coords.accuracy || 0,
            speed: p.coords.speed || 0,
            heading: p.coords.heading || 0,
          }),
        reject,
        { enableHighAccuracy: true, timeout: 15000 },
      );
    }).catch(() => null);
  }
  if (!c) return;

  const speedKmh = (c.speed || 0) * 3.6;
  const payload = {
    childId,
    latitude: c.latitude,
    longitude: c.longitude,
    accuracy: c.accuracy || 0,
    speed: c.speed || 0,
    speedKmh,
    heading: c.heading || 0,
    batteryLevel: null,
    timestamp: serverTimestamp(),
    isOnline: !!sharing,
    hasLocation: true,
    source: 'phone',
  };

  await setDoc(doc(db, 'families', familyId, 'locations', childId), payload, {
    merge: true,
  });

  await setDoc(
    doc(db, 'families', familyId, 'device_status', childId),
    {
      lastSeen: serverTimestamp(),
      isOnline: !!sharing,
      locationSharingEnabled: !!sharing,
      latitude: c.latitude,
      longitude: c.longitude,
      speedKmh,
    },
    { merge: true },
  );

  // history sparingly
  if (!writeLocation._lastHist || Date.now() - writeLocation._lastHist > 5 * 60 * 1000) {
    writeLocation._lastHist = Date.now();
    await addDoc(
      collection(db, 'families', familyId, 'location_history', childId, 'entries'),
      payload,
    );
  }
}

async function sendSos(session) {
  try {
    let lat = lastLat || 0;
    let lng = lastLng || 0;
    let hasLocation = lastLat != null;
    if (!hasLocation && navigator.geolocation) {
      try {
        const p = await new Promise((res, rej) =>
          navigator.geolocation.getCurrentPosition(res, rej, {
            enableHighAccuracy: true,
            timeout: 8000,
          }),
        );
        lat = p.coords.latitude;
        lng = p.coords.longitude;
        hasLocation = true;
      } catch (_) {}
    }
    await addDoc(collection(db, 'families', session.familyId, 'sos_events'), {
      childId: session.uid,
      childName: session.name,
      latitude: lat,
      longitude: lng,
      hasLocation,
      timestamp: serverTimestamp(),
      acknowledged: false,
    });
    toast('SOS gönderildi!', 'success');
  } catch (e) {
    toast(describeError(e), 'error');
  }
}

function openChildChat(session) {
  if (chatUnsub) chatUnsub();
  const qy = collection(
    db,
    'families',
    session.familyId,
    'chats',
    session.uid,
    'messages',
  );
  chatUnsub = onSnapshot(qy, async (snap) => {
    const msgs = [];
    snap.forEach((d) => msgs.push({ id: d.id, ...d.data() }));
    msgs.sort(
      (a, b) =>
        (tsToDate(a.createdAt)?.getTime() || 0) -
        (tsToDate(b.createdAt)?.getTime() || 0),
    );
    const box = document.getElementById('child-msgs');
    if (!box) return;
    if (!msgs.length) {
      box.innerHTML = `<div class="empty">Henüz mesaj yok. Aşağıdan yazabilirsin.</div>`;
      return;
    }
    box.innerHTML = msgs
      .slice(-100)
      .map((m) => {
        const role = m.senderRole === 'parent' ? 'parent' : 'child';
        let body = escapeHtml(m.text || '');
        if (m.type === 'image' && m.imageUrl) {
          body += `<img src="${escapeHtml(m.imageUrl)}" alt="" />`;
        }
        if (m.type === 'location' && m.latitude != null) {
          body += `<div class="meta">Konum: ${Number(m.latitude).toFixed(5)}, ${Number(m.longitude).toFixed(5)}</div>`;
        }
        return `<div class="bubble ${role}">${body}<div class="meta" style="opacity:.7;font-size:.7rem;margin-top:4px">${fmtTime(tsToDate(m.createdAt))}</div></div>`;
      })
      .join('');
    box.scrollTop = box.scrollHeight;
  });
}

async function sendChildText(session) {
  const input = document.getElementById('child-input');
  const text = input?.value?.trim();
  if (!text) return;
  try {
    await addDoc(
      collection(db, 'families', session.familyId, 'chats', session.uid, 'messages'),
      {
        childId: session.uid,
        senderId: session.uid,
        senderRole: 'child',
        type: 'text',
        text,
        createdAt: serverTimestamp(),
        readByParent: false,
        readByChild: true,
      },
    );
    input.value = '';
  } catch (e) {
    toast(describeError(e), 'error');
  }
}

async function sendChildImage(session, file) {
  if (file.size > 7 * 1024 * 1024) {
    toast('Dosya çok büyük', 'error');
    return;
  }
  try {
    const name = `${Date.now()}_${session.uid}.jpg`;
    const ref = storageRef(
      storage,
      `families/${session.familyId}/chats/${session.uid}/${name}`,
    );
    await uploadBytes(ref, file, { contentType: file.type || 'image/jpeg' });
    const url = await getDownloadURL(ref);
    await addDoc(
      collection(db, 'families', session.familyId, 'chats', session.uid, 'messages'),
      {
        childId: session.uid,
        senderId: session.uid,
        senderRole: 'child',
        type: 'image',
        text: '',
        imageUrl: url,
        createdAt: serverTimestamp(),
        readByParent: false,
        readByChild: true,
      },
    );
  } catch (e) {
    toast(describeError(e), 'error');
  }
}

export function unmountChild() {
  stopLocationWatch();
  if (chatUnsub) chatUnsub();
  chatUnsub = null;
}
