/**
 * Ebeveyn tarafında konum güncellemelerinden güvenli bölge giriş/çıkış üret.
 * Çocuk uygulaması olay yazmasa bile bildirim çalışır.
 */
import {
  db,
  collection,
  doc,
  getDoc,
  onSnapshot,
  addDoc,
  serverTimestamp,
} from './firebase-app.js';
import { haversineM } from './utils.js';

const PREF_INSIDE = 'aileizi_parent_geo_inside';

/** @type {Map<string, {lat:number, lng:number}>} */
const prevLoc = new Map();
/** @type {Record<string, boolean>} */
let insideState = {};
/** @type {Array<object>} */
let fencesCache = [];
/** @type {Map<string, string>} */
const childNames = new Map();
/** First snapshot per child — seed only, no events */
const seeded = new Set();
let stopFences = null;
let stopLoc = null;
let stopFam = null;
let activeFid = null;

try {
  insideState = JSON.parse(localStorage.getItem(PREF_INSIDE) || '{}') || {};
} catch (_) {
  insideState = {};
}

function persistInside() {
  try {
    localStorage.setItem(PREF_INSIDE, JSON.stringify(insideState));
  } catch (_) {}
}

function asNum(v) {
  const n = typeof v === 'number' ? v : Number(v);
  return Number.isFinite(n) ? n : null;
}

function fenceCenter(g) {
  const lat = asNum(g.centerLat ?? g.lat);
  const lng = asNum(g.centerLng ?? g.lng);
  if (lat == null || lng == null) return null;
  if (Math.abs(lat) < 0.00001 && Math.abs(lng) < 0.00001) return null;
  return { lat, lng };
}

async function writeEvent(fid, payload) {
  await addDoc(collection(db, 'families', fid, 'geofence_events'), {
    ...payload,
    timestamp: serverTimestamp(),
    notified: false,
  });
}

async function resolveName(childId, fallback) {
  if (childNames.has(childId)) return childNames.get(childId);
  try {
    const snap = await getDoc(doc(db, 'users', childId));
    const name = snap.data()?.name;
    if (name) {
      childNames.set(childId, name);
      return name;
    }
  } catch (_) {}
  return fallback || childId.slice(0, 6);
}

/**
 * @param {string} fid
 * @param {string} childId
 * @param {string} childName
 * @param {number} lat
 * @param {number} lng
 */
async function evaluateChild(fid, childId, childName, lat, lng) {
  if (!fencesCache.length) return;
  const prev = prevLoc.get(childId);
  let changed = false;

  for (const g of fencesCache) {
    const childIds = Array.isArray(g.childIds) ? g.childIds : [];
    if (childIds.length && !childIds.includes(childId)) continue;

    const center = fenceCenter(g);
    if (!center) continue;

    const radius = asNum(g.radiusMeters) || 200;
    const notifyExit = g.notifyOnExit !== false;
    const notifyEnter = g.notifyOnEnter !== false;
    const buffer = Math.min(25, Math.max(8, radius * 0.06));
    const distNow = haversineM(lat, lng, center.lat, center.lng);
    const isInside = distNow <= radius;
    const key = `${fid}_${childId}_${g.id}`;

    let wasInside = insideState[key];
    if (typeof wasInside !== 'boolean') {
      if (prev) {
        wasInside =
          haversineM(prev.lat, prev.lng, center.lat, center.lng) <= radius;
      } else {
        insideState[key] = isInside;
        changed = true;
        continue;
      }
    }

    const exited = wasInside && distNow > radius + buffer;
    const entered = !wasInside && distNow < Math.max(0, radius - buffer);

    if (exited && notifyExit) {
      await writeEvent(fid, {
        childId,
        childName,
        fenceName: g.name || 'Bölge',
        eventType: 'exit',
        latitude: lat,
        longitude: lng,
      });
      insideState[key] = false;
      changed = true;
    } else if (entered && notifyEnter) {
      await writeEvent(fid, {
        childId,
        childName,
        fenceName: g.name || 'Bölge',
        eventType: 'enter',
        latitude: lat,
        longitude: lng,
      });
      insideState[key] = true;
      changed = true;
    } else if (distNow <= radius - buffer || distNow >= radius + buffer) {
      if (insideState[key] !== isInside) {
        insideState[key] = isInside;
        changed = true;
      }
    }
  }

  prevLoc.set(childId, { lat, lng });
  if (changed) persistInside();
}

/**
 * @param {string} familyId parent uid
 */
export function startParentGeofenceWatch(familyId) {
  if (!familyId) return;
  if (activeFid === familyId && stopLoc) return;
  stopParentGeofenceWatch();
  activeFid = familyId;

  stopFences = onSnapshot(
    collection(db, 'families', familyId, 'geofences'),
    (snap) => {
      fencesCache = [];
      snap.forEach((d) => fencesCache.push({ id: d.id, ...d.data() }));
    },
    () => {},
  );

  stopFam = onSnapshot(
    doc(db, 'families', familyId),
    (fam) => {
      const ids = fam.data()?.childIds || [];
      ids.forEach((uid) => {
        if (!childNames.has(uid)) resolveName(uid).catch(() => {});
      });
    },
    () => {},
  );

  stopLoc = onSnapshot(
    collection(db, 'families', familyId, 'locations'),
    (snap) => {
      snap.docChanges().forEach(async (ch) => {
        if (ch.type !== 'added' && ch.type !== 'modified') return;
        const m = ch.doc.data();
        const childId = ch.doc.id;
        const lat = asNum(m.latitude);
        const lng = asNum(m.longitude);
        if (lat == null || lng == null) return;
        if (m.hasLocation === false) return;
        if (lat === 0 && lng === 0) return;

        const name = await resolveName(childId, m.childName);

        if (!seeded.has(childId)) {
          seeded.add(childId);
          prevLoc.set(childId, { lat, lng });
          for (const g of fencesCache) {
            const childIds = Array.isArray(g.childIds) ? g.childIds : [];
            if (childIds.length && !childIds.includes(childId)) continue;
            const center = fenceCenter(g);
            if (!center) continue;
            const radius = asNum(g.radiusMeters) || 200;
            const key = `${familyId}_${childId}_${g.id}`;
            if (typeof insideState[key] !== 'boolean') {
              insideState[key] =
                haversineM(lat, lng, center.lat, center.lng) <= radius;
            }
          }
          persistInside();
          return;
        }

        const prev = prevLoc.get(childId);
        if (prev && haversineM(prev.lat, prev.lng, lat, lng) < 3) return;

        try {
          await evaluateChild(familyId, childId, name, lat, lng);
        } catch (e) {
          console.warn('[geofence]', e);
        }
      });
    },
    () => {},
  );
}

export function stopParentGeofenceWatch() {
  try {
    stopFences?.();
  } catch (_) {}
  try {
    stopLoc?.();
  } catch (_) {}
  try {
    stopFam?.();
  } catch (_) {}
  stopFences = null;
  stopLoc = null;
  stopFam = null;
  activeFid = null;
  prevLoc.clear();
  seeded.clear();
}
