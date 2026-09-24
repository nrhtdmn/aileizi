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
import { setKeepAwake } from '../keep-awake.js';

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
let pendingFence = null;
let fencePreview = null;
let liveTrailPoints = [];
let liveTrailLine = null;
let animTimer = null;
let animMarker = null;
let historyHours = 24;
/** @type {Array<[number, number]>} */
let historyAnimPts = [];
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
      <div class="map-bar chrome-el">
        <div class="map-actions">
          <button class="btn btn-sm btn-outline" id="btn-map-type" type="button">Hibrit</button>
          <button class="btn btn-sm btn-outline" id="btn-center" type="button">Ortala</button>
          <button class="btn btn-sm btn-outline" id="btn-tools" type="button">Araçlar</button>
          <button class="btn btn-sm btn-primary" id="btn-add-fence" type="button">+ Bölge</button>
        </div>
      </div>
      <div class="tools-panel chrome-el" id="tools-panel">
        <div class="tools-section">
          <h4>Takip</h4>
          <p class="hint">Çocuğu canlı izle, gittiği yeri çiz. Ekran kapanmaz.</p>
          <button class="btn btn-sm btn-outline" id="btn-follow" type="button">Takibi başlat</button>
          <button class="btn btn-sm btn-outline" id="btn-clear-live" type="button">Canlı izi sil</button>
          <button class="btn btn-sm btn-outline" id="btn-save-live" type="button">Canlı izi kaydet</button>
        </div>
        <div class="tools-section">
          <h4>İz (geçmiş)</h4>
          <p class="hint">Süre seç → yükle → oynat. Harita yolu takip eder.</p>
          <select id="history-hours" aria-label="Süre">
            <option value="1">Son 1 saat</option>
            <option value="3">Son 3 saat</option>
            <option value="6">Son 6 saat</option>
            <option value="12">Son 12 saat</option>
            <option value="24" selected>Son 24 saat</option>
            <option value="48">Son 2 gün</option>
            <option value="168">Son 7 gün</option>
          </select>
          <div class="row-actions">
            <button class="btn btn-sm btn-outline" id="btn-history" type="button">İzi yükle</button>
            <button class="btn btn-sm btn-primary" id="btn-anim" type="button" disabled>Oynat</button>
            <button class="btn btn-sm btn-outline" id="btn-anim-stop" type="button">Durdur</button>
            <button class="btn btn-sm btn-outline" id="btn-save-trail" type="button">İzi kaydet</button>
          </div>
        </div>
        <div class="tools-section">
          <h4>Konum</h4>
          <p class="hint">Haritaya tıkla veya seçili çocuğun konumunu kaydet.</p>
          <div class="row-actions">
            <button class="btn btn-sm btn-outline" id="btn-save-place-click" type="button">Tıklanan noktayı kaydet</button>
            <button class="btn btn-sm btn-outline" id="btn-save-place-child" type="button">Çocuk konumunu kaydet</button>
          </div>
        </div>
        <div class="tools-section">
          <h4>Rota çiz</h4>
          <p class="hint" id="draw-hint">Haritaya dokunarak nokta ekle, kaydet.</p>
          <div class="row-actions">
            <button class="btn btn-sm btn-outline" id="btn-draw" type="button">Çiz</button>
            <button class="btn btn-sm btn-outline" id="btn-osrm" type="button">Yol bul</button>
            <button class="btn btn-sm btn-outline" id="btn-clear-draft" type="button">Temizle</button>
            <button class="btn btn-sm btn-primary" id="btn-save-route" type="button" disabled>Kaydet</button>
          </div>
          <p class="hint">Tüm kayıtları yönetmek için alt menüden <b>Kayıt</b>.</p>
        </div>
      </div>
      <div class="map-status chrome-el" id="map-status">Konumlar yükleniyor…</div>
      <div class="map-stage">
        <div id="map"></div>
        <div class="map-zoom-fab" aria-label="Yakınlaştır">
          <button type="button" id="btn-zoom-in" title="Yakınlaştır">+</button>
          <button type="button" id="btn-zoom-out" title="Uzaklaştır">−</button>
        </div>
      </div>
    </div>
  `;

  map = L.map('map', {
    zoomControl: false,
    attributionControl: true,
  }).setView([DEFAULT_MAP.lat, DEFAULT_MAP.lng], DEFAULT_MAP.zoom);

  root.querySelector('#btn-zoom-in').onclick = () => map.zoomIn();
  root.querySelector('#btn-zoom-out').onclick = () => map.zoomOut();

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
  root.querySelector('#btn-tools').onclick = (e) => {
    const panel = root.querySelector('#tools-panel');
    const open = panel.classList.toggle('open');
    e.target.classList.toggle('is-on', open);
    setTimeout(() => map?.invalidateSize(), 80);
  };
  root.querySelector('#btn-follow').onclick = () => toggleFollow();
  root.querySelector('#btn-clear-live').onclick = () => clearLiveTrail();
  root.querySelector('#btn-save-live').onclick = () => saveTrailFromLive();
  root.querySelector('#history-hours').onchange = (e) => {
    historyHours = Number(e.target.value) || 24;
  };
  root.querySelector('#btn-history').onclick = () => loadHistory();
  root.querySelector('#btn-anim').onclick = () => playHistoryAnim();
  root.querySelector('#btn-anim-stop').onclick = () => stopHistoryAnim();
  root.querySelector('#btn-save-trail').onclick = () => saveTrailFromHistory();
  root.querySelector('#btn-save-place-click').onclick = () => savePlaceFromClick();
  root.querySelector('#btn-save-place-child').onclick = () => savePlaceFromChild();
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
      : 'Haritaya dokunarak nokta ekle, kaydet.';
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
  root.querySelector('#btn-add-fence').onclick = () => addSafeZoneFromMap();
  const topChild = document.getElementById('top-child');
  if (topChild) {
    topChild.onchange = (e) => {
      selectedChildId = e.target.value || null;
      if (follow) {
        liveTrailPoints = [];
        refreshLiveTrail();
      }
      renderMarkers();
      if (selectedChildId) fitToMarkers(true);
    };
  }

  map.on('click', (ev) => {
    if (drawMode) {
      draftPoints.push({ latitude: ev.latlng.lat, longitude: ev.latlng.lng });
      refreshDraft();
      return;
    }
    pendingFence = { lat: ev.latlng.lat, lng: ev.latlng.lng };
    if (fencePreview) map.removeLayer(fencePreview);
    fencePreview = L.circle([pendingFence.lat, pendingFence.lng], {
      radius: 200,
      color: '#2d6a4f',
      fillOpacity: 0.12,
      dashArray: '4 6',
    }).addTo(map);
    setStatus('Nokta seçildi — «+ Bölge» ile güvenli bölge ekle');
  });

  setTimeout(() => {
    map.invalidateSize();
    renderMarkers();
  }, 150);
  setTimeout(() => map.invalidateSize(), 500);

  const onResize = () => map?.invalidateSize();
  window.addEventListener('resize', onResize);
  root._onResize = onResize;
}

function toggleFollow() {
  const btn = document.getElementById('btn-follow');
  if (!follow && !selectedChildId) {
    toast('Önce üstten bir çocuk seç', 'error');
    return;
  }
  follow = !follow;
  if (btn) {
    btn.classList.toggle('is-on', follow);
    btn.textContent = follow ? 'Takibi durdur' : 'Takibi başlat';
  }
  setKeepAwake('follow', follow);
  if (follow) {
    liveTrailPoints = [];
    const m = locByChild.get(selectedChildId);
    const lat = asNum(m?.latitude);
    const lng = asNum(m?.longitude);
    if (lat != null && lng != null) {
      liveTrailPoints.push([lat, lng]);
      refreshLiveTrail();
      map.setView([lat, lng], Math.max(map.getZoom(), 16));
    }
    setStatus('Takip açık · ekran kapanmaz · canlı iz çiziliyor');
    toast('Takip başladı', 'success');
  } else {
    setStatus('Takip kapalı');
    toast('Takip durdu');
  }
}

function clearLiveTrail() {
  liveTrailPoints = [];
  refreshLiveTrail();
  toast('Canlı iz temizlendi');
}

function refreshLiveTrail() {
  if (liveTrailLine) {
    historyLayer.removeLayer(liveTrailLine);
    liveTrailLine = null;
  }
  if (liveTrailPoints.length >= 2) {
    liveTrailLine = L.polyline(liveTrailPoints, {
      color: '#e76f51',
      weight: 5,
      opacity: 0.9,
    }).addTo(historyLayer);
  } else if (liveTrailPoints.length === 1) {
    liveTrailLine = L.circleMarker(liveTrailPoints[0], {
      radius: 5,
      color: '#e76f51',
      fillColor: '#e76f51',
      fillOpacity: 1,
    }).addTo(historyLayer);
  }
}

async function addSafeZoneFromMap() {
  let center = pendingFence;
  if (!center && selectedChildId) {
    const m = locByChild.get(selectedChildId);
    const lat = asNum(m?.latitude);
    const lng = asNum(m?.longitude);
    if (lat != null && lng != null) center = { lat, lng };
  }
  if (!center) {
    toast('Haritaya tıkla veya konumlu çocuk seç', 'error');
    return;
  }
  const name = prompt('Güvenli bölge adı', 'Ev')?.trim();
  if (!name) return;
  const radius = Number(prompt('Yarıçap (metre)', '200')) || 200;
  try {
    await ensureParentProfile(auth.currentUser);
    await addDoc(collection(db, 'families', familyId(), 'geofences'), {
      name,
      centerLat: center.lat,
      centerLng: center.lng,
      radiusMeters: radius,
      childIds: selectedChildId ? [selectedChildId] : [],
      notifyOnEnter: true,
      notifyOnExit: true,
    });
    toast('Güvenli bölge eklendi', 'success');
    pendingFence = null;
    if (fencePreview) {
      map.removeLayer(fencePreview);
      fencePreview = null;
    }
  } catch (e) {
    toast(e.message || 'Eklenemedi', 'error');
  }
}

function setStatus(text) {
  const el = document.getElementById('map-status');
  if (el) el.textContent = text;
}

function renderChildSelect() {
  const sel = document.getElementById('top-child');
  if (!sel) return;
  const prev = selectedChildId ?? sel.value;
  sel.innerHTML =
    `<option value="">Tüm çocuklar</option>` +
    children
      .map(
        (c) =>
          `<option value="${c.uid}" ${prev === c.uid ? 'selected' : ''}>${escapeHtml(c.name)}</option>`,
      )
      .join('');
  if (prev) selectedChildId = prev || null;
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
      const last = liveTrailPoints[liveTrailPoints.length - 1];
      if (!last || last[0] !== lat || last[1] !== lng) {
        // throttle ~12m moves already done on child; here take every update if moved
        if (
          !last ||
          Math.abs(last[0] - lat) > 0.00005 ||
          Math.abs(last[1] - lng) > 0.00005
        ) {
          liveTrailPoints.push([lat, lng]);
          if (liveTrailPoints.length > 2000) liveTrailPoints.shift();
          refreshLiveTrail();
        }
      }
      setStatus(
        `Takip · ${liveTrailPoints.length} nokta · ekran açık kalır`,
      );
    }
  }

  if (!pts.length) {
    const waitingKids = children.length
      ? `${children.length} çocuk — henüz konum yok (uygulama açık mı?)`
      : 'Konum bekleniyor…';
    if (!follow) setStatus(waitingKids);
    return;
  }

  if (!follow) {
    setStatus(
      pts.length === 1
        ? '1 konum gösteriliyor'
        : `${pts.length} konum gösteriliyor`,
    );
  }

  if (!didFit && !follow) {
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
    toast('Önce üstten bir çocuk seç', 'error');
    return;
  }
  stopHistoryAnim();
  // keep live trail if following
  historyLayer.clearLayers();
  if (liveTrailLine && liveTrailPoints.length) refreshLiveTrail();

  historyHours =
    Number(document.getElementById('history-hours')?.value) || historyHours || 24;
  const since = Timestamp.fromDate(
    new Date(Date.now() - historyHours * 3600 * 1000),
  );
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
    historyAnimPts = pts;
    const animBtn = document.getElementById('btn-anim');
    if (animBtn) animBtn.disabled = pts.length < 2;
    if (pts.length < 2) {
      toast(`Son ${historyHours} saatte yeterli iz yok`);
      return;
    }
    L.polyline(pts, { color: '#4a90d9', weight: 4, opacity: 0.55 }).addTo(
      historyLayer,
    );
    L.circleMarker(pts[0], {
      radius: 7,
      color: '#2d6a4f',
      fillColor: '#2d6a4f',
      fillOpacity: 1,
    })
      .bindPopup('Başlangıç')
      .addTo(historyLayer);
    L.circleMarker(pts[pts.length - 1], {
      radius: 7,
      color: '#c62828',
      fillColor: '#c62828',
      fillOpacity: 1,
    })
      .bindPopup('Son')
      .addTo(historyLayer);
    map.fitBounds(pts, { padding: [30, 30] });
    toast(`${pts.length} nokta yüklendi — Oynat’a bas`, 'success');
  } catch (e) {
    toast(e.message || 'Geçmiş yüklenemedi', 'error');
  }
}

function stopHistoryAnim() {
  if (animTimer) {
    clearInterval(animTimer);
    animTimer = null;
  }
  if (animMarker && map) {
    try {
      map.removeLayer(animMarker);
    } catch (_) {}
    animMarker = null;
  }
}

function playHistoryAnim() {
  stopHistoryAnim();
  if (historyAnimPts.length < 2) {
    toast('Önce izi yükle', 'error');
    return;
  }
  const pts = historyAnimPts;
  let i = 0;
  const traveled = [pts[0]];
  let pathLine = L.polyline(traveled, {
    color: '#f4a261',
    weight: 5,
    opacity: 0.95,
  }).addTo(historyLayer);

  animMarker = L.circleMarker(pts[0], {
    radius: 9,
    color: '#fff',
    weight: 2,
    fillColor: '#e76f51',
    fillOpacity: 1,
  }).addTo(map);

  map.setView(pts[0], Math.max(map.getZoom(), 15));
  setStatus('İz oynatılıyor…');

  const stepMs = Math.max(40, Math.min(200, 12000 / pts.length));
  animTimer = setInterval(() => {
    i += 1;
    if (i >= pts.length) {
      stopHistoryAnim();
      setStatus('İz animasyonu bitti');
      toast('Animasyon tamam', 'success');
      return;
    }
    traveled.push(pts[i]);
    pathLine.setLatLngs(traveled);
    animMarker.setLatLng(pts[i]);
    map.panTo(pts[i], { animate: true, duration: stepMs / 1000 });
  }, stepMs);
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
    toast('Rota kaydedildi — Kayıt sekmesinden yönet', 'success');
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

async function saveTrailDoc({ name, points, source, hours }) {
  const fid = familyId();
  if (!fid || !selectedChildId) {
    toast('Önce üstten bir çocuk seç', 'error');
    return;
  }
  if (!points || points.length < 2) {
    toast('Kaydedilecek yeterli nokta yok', 'error');
    return;
  }
  try {
    await ensureParentProfile(auth.currentUser);
    await addDoc(collection(db, 'families', fid, 'trails'), {
      name,
      childId: selectedChildId,
      points: points.map((p) =>
        Array.isArray(p)
          ? { latitude: p[0], longitude: p[1] }
          : { latitude: p.latitude, longitude: p.longitude },
      ),
      source,
      hours: hours || null,
      createdAt: serverTimestamp(),
    });
    toast('İz kaydedildi — Kayıt sekmesi', 'success');
  } catch (e) {
    toast(e.message || 'İz kaydı başarısız', 'error');
  }
}

async function saveTrailFromHistory() {
  if (historyAnimPts.length < 2) {
    toast('Önce izi yükle', 'error');
    return;
  }
  const name = prompt('İz adı', `İz ${historyHours}s`)?.trim();
  if (!name) return;
  await saveTrailDoc({
    name,
    points: historyAnimPts,
    source: 'history',
    hours: historyHours,
  });
}

async function saveTrailFromLive() {
  if (liveTrailPoints.length < 2) {
    toast('Önce takibi başlatıp biraz iz çiz', 'error');
    return;
  }
  const name = prompt('İz adı', 'Canlı iz')?.trim();
  if (!name) return;
  await saveTrailDoc({
    name,
    points: liveTrailPoints,
    source: 'live',
  });
}

async function savePlaceAt(lat, lng, defaultName) {
  const fid = familyId();
  if (!fid) return;
  const name = prompt('Konum adı', defaultName || 'Konum')?.trim();
  if (!name) return;
  const note = prompt('Not (isteğe bağlı)', '')?.trim() || '';
  try {
    await ensureParentProfile(auth.currentUser);
    await addDoc(collection(db, 'families', fid, 'places'), {
      name,
      latitude: lat,
      longitude: lng,
      note,
      childId: selectedChildId || null,
      createdAt: serverTimestamp(),
    });
    toast('Konum kaydedildi — Kayıt sekmesi', 'success');
  } catch (e) {
    toast(e.message || 'Konum kaydı başarısız', 'error');
  }
}

async function savePlaceFromClick() {
  if (!pendingFence) {
    toast('Önce haritaya tıkla', 'error');
    return;
  }
  await savePlaceAt(pendingFence.lat, pendingFence.lng, 'Konum');
}

async function savePlaceFromChild() {
  if (!selectedChildId) {
    toast('Önce üstten bir çocuk seç', 'error');
    return;
  }
  const m = locByChild.get(selectedChildId);
  const lat = asNum(m?.latitude);
  const lng = asNum(m?.longitude);
  if (lat == null || lng == null) {
    toast('Çocuk konumu yok', 'error');
    return;
  }
  const child = children.find((c) => c.uid === selectedChildId);
  await savePlaceAt(lat, lng, child?.name || 'Konum');
}

export function unmountMap() {
  stopHistoryAnim();
  setKeepAwake('follow', false);
  follow = false;
  liveTrailPoints = [];
  liveTrailLine = null;
  historyAnimPts = [];
  if (unsubFam) unsubFam();
  if (unsubLoc) unsubLoc();
  if (unsubStatus) unsubStatus();
  if (unsubRoutes) unsubRoutes();
  unsubFam = unsubLoc = unsubStatus = unsubRoutes = null;
  locByChild.clear();
  pendingFence = null;
  fencePreview = null;
  const roots = document.querySelectorAll('.map-view');
  roots.forEach((r) => {
    if (r._onResize) window.removeEventListener('resize', r._onResize);
  });
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
