import {
  auth,
  db,
  collection,
  doc,
  onSnapshot,
  getDocs,
  getDoc,
  query,
  where,
  orderBy,
  Timestamp,
  addDoc,
  deleteDoc,
  serverTimestamp,
  ensureParentProfile,
  tsToDate,
} from '../firebase-app.js';
import { DEFAULT_MAP, OSRM_URL } from '../config.js';
import { toast, escapeHtml, fmtTime } from '../utils.js';

let map;
let markersLayer;
let historyLayer;
let routesLayer;
let streetLayer;
let hybridBase;
let hybridLabels;
let unsubFam;
let unsubLoc;
let unsubStatus;
let unsubRoutes;
let children = [];
let activeChildIds = new Set();
let selectedChildId = null;
let drawMode = false;
let draftPoints = [];
let draftPolyline;
let follow = false;
let mapMode = localStorage.getItem('aileizi_map_mode') || 'hybrid';
let didFit = false;
/** @type {Map<string, object>} */
const locByChild = new Map();

function familyId() {
  return auth.currentUser?.uid;
}

function asNum(v) {
  if (typeof v === 'number' && Number.isFinite(v)) return v;
  if (typeof v === 'string' && v.trim() !== '') {
    const n = Number(v);
    return Number.isFinite(n) ? n : null;
  }
  if (v && typeof v === 'object' && typeof v.toNumber === 'function') {
    const n = v.toNumber();
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
  const btn = document.getElementById('btn-map-type');
  if (btn) btn.textContent = mapMode === 'hybrid' ? 'Harita' : 'Hibrit';
  localStorage.setItem('aileizi_map_mode', mapMode);
}

export function mountMap(root) {
  didFit = false;
  locByChild.clear();

  root.innerHTML = `
    <div class="view map-view">
      <div class="map-bar">
        <select id="map-child" aria-label="Çocuk"></select>
        <div class="map-actions">
          <button class="btn btn-sm btn-outline" id="btn-map-type" type="button">Hibrit</button>
          <button class="btn btn-sm btn-outline" id="btn-center" type="button">Ortala</button>
          <button class="btn btn-sm btn-outline" id="btn-follow" type="button">Takip</button>
          <button class="btn btn-sm btn-outline" id="btn-history" type="button">İz</button>
          <button class="btn btn-sm btn-outline" id="btn-route-toggle" type="button">Rota</button>
        </div>
      </div>
      <div class="route-panel" id="route-panel">
        <p class="hint" id="draw-hint">Haritaya dokunarak nokta ekle.</p>
        <button class="btn btn-sm btn-outline" id="btn-draw" type="button">Çiz</button>
        <button class="btn btn-sm btn-outline" id="btn-osrm" type="button">Yol bul</button>
        <button class="btn btn-sm btn-outline" id="btn-clear-draft" type="button">Temizle</button>
        <button class="btn btn-sm btn-primary" id="btn-save-route" type="button" disabled>Kaydet</button>
      </div>
      <div class="map-status" id="map-status">Konumlar yükleniyor…</div>
      <div id="map"></div>
    </div>
  `;

  map = L.map('map', {
    zoomControl: false,
    attributionControl: true,
  }).setView([DEFAULT_MAP.lat, DEFAULT_MAP.lng], DEFAULT_MAP.zoom);

  L.control.zoom({ position: 'bottomright' }).addTo(map);

  streetLayer = L.tileLayer(
    'https://{s}.basemaps.cartocdn.com/rastertiles/voyager/{z}/{x}/{y}{r}.png',
    {
      attribution: '&copy; OSM &copy; CARTO',
      maxZoom: 20,
      subdomains: 'abcd',
    },
  );

  hybridBase = L.tileLayer(
    'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}',
    {
      attribution: 'Esri',
      maxZoom: 19,
    },
  );

  hybridLabels = L.tileLayer(
    'https://server.arcgisonline.com/ArcGIS/rest/services/Reference/World_Boundaries_and_Places/MapServer/tile/{z}/{y}/{x}',
    {
      attribution: 'Esri',
      maxZoom: 19,
      pane: 'overlayPane',
      opacity: 0.95,
    },
  );

  applyMapMode();

  markersLayer = L.layerGroup().addTo(map);
  historyLayer = L.layerGroup().addTo(map);
  routesLayer = L.layerGroup().addTo(map);

  const fid = familyId();
  if (!fid) {
    setStatus('Oturum yok');
    return;
  }

  unsubFam = onSnapshot(
    doc(db, 'families', fid),
    async (fam) => {
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
      // Drop markers for removed children + delete orphan Firestore location docs
      for (const id of [...locByChild.keys()]) {
        if (!activeChildIds.has(id)) locByChild.delete(id);
      }
      // Clean stale location / device_status docs for removed children
      try {
        const locSnap = await getDocs(collection(db, 'families', fid, 'locations'));
        for (const d of locSnap.docs) {
          if (!activeChildIds.has(d.id)) {
            deleteDoc(d.ref).catch(() => {});
          }
        }
        const stSnap = await getDocs(collection(db, 'families', fid, 'device_status'));
        for (const d of stSnap.docs) {
          if (!activeChildIds.has(d.id)) {
            deleteDoc(d.ref).catch(() => {});
          }
        }
      } catch (_) {}
      if (selectedChildId && !activeChildIds.has(selectedChildId)) {
        selectedChildId = null;
      }
      renderChildSelect();
      renderMarkers();
      if (!ids.length) setStatus('Henüz bağlı çocuk yok');
    },
    (err) => {
      setStatus('Aile okunamadı');
      toast(err.message || 'Aile hatası', 'error');
    },
  );

  unsubLoc = onSnapshot(
    collection(db, 'families', fid, 'locations'),
    (snap) => {
      snap.forEach((d) => {
        // Only keep locations for current family children
        if (activeChildIds.size && !activeChildIds.has(d.id)) return;
        const m = d.data() || {};
        locByChild.set(d.id, { ...m, _src: 'locations', childId: d.id });
      });
      const ids = new Set(
        snap.docs.map((d) => d.id).filter((id) => !activeChildIds.size || activeChildIds.has(id)),
      );
      for (const [id, v] of locByChild) {
        if (v._src === 'locations' && !ids.has(id)) locByChild.delete(id);
        if (activeChildIds.size && !activeChildIds.has(id)) locByChild.delete(id);
      }
      renderMarkers();
    },
    (err) => {
      setStatus('Konum okunamadı (izin?)');
      toast(err.message || 'Konum hatası', 'error');
      console.error('locations', err);
    },
  );

  // Fallback / enrichment from device_status
  unsubStatus = onSnapshot(
    collection(db, 'families', fid, 'device_status'),
    (snap) => {
      snap.forEach((d) => {
        if (activeChildIds.size && !activeChildIds.has(d.id)) return;
        const m = d.data() || {};
        const existing = locByChild.get(d.id);
        const lat = asNum(m.latitude);
        const lng = asNum(m.longitude);
        if (!existing && lat != null && lng != null) {
          locByChild.set(d.id, {
            ...m,
            hasLocation: true,
            _src: 'device_status',
            childId: d.id,
          });
        } else if (existing && existing._src === 'device_status') {
          locByChild.set(d.id, {
            ...existing,
            ...m,
            _src: 'device_status',
            childId: d.id,
          });
        }
      });
      for (const id of [...locByChild.keys()]) {
        if (activeChildIds.size && !activeChildIds.has(id)) locByChild.delete(id);
      }
      renderMarkers();
    },
    () => {},
  );

  unsubRoutes = onSnapshot(collection(db, 'families', fid, 'routes'), (snap) => {
    routesLayer.clearLayers();
    snap.forEach((d) => {
      const r = d.data();
      const pts = (r.points || [])
        .map((p) => [asNum(p.latitude), asNum(p.longitude)])
        .filter((p) => p[0] != null && p[1] != null);
      if (pts.length < 2) return;
      const color = r.isDeviated ? '#c62828' : r.active ? '#2d6a4f' : '#889';
      L.polyline(pts, { color, weight: 4, opacity: 0.9 })
        .bindPopup(`${escapeHtml(r.name || 'Rota')} ${r.active ? '(aktif)' : ''}`)
        .addTo(routesLayer);
    });
  });

  root.querySelector('#btn-map-type').onclick = () => {
    mapMode = mapMode === 'hybrid' ? 'street' : 'hybrid';
    applyMapMode();
  };
  root.querySelector('#btn-center').onclick = () => fitToMarkers(true);
  root.querySelector('#btn-history').onclick = () => loadHistory();
  root.querySelector('#btn-follow').onclick = (e) => {
    follow = !follow;
    e.target.classList.toggle('is-on', follow);
    if (follow) fitToMarkers(true);
  };
  root.querySelector('#btn-route-toggle').onclick = (e) => {
    const panel = root.querySelector('#route-panel');
    const open = panel.classList.toggle('open');
    e.target.classList.toggle('is-on', open);
    setTimeout(() => map?.invalidateSize(), 80);
  };
  root.querySelector('#btn-draw').onclick = (e) => {
    drawMode = !drawMode;
    draftPoints = [];
    if (draftPolyline) {
      map.removeLayer(draftPolyline);
      draftPolyline = null;
    }
    e.target.classList.toggle('is-on', drawMode);
    root.querySelector('#draw-hint').textContent = drawMode
      ? 'Haritaya dokunarak nokta ekle, sonra Kaydet.'
      : 'Haritaya dokunarak nokta ekle.';
    root.querySelector('#btn-save-route').disabled = true;
  };
  root.querySelector('#btn-osrm').onclick = () => autoRoute();
  root.querySelector('#btn-clear-draft').onclick = () => {
    draftPoints = [];
    if (draftPolyline) {
      map.removeLayer(draftPolyline);
      draftPolyline = null;
    }
    root.querySelector('#btn-save-route').disabled = true;
  };
  root.querySelector('#btn-save-route').onclick = () => saveRoute();
  root.querySelector('#map-child').onchange = (e) => {
    selectedChildId = e.target.value || null;
    renderMarkers();
    if (selectedChildId) fitToMarkers(true);
  };

  map.on('click', (ev) => {
    if (!drawMode) return;
    draftPoints.push({ latitude: ev.latlng.lat, longitude: ev.latlng.lng });
    refreshDraft();
  });

  setTimeout(() => {
    map.invalidateSize();
    renderMarkers();
  }, 150);
  setTimeout(() => map.invalidateSize(), 500);
}

function setStatus(text) {
  const el = document.getElementById('map-status');
  if (el) el.textContent = text;
}

function renderChildSelect() {
  const sel = document.getElementById('map-child');
  if (!sel) return;
  const prev = selectedChildId;
  sel.innerHTML =
    `<option value="">Tüm çocuklar</option>` +
    children
      .map(
        (c) =>
          `<option value="${c.uid}" ${prev === c.uid ? 'selected' : ''}>${escapeHtml(c.name)}</option>`,
      )
      .join('');
}

function renderMarkers() {
  if (!markersLayer || !map) return;
  markersLayer.clearLayers();
  const pts = [];

  for (const [id, m] of locByChild) {
    if (activeChildIds.size && !activeChildIds.has(id)) continue;
    if (selectedChildId && id !== selectedChildId) continue;

    const lat = asNum(m.latitude);
    const lng = asNum(m.longitude);
    if (lat == null || lng == null) continue;
    if (m.hasLocation === false) continue;
    // Skip null island unless explicitly hasLocation
    if (lat === 0 && lng === 0 && m.hasLocation !== true) continue;

    const child = children.find((c) => c.uid === id);
    const name = child?.name || m.childName || id.slice(0, 6);
    const online = m.isOnline !== false;
    const bat =
      m.batteryLevel != null && m.batteryLevel !== ''
        ? `Pil ${m.batteryLevel}%`
        : '';
    const speed =
      m.speedKmh != null ? `${Number(m.speedKmh).toFixed(0)} km/s` : '';

    const marker = L.marker([lat, lng], {
      icon: childMarkerIcon(name, online),
      title: name,
    }).bindPopup(
      `<div class="map-popup">
        <strong>${escapeHtml(name)}</strong>
        <div>${online ? 'Çevrimiçi' : 'Çevrimdışı'}${bat ? ' · ' + bat : ''}</div>
        ${speed ? `<div>${speed}</div>` : ''}
        <div class="meta">${fmtTime(tsToDate(m.timestamp) || tsToDate(m.lastSeen))}</div>
      </div>`,
    );
    markersLayer.addLayer(marker);
    pts.push([lat, lng]);

    if (follow && selectedChildId === id) {
      map.panTo([lat, lng], { animate: true });
    }
  }

  if (!pts.length) {
    const waitingKids = children.length
      ? `${children.length} çocuk — henüz konum yok (uygulama açık mı?)`
      : 'Konum bekleniyor…';
    setStatus(waitingKids);
    return;
  }

  setStatus(
    pts.length === 1
      ? '1 konum gösteriliyor'
      : `${pts.length} konum gösteriliyor`,
  );

  if (!didFit || follow) {
    fitToMarkers(false);
    didFit = true;
  }
}

function fitToMarkers(force) {
  if (!map || !markersLayer) return;
  const layers = markersLayer.getLayers();
  if (!layers.length) {
    if (force) toast('Gösterilecek konum yok');
    return;
  }
  if (layers.length === 1) {
    const ll = layers[0].getLatLng();
    map.setView(ll, Math.max(map.getZoom(), 15), { animate: true });
    return;
  }
  const group = L.featureGroup(layers);
  map.fitBounds(group.getBounds().pad(0.2), { animate: true, maxZoom: 16 });
}

function refreshDraft() {
  if (draftPolyline) map.removeLayer(draftPolyline);
  if (draftPoints.length < 2) {
    document.getElementById('btn-save-route').disabled = true;
    return;
  }
  draftPolyline = L.polyline(
    draftPoints.map((p) => [p.latitude, p.longitude]),
    { color: '#f4a261', weight: 5, dashArray: '6 8' },
  ).addTo(map);
  document.getElementById('btn-save-route').disabled = !selectedChildId;
}

async function loadHistory() {
  const fid = familyId();
  if (!fid || !selectedChildId) {
    toast('Önce bir çocuk seçin', 'error');
    return;
  }
  historyLayer.clearLayers();
  const since = Timestamp.fromDate(new Date(Date.now() - 24 * 3600 * 1000));
  try {
    const qy = query(
      collection(
        db,
        'families',
        fid,
        'location_history',
        selectedChildId,
        'entries',
      ),
      where('timestamp', '>', since),
      orderBy('timestamp', 'asc'),
    );
    const snap = await getDocs(qy);
    const pts = [];
    snap.forEach((d) => {
      const m = d.data();
      const lat = asNum(m.latitude);
      const lng = asNum(m.longitude);
      if (lat != null && lng != null) pts.push([lat, lng]);
    });
    if (pts.length < 2) {
      toast('Son 24 saatte iz yok');
      return;
    }
    L.polyline(pts, { color: '#4a90d9', weight: 4, opacity: 0.85 }).addTo(
      historyLayer,
    );
    map.fitBounds(pts);
  } catch (e) {
    toast(e.message || 'Geçmiş yüklenemedi', 'error');
  }
}

async function autoRoute() {
  if (draftPoints.length < 2) {
    toast('Önce en az 2 nokta çizin', 'error');
    return;
  }
  const coords = draftPoints.map((p) => `${p.longitude},${p.latitude}`).join(';');
  try {
    const res = await fetch(`${OSRM_URL}/${coords}?overview=full&geometries=geojson`);
    const data = await res.json();
    const geo = data?.routes?.[0]?.geometry?.coordinates;
    if (!geo?.length) throw new Error('Rota bulunamadı');
    draftPoints = geo.map(([lng, lat]) => ({ latitude: lat, longitude: lng }));
    refreshDraft();
    toast('Rota hazır', 'success');
  } catch (e) {
    toast(e.message || 'Rota hatası', 'error');
  }
}

async function saveRoute() {
  const fid = familyId();
  if (!fid || !selectedChildId || draftPoints.length < 2) return;
  const name = prompt('Rota adı', 'Rota')?.trim();
  if (!name) return;
  try {
    await ensureParentProfile(auth.currentUser);
    await addDoc(collection(db, 'families', fid, 'routes'), {
      name,
      childId: selectedChildId,
      mode: 'manual',
      points: draftPoints,
      deviationMeters: 80,
      active: true,
      isDeviated: false,
      recording: false,
      createdAt: serverTimestamp(),
    });
    toast('Rota kaydedildi', 'success');
    draftPoints = [];
    if (draftPolyline) {
      map.removeLayer(draftPolyline);
      draftPolyline = null;
    }
    drawMode = false;
  } catch (e) {
    toast(e.message || 'Kayıt başarısız', 'error');
  }
}

export function unmountMap() {
  if (unsubFam) unsubFam();
  if (unsubLoc) unsubLoc();
  if (unsubStatus) unsubStatus();
  if (unsubRoutes) unsubRoutes();
  unsubFam = unsubLoc = unsubStatus = unsubRoutes = null;
  locByChild.clear();
  if (map) {
    map.remove();
    map = null;
  }
}

export function focusMapOn(lat, lng) {
  const a = asNum(lat);
  const b = asNum(lng);
  if (map && a != null && b != null) {
    map.setView([a, b], 16);
  }
}
