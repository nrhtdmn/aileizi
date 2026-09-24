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
} from '../firebase-app.js';
import { DEFAULT_MAP } from '../config.js';
import { t, toast, escapeHtml } from '../utils.js';

let map;
let layer;
let unsubFences;
let unsubFam;
let children = [];
let pendingCenter = null;
let circlePreview;
let streetLayer;
let hybridBase;
let hybridLabels;
let mapMode = localStorage.getItem('aileizi_map_mode') || 'hybrid';
let editingId = null;

function asNum(v) {
  if (typeof v === 'number' && Number.isFinite(v)) return v;
  if (typeof v === 'string' && v.trim() !== '') {
    const n = Number(v);
    return Number.isFinite(n) ? n : null;
  }
  return null;
}

function applyMapMode() {
  if (!map) return;
  map.removeLayer(streetLayer);
  map.removeLayer(hybridBase);
  map.removeLayer(hybridLabels);
  if (mapMode === 'hybrid') {
    hybridBase.addTo(map);
    hybridLabels.addTo(map);
  } else {
    streetLayer.addTo(map);
  }
  const btn = document.getElementById('geo-map-type');
  if (btn) btn.textContent = mapMode === 'hybrid' ? 'Harita' : 'Hibrit';
}

export function mountGeofence(root) {
  root.innerHTML = `
    <div class="view map-view">
      <div class="map-bar">
        <span style="font-weight:800;flex:1">Güvenli bölgeler</span>
        <div class="map-actions">
          <button class="btn btn-sm btn-outline" id="geo-map-type" type="button">Hibrit</button>
          <button class="btn btn-sm btn-primary" id="geo-add" type="button">Ekle</button>
        </div>
      </div>
      <div class="map-status" id="geo-status">Haritaya tıkla → merkez seç → Ekle</div>
      <div id="geofence-map"></div>
      <div class="map-manage" id="geo-list"></div>
    </div>
  `;

  map = L.map('geofence-map', { zoomControl: false }).setView(
    [DEFAULT_MAP.lat, DEFAULT_MAP.lng],
    12,
  );
  L.control.zoom({ position: 'bottomright' }).addTo(map);

  streetLayer = L.tileLayer(
    'https://{s}.basemaps.cartocdn.com/rastertiles/voyager/{z}/{x}/{y}{r}.png',
    { maxZoom: 20, attribution: '&copy; OSM &copy; CARTO' },
  );
  hybridBase = L.tileLayer(
    'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}',
    { maxZoom: 19, attribution: 'Esri' },
  );
  hybridLabels = L.tileLayer(
    'https://server.arcgisonline.com/ArcGIS/rest/services/Reference/World_Boundaries_and_Places/MapServer/tile/{z}/{y}/{x}',
    { maxZoom: 19, opacity: 0.95 },
  );
  applyMapMode();
  layer = L.layerGroup().addTo(map);

  map.on('click', (ev) => {
    pendingCenter = { lat: ev.latlng.lat, lng: ev.latlng.lng };
    if (circlePreview) map.removeLayer(circlePreview);
    circlePreview = L.circle([pendingCenter.lat, pendingCenter.lng], {
      radius: 200,
      color: '#2d6a4f',
      fillOpacity: 0.15,
    }).addTo(map);
    document.getElementById('geo-status').textContent =
      'Merkez seçildi — Ekle ile kaydet';
  });

  const fid = auth.currentUser?.uid;
  if (!fid) return;

  unsubFam = onSnapshot(doc(db, 'families', fid), async (fam) => {
    const ids = fam.data()?.childIds || [];
    children = [];
    for (const id of ids) {
      try {
        const u = await getDoc(doc(db, 'users', id));
        children.push({ uid: id, name: u.data()?.name || id.slice(0, 6) });
      } catch {
        children.push({ uid: id, name: id.slice(0, 6) });
      }
    }
  });

  unsubFences = onSnapshot(collection(db, 'families', fid, 'geofences'), (snap) => {
    layer.clearLayers();
    const list = [];
    snap.forEach((d) => list.push({ id: d.id, ...d.data() }));
    renderList(list);
    const bounds = [];
    list.forEach((g) => {
      const lat = asNum(g.centerLat);
      const lng = asNum(g.centerLng);
      if (lat == null || lng == null) return;
      const c = L.circle([lat, lng], {
        radius: g.radiusMeters || 200,
        color: '#1b4332',
        fillOpacity: 0.12,
      })
        .bindPopup(escapeHtml(g.name || 'Bölge'))
        .addTo(layer);
      bounds.push(c.getBounds());
    });
    if (bounds.length) {
      const b = bounds[0];
      bounds.slice(1).forEach((x) => b.extend(x));
      map.fitBounds(b.pad(0.2));
    }
  });

  root.querySelector('#geo-map-type').onclick = () => {
    mapMode = mapMode === 'hybrid' ? 'street' : 'hybrid';
    localStorage.setItem('aileizi_map_mode', mapMode);
    applyMapMode();
  };
  root.querySelector('#geo-add').onclick = () => createFence();
  setTimeout(() => map.invalidateSize(), 150);
}

function renderList(list) {
  const el = document.getElementById('geo-list');
  if (!el) return;
  if (!list.length) {
    el.innerHTML = `<div class="empty" style="padding:12px">Bölge yok</div>`;
    return;
  }
  el.innerHTML = list
    .map(
      (g) => `
    <div class="row" style="margin:8px 10px">
      <h3>${escapeHtml(g.name || 'Bölge')}</h3>
      <div class="meta">${Math.round(g.radiusMeters || 0)} m · giriş:${g.notifyOnEnter !== false ? 'açık' : 'kapalı'} · çıkış:${g.notifyOnExit !== false ? 'açık' : 'kapalı'}</div>
      <div class="row-actions">
        <button class="btn btn-sm btn-outline" data-focus="${g.id}">Göster</button>
        <button class="btn btn-sm btn-outline" data-edit="${g.id}">Düzenle</button>
        <button class="btn btn-sm btn-outline" data-del="${g.id}">${t('delete')}</button>
      </div>
    </div>`,
    )
    .join('');

  el.querySelectorAll('[data-focus]').forEach((b) => {
    b.onclick = () => {
      const g = list.find((x) => x.id === b.dataset.focus);
      if (g && map) map.setView([g.centerLat, g.centerLng], 15);
    };
  });
  el.querySelectorAll('[data-del]').forEach((b) => {
    b.onclick = async () => {
      if (!confirm('Bölge silinsin mi?')) return;
      try {
        await deleteDoc(
          doc(db, 'families', auth.currentUser.uid, 'geofences', b.dataset.del),
        );
      } catch (e) {
        toast(e.message, 'error');
      }
    };
  });
  el.querySelectorAll('[data-edit]').forEach((b) => {
    b.onclick = async () => {
      const g = list.find((x) => x.id === b.dataset.edit);
      if (!g) return;
      const name = prompt('Ad', g.name || '')?.trim();
      if (!name) return;
      const radius = Number(prompt('Yarıçap (m)', String(g.radiusMeters || 200)));
      if (!Number.isFinite(radius) || radius < 30) return;
      const enter = confirm('Girişte bildir? (Tamam=Evet, İptal=Hayır)');
      const exit = confirm('Çıkışta bildir? (Tamam=Evet, İptal=Hayır)');
      try {
        await ensureParentProfile(auth.currentUser);
        await updateDoc(doc(db, 'families', auth.currentUser.uid, 'geofences', g.id), {
          name,
          radiusMeters: radius,
          notifyOnEnter: enter,
          notifyOnExit: exit,
        });
        toast('Güncellendi', 'success');
      } catch (e) {
        toast(e.message, 'error');
      }
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
    toast('Bölge eklendi', 'success');
    pendingCenter = null;
    if (circlePreview) {
      map.removeLayer(circlePreview);
      circlePreview = null;
    }
    document.getElementById('geo-status').textContent =
      'Haritaya tıkla → merkez seç → Ekle';
  } catch (e) {
    toast(e.message, 'error');
  }
}

export function unmountGeofence() {
  if (unsubFences) unsubFences();
  if (unsubFam) unsubFam();
  unsubFences = unsubFam = null;
  if (map) {
    map.remove();
    map = null;
  }
}
