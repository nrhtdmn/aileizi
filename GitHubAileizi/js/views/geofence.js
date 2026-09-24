import {
  auth,
  db,
  collection,
  doc,
  onSnapshot,
  addDoc,
  updateDoc,
  deleteDoc,
  getDoc,
  ensureParentProfile,
  tsToDate,
} from '../firebase-app.js';
import { DEFAULT_MAP } from '../config.js';
import { t, fmtTime, toast, escapeHtml, notifyBrowser } from '../utils.js';

let map;
let layer;
let unsubFences;
let unsubEvents;
let pendingCenter = null;
let circlePreview;

export function mountGeofence(root) {
  root.innerHTML = `
    <div class="view geo-view">
      <div class="map-bar">
        <span style="font-weight:800;font-size:0.95rem;flex:1">${t('nav_geofence')}</span>
        <button class="btn btn-sm btn-primary" id="geo-add" type="button">Ekle</button>
      </div>
      <div class="geo-layout">
        <div id="geofence-map"></div>
        <div class="geo-side">
          <div class="list" id="geo-list"></div>
          <h3 style="margin:14px 0 8px;font-size:0.9rem">Son olaylar</h3>
          <div class="list" id="geo-events"></div>
        </div>
      </div>
    </div>
  `;

  map = L.map('geofence-map').setView([DEFAULT_MAP.lat, DEFAULT_MAP.lng], 12);
  L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', {
    attribution: '&copy; OSM',
  }).addTo(map);
  layer = L.layerGroup().addTo(map);

  map.on('click', (ev) => {
    pendingCenter = { lat: ev.latlng.lat, lng: ev.latlng.lng };
    if (circlePreview) map.removeLayer(circlePreview);
    circlePreview = L.circle([pendingCenter.lat, pendingCenter.lng], {
      radius: 200,
      color: '#2d6a4f',
    }).addTo(map);
    toast('Merkez seçildi — Ekle’ye bas');
  });

  const fid = auth.currentUser?.uid;
  if (!fid) return;

  unsubFences = onSnapshot(collection(db, 'families', fid, 'geofences'), (snap) => {
    layer.clearLayers();
    const list = [];
    snap.forEach((d) => list.push({ id: d.id, ...d.data() }));
    renderFences(list);
    list.forEach((g) => {
      if (g.centerLat == null) return;
      L.circle([g.centerLat, g.centerLng], {
        radius: g.radiusMeters || 200,
        color: '#1b4332',
        fillOpacity: 0.12,
      })
        .bindPopup(escapeHtml(g.name || 'Bölge'))
        .addTo(layer);
    });
  });

  unsubEvents = onSnapshot(
    collection(db, 'families', fid, 'geofence_events'),
    (snap) => {
      const list = [];
      snap.forEach((d) => list.push({ id: d.id, ...d.data() }));
      list.sort(
        (a, b) =>
          (tsToDate(b.timestamp)?.getTime() || 0) -
          (tsToDate(a.timestamp)?.getTime() || 0),
      );
      const recent = list.slice(0, 15);
      const el = document.getElementById('geo-events');
      if (!el) return;
      el.innerHTML = recent.length
        ? recent
            .map(
              (e) => `
          <div class="row">
            <h3>${escapeHtml(e.childName || '')} — ${escapeHtml(e.fenceName || '')}</h3>
            <div class="meta"><span class="badge ${e.eventType === 'exit' ? 'warn' : ''}">${e.eventType || '?'}</span> ${fmtTime(tsToDate(e.timestamp))}</div>
          </div>`,
            )
            .join('')
        : `<div class="empty">Olay yok</div>`;

      recent
        .filter((e) => e.notified === false)
        .forEach((e) => {
          notifyBrowser(
            'Güvenli bölge',
            `${e.childName}: ${e.eventType} — ${e.fenceName}`,
            e.id,
          );
          updateDoc(doc(db, 'families', fid, 'geofence_events', e.id), {
            notified: true,
          }).catch(() => {});
        });
    },
  );

  root.querySelector('#geo-add').onclick = () => createFence();
  setTimeout(() => map.invalidateSize(), 120);
}

function renderFences(list) {
  const el = document.getElementById('geo-list');
  if (!el) return;
  if (!list.length) {
    el.innerHTML = `<div class="empty">Haritaya tıkla, sonra Ekle</div>`;
    return;
  }
  el.innerHTML = list
    .map(
      (g) => `
    <div class="row">
      <h3>${escapeHtml(g.name || 'Bölge')}</h3>
      <div class="meta">${Math.round(g.radiusMeters || 0)} m</div>
      <div class="row-actions">
        <button class="btn btn-sm btn-outline" data-focus="${g.id}">Göster</button>
        <button class="btn btn-sm btn-outline" data-del="${g.id}">${t('delete')}</button>
      </div>
    </div>`,
    )
    .join('');

  el.querySelectorAll('[data-del]').forEach((b) => {
    b.onclick = async () => {
      if (!confirm('Silinsin mi?')) return;
      try {
        await deleteDoc(
          doc(db, 'families', auth.currentUser.uid, 'geofences', b.dataset.del),
        );
      } catch (e) {
        toast(e.message, 'error');
      }
    };
  });
  el.querySelectorAll('[data-focus]').forEach((b) => {
    b.onclick = () => {
      const g = list.find((x) => x.id === b.dataset.focus);
      if (g && map) map.setView([g.centerLat, g.centerLng], 15);
    };
  });
}

async function createFence() {
  if (!pendingCenter) {
    toast('Önce haritaya tıkla', 'error');
    return;
  }
  const name = prompt('Bölge adı', 'Ev')?.trim();
  if (!name) return;
  const radius = Number(prompt('Yarıçap (metre)', '200')) || 200;
  try {
    await ensureParentProfile(auth.currentUser);
    await addDoc(collection(db, 'families', auth.currentUser.uid, 'geofences'), {
      name,
      centerLat: pendingCenter.lat,
      centerLng: pendingCenter.lng,
      radiusMeters: radius,
      childIds: [],
      notifyOnEnter: true,
      notifyOnExit: true,
    });
    toast('Eklendi', 'success');
    pendingCenter = null;
    if (circlePreview) {
      map.removeLayer(circlePreview);
      circlePreview = null;
    }
  } catch (e) {
    toast(e.message, 'error');
  }
}

export function unmountGeofence() {
  if (unsubFences) unsubFences();
  if (unsubEvents) unsubEvents();
  unsubFences = unsubEvents = null;
  if (map) {
    map.remove();
    map = null;
  }
}
