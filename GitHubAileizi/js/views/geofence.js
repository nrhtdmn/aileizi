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
import { t, toast, escapeHtml, fmtTime } from '../utils.js';

let map;
let fenceLayer;
let markersLayer;
let unsubFences;
let unsubFam;
let unsubLoc;
let children = [];
let activeChildIds = new Set();
let pendingCenter = null;
let circlePreview;
let streetLayer;
let hybridBase;
let hybridLabels;
let mapMode = localStorage.getItem('aileizi_map_mode') || 'hybrid';
const locByChild = new Map();

function asNum(v) {
  if (typeof v === 'number' && Number.isFinite(v)) return v;
  if (typeof v === 'string' && v.trim() !== '') {
    const n = Number(v);
    return Number.isFinite(n) ? n : null;
  }
  return null;
}

function childMarkerIcon(name, online) {
  const initial = escapeHtml((name || '?').trim().charAt(0).toUpperCase() || '?');
  const bg = online ? '#1b4332' : '#6b756f';
  return L.divIcon({
    className: 'child-marker',
    html: `<div class="child-pin" style="--pin:${bg}"><span>${initial}</span><i></i></div>`,
    iconSize: [40, 48],
    iconAnchor: [20, 46],
    popupAnchor: [0, -40],
  });
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
  locByChild.clear();
  root.innerHTML = `
    <div class="view map-view">
      <div class="map-bar">
        <span style="font-weight:800;flex:1">Güvenli bölgeler</span>
        <div class="map-actions">
          <button class="btn btn-sm btn-outline" id="geo-map-type" type="button">Hibrit</button>
          <button class="btn btn-sm btn-outline" id="geo-center" type="button">Ortala</button>
          <button class="btn btn-sm btn-primary" id="geo-add" type="button">+ Bölge</button>
        </div>
      </div>
      <div class="map-status" id="geo-status">Haritaya tıkla → merkez seç → + Bölge</div>
      <div class="map-stage">
        <div id="geofence-map"></div>
        <div class="map-zoom-fab">
          <button type="button" id="geo-zoom-in">+</button>
          <button type="button" id="geo-zoom-out">−</button>
        </div>
      </div>
      <div class="map-manage" id="geo-list"></div>
    </div>
  `;

  map = L.map('geofence-map', { zoomControl: false }).setView(
    [DEFAULT_MAP.lat, DEFAULT_MAP.lng],
    12,
  );
  root.querySelector('#geo-zoom-in').onclick = () => map.zoomIn();
  root.querySelector('#geo-zoom-out').onclick = () => map.zoomOut();

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
  fenceLayer = L.layerGroup().addTo(map);
  markersLayer = L.layerGroup().addTo(map);

  map.on('click', (ev) => {
    pendingCenter = { lat: ev.latlng.lat, lng: ev.latlng.lng };
    if (circlePreview) map.removeLayer(circlePreview);
    circlePreview = L.circle([pendingCenter.lat, pendingCenter.lng], {
      radius: 200,
      color: '#2d6a4f',
      fillOpacity: 0.15,
    }).addTo(map);
    document.getElementById('geo-status').textContent =
      'Merkez seçildi — + Bölge ile kaydet';
  });

  const fid = auth.currentUser?.uid;
  if (!fid) return;

  unsubFam = onSnapshot(doc(db, 'families', fid), async (fam) => {
    const ids = fam.data()?.childIds || [];
    activeChildIds = new Set(ids);
    children = [];
    for (const id of ids) {
      try {
        const u = await getDoc(doc(db, 'users', id));
        children.push({ uid: id, name: u.data()?.name || id.slice(0, 6) });
      } catch {
        children.push({ uid: id, name: id.slice(0, 6) });
      }
    }
    for (const id of [...locByChild.keys()]) {
      if (!activeChildIds.has(id)) locByChild.delete(id);
    }
    renderChildMarkers();
  });

  unsubLoc = onSnapshot(collection(db, 'families', fid, 'locations'), (snap) => {
    snap.forEach((d) => {
      if (activeChildIds.size && !activeChildIds.has(d.id)) return;
      locByChild.set(d.id, d.data() || {});
    });
    const keep = new Set(
      snap.docs
        .map((d) => d.id)
        .filter((id) => !activeChildIds.size || activeChildIds.has(id)),
    );
    for (const id of [...locByChild.keys()]) {
      if (!keep.has(id) || (activeChildIds.size && !activeChildIds.has(id))) {
        locByChild.delete(id);
      }
    }
    renderChildMarkers();
  });

  unsubFences = onSnapshot(collection(db, 'families', fid, 'geofences'), (snap) => {
    fenceLayer.clearLayers();
    const list = [];
    snap.forEach((d) => list.push({ id: d.id, ...d.data() }));
    renderList(list);
    list.forEach((g) => {
      const lat = asNum(g.centerLat);
      const lng = asNum(g.centerLng);
      if (lat == null || lng == null) return;
      L.circle([lat, lng], {
        radius: g.radiusMeters || 200,
        color: '#1b4332',
        fillOpacity: 0.12,
      })
        .bindPopup(escapeHtml(g.name || 'Bölge'))
        .addTo(fenceLayer);
    });
  });

  root.querySelector('#geo-map-type').onclick = () => {
    mapMode = mapMode === 'hybrid' ? 'street' : 'hybrid';
    localStorage.setItem('aileizi_map_mode', mapMode);
    applyMapMode();
  };
  root.querySelector('#geo-center').onclick = () => fitAll();
  root.querySelector('#geo-add').onclick = () => createFence();
  setTimeout(() => map.invalidateSize(), 150);
}

function renderChildMarkers() {
  if (!markersLayer) return;
  markersLayer.clearLayers();
  const pts = [];
  for (const [id, m] of locByChild) {
    if (activeChildIds.size && !activeChildIds.has(id)) continue;
    const lat = asNum(m.latitude);
    const lng = asNum(m.longitude);
    if (lat == null || lng == null) continue;
    if (m.hasLocation === false) continue;
    if (lat === 0 && lng === 0 && m.hasLocation !== true) continue;
    const child = children.find((c) => c.uid === id);
    const name = child?.name || id.slice(0, 6);
    L.marker([lat, lng], {
      icon: childMarkerIcon(name, m.isOnline !== false),
    })
      .bindPopup(
        `<strong>${escapeHtml(name)}</strong><br>${fmtTime(tsToDate(m.timestamp))}`,
      )
      .addTo(markersLayer);
    pts.push([lat, lng]);
  }
  const st = document.getElementById('geo-status');
  if (st && !pendingCenter) {
    st.textContent = pts.length
      ? `${pts.length} çocuk konumu · Haritaya tıkla → + Bölge`
      : 'Haritaya tıkla → merkez seç → + Bölge';
  }
}

function fitAll() {
  const layers = [...markersLayer.getLayers(), ...fenceLayer.getLayers()];
  if (!layers.length) {
    toast('Gösterilecek konum yok');
    return;
  }
  map.fitBounds(L.featureGroup(layers).getBounds().pad(0.2), { maxZoom: 16 });
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
  } catch (e) {
    toast(e.message, 'error');
  }
}

export function unmountGeofence() {
  if (unsubFences) unsubFences();
  if (unsubFam) unsubFam();
  if (unsubLoc) unsubLoc();
  unsubFences = unsubFam = unsubLoc = null;
  locByChild.clear();
  if (map) {
    map.remove();
    map = null;
  }
}
