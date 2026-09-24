import {
  auth,
  db,
  doc,
  setDoc,
  getDoc,
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

const PREF_FAMILY = 'aileizi_child_family';
const PREF_NAME = 'aileizi_child_name';

let watchId = null;
let chatUnsub = null;
let locTimer = null;
let lastLat = null;
let lastLng = null;
let lastWrite = 0;

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
  root.innerHTML = `
    <div class="app-shell child">
      <header class="topbar">
        <div>
          <h2>${Brand.name}</h2>
          <div class="sub">Merhaba, ${escapeHtml(session.name)}</div>
        </div>
        <button class="btn btn-sm btn-outline" id="child-chat-btn" style="background:rgba(255,255,255,.15);color:#fff;border-color:transparent">Mesajlar</button>
      </header>
      <div class="view" id="child-main">
        <div class="row section">
          <div class="meta" id="child-status">${t('loading')}</div>
          <div class="row-actions">
            <button class="btn btn-sm btn-outline" id="toggle-share">${sharing ? t('sharing_on') : t('sharing_off')}</button>
            <button class="btn btn-sm btn-outline" id="refresh-loc">Yenile</button>
          </div>
        </div>
        <div class="sos-wrap">
          <button class="sos-btn" id="sos-btn">SOS</button>
          <p class="meta" style="margin-top:14px">${t('sos_hold')}</p>
        </div>
        <div id="child-chat-panel" class="hidden" style="margin-top:12px">
          <div class="chat-pane">
            <div class="chat-msgs" id="child-msgs"></div>
            <div class="chat-compose">
              <input type="file" id="child-file" accept="image/*" hidden />
              <button class="btn btn-sm btn-outline" id="child-img" type="button">Foto</button>
              <input id="child-input" type="text" placeholder="Mesaj…" />
              <button class="btn btn-sm btn-primary" id="child-send" type="button">${t('send')}</button>
            </div>
          </div>
        </div>
      </div>
    </div>
  `;

  const status = () => root.querySelector('#child-status');

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

  // SOS hold 3s
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

  root.querySelector('#child-chat-btn').onclick = () => {
    const panel = root.querySelector('#child-chat-panel');
    panel.classList.toggle('hidden');
    if (!panel.classList.contains('hidden')) openChildChat(session);
  };
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
    onStatus?.('Konum kullanılamıyor');
    return;
  }
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
      onStatus?.(
        `Paylaşılıyor · ±${Math.round(accuracy || 0)} m · ${new Date().toLocaleTimeString('tr-TR')}`,
      );
    },
    (err) => onStatus?.(`Konum hatası: ${err.message}`),
    { enableHighAccuracy: true, maximumAge: 5000, timeout: 20000 },
  );

  // heartbeat
  locTimer = setInterval(() => {
    if (lastLat != null) {
      writeLocation(session.familyId, session.uid, true, {
        latitude: lastLat,
        longitude: lastLng,
        accuracy: 0,
        speed: 0,
        heading: 0,
      });
    }
  }, 90000);
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
    box.innerHTML = msgs
      .slice(-100)
      .map((m) => {
        const role = m.senderRole === 'parent' ? 'parent' : 'child';
        let body = escapeHtml(m.text || '');
        if (m.type === 'image' && m.imageUrl) {
          body += `<img src="${escapeHtml(m.imageUrl)}" alt="" />`;
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
