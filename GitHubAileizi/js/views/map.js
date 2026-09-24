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
let unsubFam;
let unsubLoc;
let unsubRoutes;
let children = [];
let selectedChildId = null;
let drawMode = false;
let draftPoints = [];
let draftPolyline;
let follow = false;

function familyId() {
  return auth.currentUser?.uid;
}

export function mountMap(root) {
  root.innerHTML = `
    <div class="view map-view">
      <div class="map-toolbar">
        <select id="map-child"></select>
        <button class="btn btn-sm btn-outline" id="btn-history">24s iz</button>
        <button class="btn btn-sm btn-outline" id="btn-follow">Takip</button>
        <button class="btn btn-sm btn-outline" id="btn-draw">Rota çiz</button>
        <button class="btn btn-sm btn-outline" id="btn-osrm">OSRM</button>
        <button class="btn btn-sm btn-primary" id="btn-save-route" disabled>Rotayı kaydet</button>
        <button class="btn btn-sm btn-outline" id="btn-clear-draft">Temizle</button>
      </div>
      <div class="child-chip-bar" id="child-chips"></div>
      <p class="route-draw-hint" id="draw-hint"></p>
      <div id="map"></div>
    </div>
  `;

  map = L.map('map', { zoomControl: true }).setView(
    [DEFAULT_MAP.lat, DEFAULT_MAP.lng],
    DEFAULT_MAP.zoom,
  );
  L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', {
    attribution: '&copy; OpenStreetMap',
    maxZoom: 19,
  }).addTo(map);

  markersLayer = L.layerGroup().addTo(map);
  historyLayer = L.layerGroup().addTo(map);
  routesLayer = L.layerGroup().addTo(map);

  const fid = familyId();
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
    renderChildSelect();
  });

  unsubLoc = onSnapshot(collection(db, 'families', fid, 'locations'), (snap) => {
    markersLayer.clearLayers();
    snap.forEach((d) => {
      const m = d.data();
      const lat = m.latitude;
      const lng = m.longitude;
      if (typeof lat !== 'number' || typeof lng !== 'number') return;
      if (m.hasLocation === false) return;
      const child = children.find((c) => c.uid === d.id);
      const name = child?.name || d.id.slice(0, 6);
      const online = m.isOnline ? '🟢' : '⚪';
      const bat = m.batteryLevel != null ? `🔋${m.batteryLevel}%` : '';
      const marker = L.marker([lat, lng]).bindPopup(
        `<b>${escapeHtml(name)}</b><br>${online} ${bat}<br>${fmtTime(tsToDate(m.timestamp))}`,
      );
      markersLayer.addLayer(marker);
      if (selectedChildId === d.id && follow) {
        map.panTo([lat, lng]);
      }
    });
  });

  unsubRoutes = onSnapshot(collection(db, 'families', fid, 'routes'), (snap) => {
    routesLayer.clearLayers();
    snap.forEach((d) => {
      const r = d.data();
      const pts = (r.points || [])
        .map((p) => [p.latitude, p.longitude])
        .filter((p) => Number.isFinite(p[0]) && Number.isFinite(p[1]));
      if (pts.length < 2) return;
      const color = r.isDeviated ? '#c1121f' : r.active ? '#2d6a4f' : '#889';
      L.polyline(pts, { color, weight: 4, opacity: 0.85 })
        .bindPopup(`${escapeHtml(r.name || 'Rota')} ${r.active ? '(aktif)' : ''}`)
        .addTo(routesLayer);
    });
  });

  root.querySelector('#btn-history').onclick = () => loadHistory();
  root.querySelector('#btn-follow').onclick = (e) => {
    follow = !follow;
    e.target.classList.toggle('btn-primary', follow);
    e.target.classList.toggle('btn-outline', !follow);
  };
  root.querySelector('#btn-draw').onclick = (e) => {
    drawMode = !drawMode;
    draftPoints = [];
    if (draftPolyline) {
      map.removeLayer(draftPolyline);
      draftPolyline = null;
    }
    e.target.classList.toggle('btn-primary', drawMode);
    root.querySelector('#draw-hint').textContent = drawMode
      ? 'Haritaya dokunarak rota noktaları ekleyin.'
      : '';
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
    highlightChip();
  };

  map.on('click', (ev) => {
    if (!drawMode) return;
    draftPoints.push({ latitude: ev.latlng.lat, longitude: ev.latlng.lng });
    refreshDraft();
  });

  setTimeout(() => map.invalidateSize(), 120);
}

function renderChildSelect() {
  const sel = document.getElementById('map-child');
  const chips = document.getElementById('child-chips');
  if (!sel || !chips) return;
  sel.innerHTML =
    `<option value="">Tüm çocuklar</option>` +
    children
      .map(
        (c) =>
          `<option value="${c.uid}" ${selectedChildId === c.uid ? 'selected' : ''}>${escapeHtml(c.name)}</option>`,
      )
      .join('');
  chips.innerHTML = children
    .map(
      (c) =>
        `<button type="button" class="child-chip ${selectedChildId === c.uid ? 'active' : ''}" data-id="${c.uid}">${escapeHtml(c.name)}</button>`,
    )
    .join('');
  chips.querySelectorAll('.child-chip').forEach((btn) => {
    btn.onclick = () => {
      selectedChildId = btn.dataset.id;
      sel.value = selectedChildId;
      highlightChip();
    };
  });
}

function highlightChip() {
  document.querySelectorAll('#child-chips .child-chip').forEach((b) => {
    b.classList.toggle('active', b.dataset.id === selectedChildId);
  });
}

function refreshDraft() {
  if (draftPolyline) map.removeLayer(draftPolyline);
  if (draftPoints.length < 2) {
    document.getElementById('btn-save-route').disabled = true;
    return;
  }
  draftPolyline = L.polyline(
    draftPoints.map((p) => [p.latitude, p.longitude]),
    { color: '#e09f3e', weight: 5, dashArray: '6 8' },
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
      if (typeof m.latitude === 'number') pts.push([m.latitude, m.longitude]);
    });
    if (pts.length < 2) {
      toast('Son 24 saatte iz yok');
      return;
    }
    L.polyline(pts, { color: '#3a7ca5', weight: 3 }).addTo(historyLayer);
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
    toast('OSRM rotası hazır', 'success');
  } catch (e) {
    toast(e.message || 'OSRM hatası', 'error');
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
  if (unsubRoutes) unsubRoutes();
  unsubFam = unsubLoc = unsubRoutes = null;
  if (map) {
    map.remove();
    map = null;
  }
}

export function focusMapOn(lat, lng) {
  if (map && Number.isFinite(lat) && Number.isFinite(lng)) {
    map.setView([lat, lng], 16);
  }
}
