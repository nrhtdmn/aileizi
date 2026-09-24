import {
  auth,
  db,
  collection,
  doc,
  onSnapshot,
  updateDoc,
  query,
  where,
} from './firebase-app.js';
import { notifyBrowser, toast } from './utils.js';

const PREF_KEY = 'aileizi_alert_prefs';

const defaultPrefs = {
  sos: true,
  chat: true,
  geofence: true,
  route: true,
  sound: true,
  batteryLow: true,
};

let stoppers = [];
let startedFor = null;
const seenSos = new Set();
const seenChat = new Set();
const seenGeo = new Set();
const seenRoute = new Set();
let audioCtx = null;

export function getAlertPrefs() {
  try {
    return { ...defaultPrefs, ...JSON.parse(localStorage.getItem(PREF_KEY) || '{}') };
  } catch {
    return { ...defaultPrefs };
  }
}

export function setAlertPrefs(partial) {
  const next = { ...getAlertPrefs(), ...partial };
  localStorage.setItem(PREF_KEY, JSON.stringify(next));
  return next;
}

async function ensurePermission() {
  if (!('Notification' in window)) return false;
  if (Notification.permission === 'granted') return true;
  if (Notification.permission === 'denied') return false;
  const r = await Notification.requestPermission();
  return r === 'granted';
}

function beep() {
  const prefs = getAlertPrefs();
  if (!prefs.sound) return;
  try {
    audioCtx = audioCtx || new (window.AudioContext || window.webkitAudioContext)();
    const o = audioCtx.createOscillator();
    const g = audioCtx.createGain();
    o.type = 'sine';
    o.frequency.value = 880;
    g.gain.value = 0.04;
    o.connect(g);
    g.connect(audioCtx.destination);
    o.start();
    setTimeout(() => {
      o.stop();
    }, 180);
  } catch (_) {}
}

async function alertNow(title, body, tag, goTab) {
  const prefs = getAlertPrefs();
  toast(`${title}: ${body}`, 'error');
  beep();
  await ensurePermission();
  await notifyBrowser(title, body, tag);
  if (typeof goTab === 'number' && window.__aileiziGoTab) {
    // soft hint only — don't force navigate every time
  }
  document.dispatchEvent(
    new CustomEvent('aileizi-alert', { detail: { title, body, tag, goTab } }),
  );
}

export async function startParentAlerts() {
  const uid = auth.currentUser?.uid;
  if (!uid || startedFor === uid) return;
  stopParentAlerts();
  startedFor = uid;
  await ensurePermission();

  const prefs = () => getAlertPrefs();

  // SOS — unacknowledged (skip existing on first load)
  let sosReady = false;
  const s1 = onSnapshot(
    collection(db, 'families', uid, 'sos_events'),
    (snap) => {
      if (!sosReady) {
        snap.forEach((d) => seenSos.add(d.id));
        sosReady = true;
        return;
      }
      if (!prefs().sos) return;
      snap.docChanges().forEach((ch) => {
        if (ch.type !== 'added' && ch.type !== 'modified') return;
        const d = ch.doc.data();
        const id = ch.doc.id;
        if (d.acknowledged) return;
        if (seenSos.has(id) && ch.type === 'added') return;
        if (ch.type === 'modified' && seenSos.has(id)) {
          // reactivated
        }
        if (seenSos.has(`alerted-${id}`) && ch.type === 'modified') return;
        seenSos.add(id);
        seenSos.add(`alerted-${id}`);
        alertNow(
          'SOS!',
          `${d.childName || 'Çocuk'} yardım istiyor`,
          `sos-${id}`,
          1,
        );
      });
    },
    () => {},
  );
  stoppers.push(s1);

  // Geofence events (enter/exit)
  let geoReady = false;
  const s2 = onSnapshot(
    query(
      collection(db, 'families', uid, 'geofence_events'),
      where('notified', '==', false),
    ),
    (snap) => {
      if (!geoReady) {
        snap.forEach((d) => seenGeo.add(d.id));
        geoReady = true;
        // still mark notified so they don't pile up? leave for parent to see once
        return;
      }
      if (!prefs().geofence) return;
      snap.docChanges().forEach(async (ch) => {
        if (ch.type !== 'added') return;
        const id = ch.doc.id;
        if (seenGeo.has(id)) return;
        seenGeo.add(id);
        const e = ch.doc.data();
        const tip = e.eventType === 'exit' ? 'çıktı' : 'girdi';
        await alertNow(
          'Güvenli bölge',
          `${e.childName || 'Çocuk'} «${e.fenceName || 'bölge'}» bölgesine ${tip}`,
          `geo-${id}`,
          4,
        );
        try {
          await updateDoc(doc(db, 'families', uid, 'geofence_events', id), {
            notified: true,
          });
        } catch (_) {}
      });
    },
    () => {},
  );
  stoppers.push(s2);

  // Route deviate / return
  let routeReady = false;
  const s3 = onSnapshot(
    query(
      collection(db, 'families', uid, 'route_events'),
      where('notified', '==', false),
    ),
    (snap) => {
      if (!routeReady) {
        snap.forEach((d) => seenRoute.add(d.id));
        routeReady = true;
        return;
      }
      if (!prefs().route) return;
      snap.docChanges().forEach(async (ch) => {
        if (ch.type !== 'added') return;
        const id = ch.doc.id;
        if (seenRoute.has(id)) return;
        seenRoute.add(id);
        const e = ch.doc.data();
        const tip = e.eventType === 'return' ? 'rotaya döndü' : 'rotadan saptı';
        await alertNow(
          'Rota uyarısı',
          `${e.childName || 'Çocuk'} «${e.routeName || 'rota'}» — ${tip}`,
          `route-${id}`,
          3,
        );
        try {
          await updateDoc(doc(db, 'families', uid, 'route_events', id), {
            notified: true,
          });
        } catch (_) {}
      });
    },
    () => {},
  );
  stoppers.push(s3);

  // Live chat listeners per child (instant)
  const chatStops = [];
  const sFam = onSnapshot(doc(db, 'families', uid), (fam) => {
    chatStops.forEach((u) => u());
    chatStops.length = 0;
    const childIds = fam.data()?.childIds || [];
    for (const childId of childIds) {
      let chatReady = false;
      const u = onSnapshot(
        query(
          collection(db, 'families', uid, 'chats', childId, 'messages'),
          where('readByParent', '==', false),
        ),
        (snap) => {
          if (!chatReady) {
            snap.forEach((d) => seenChat.add(d.id));
            chatReady = true;
            return;
          }
          if (!prefs().chat) return;
          snap.docChanges().forEach((ch) => {
            if (ch.type !== 'added') return;
            const m = ch.doc.data();
            if (m.senderRole !== 'child') return;
            const key = ch.doc.id;
            if (seenChat.has(key)) return;
            seenChat.add(key);
            alertNow(
              'Yeni mesaj',
              m.text || (m.type === 'image' ? 'Fotoğraf' : 'Mesaj'),
              `chat-${key}`,
              2,
            );
          });
        },
        () => {},
      );
      chatStops.push(u);
    }
  });
  stoppers.push(() => {
    sFam();
    chatStops.forEach((u) => u());
  });

  // Battery low via device_status
  const s5 = onSnapshot(collection(db, 'families', uid, 'device_status'), (snap) => {
    if (!prefs().batteryLow) return;
    snap.docChanges().forEach((ch) => {
      const m = ch.doc.data();
      const bat = Number(m.batteryLevel);
      if (!Number.isFinite(bat) || bat > 15) return;
      const key = `bat-${ch.doc.id}-${Math.floor(bat / 5)}`;
      if (seenChat.has(key)) return;
      seenChat.add(key);
      alertNow('Düşük pil', `Çocuk cihazı %${bat}`, key, 0);
    });
  });
  stoppers.push(s5);
}

export function stopParentAlerts() {
  stoppers.forEach((s) => {
    try {
      if (typeof s === 'function') s();
      else s();
    } catch (_) {}
  });
  stoppers = [];
  startedFor = null;
}
