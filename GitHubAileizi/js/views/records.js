import {
  auth,
  db,
  collection,
  doc,
  onSnapshot,
  updateDoc,
  deleteDoc,
  getDoc,
  addDoc,
  ensureParentProfile,
  serverTimestamp,
  deleteField,
  tsToDate,
} from '../firebase-app.js';
import { t, fmtTime, toast, escapeHtml, shareText } from '../utils.js';

let unsubs = [];
let children = [];
let cache = { routes: [], fences: [], places: [], trails: [] };
let section = localStorage.getItem('aileizi_records_tab') || 'routes';

const SECTIONS = [
  { id: 'routes', label: 'Rotalar', ico: '🛣️' },
  { id: 'fences', label: 'Bölgeler', ico: '📍' },
  { id: 'places', label: 'Konumlar', ico: '📌' },
  { id: 'trails', label: 'İzler', ico: '👣' },
];

function mapsPoint(lat, lng, label) {
  const q = encodeURIComponent(`${lat},${lng}`);
  const link = `https://www.google.com/maps?q=${q}`;
  return label ? `${label}\n${link}` : link;
}

function mapsDir(points) {
  if (!points?.length) return '';
  const first = points[0];
  const last = points[points.length - 1];
  const origin = `${first.latitude},${first.longitude}`;
  const dest = `${last.latitude},${last.longitude}`;
  let url = `https://www.google.com/maps/dir/?api=1&origin=${origin}&destination=${dest}`;
  if (points.length > 2) {
    const mid = points
      .slice(1, -1)
      .slice(0, 8)
      .map((p) => `${p.latitude},${p.longitude}`)
      .join('|');
    if (mid) url += `&waypoints=${encodeURIComponent(mid)}`;
  }
  return url;
}

function childName(id) {
  if (!id) return '—';
  return children.find((c) => c.uid === id)?.name || id.slice(0, 6);
}

function sortByCreated(list) {
  return [...list].sort(
    (a, b) =>
      (tsToDate(b.createdAt)?.getTime() || 0) -
      (tsToDate(a.createdAt)?.getTime() || 0),
  );
}

export function mountRecords(root) {
  unsubs = [];
  children = [];
  cache = { routes: [], fences: [], places: [], trails: [] };

  root.innerHTML = `
    <div class="view records-view">
      <div class="panel-title">
        <h2>Kayıtlar</h2>
      </div>
      <p class="meta records-intro">Rota, bölge, konum ve izleri buradan düzenle, sil veya paylaş.</p>
      <div class="records-tabs" id="records-tabs" role="tablist">
        ${SECTIONS.map(
          (s) => `
          <button type="button" role="tab" data-sec="${s.id}" class="${s.id === section ? 'active' : ''}">
            <span class="ico">${s.ico}</span>
            <span>${s.label}</span>
          </button>`,
        ).join('')}
      </div>
      <div class="records-toolbar" id="records-toolbar"></div>
      <div class="list" id="records-list"><div class="empty">${t('loading')}</div></div>
    </div>
  `;

  const fid = auth.currentUser?.uid;
  if (!fid) return;

  root.querySelector('#records-tabs').onclick = (e) => {
    const btn = e.target.closest('button[data-sec]');
    if (!btn) return;
    section = btn.dataset.sec;
    localStorage.setItem('aileizi_records_tab', section);
    root.querySelectorAll('#records-tabs button').forEach((b) =>
      b.classList.toggle('active', b === btn),
    );
    render();
  };

  unsubs.push(
    onSnapshot(doc(db, 'families', fid), async (fam) => {
      const ids = fam.data()?.childIds || [];
      const list = [];
      for (const id of ids) {
        try {
          const u = await getDoc(doc(db, 'users', id));
          list.push({ uid: id, name: u.data()?.name || id.slice(0, 6) });
        } catch {
          list.push({ uid: id, name: id.slice(0, 6) });
        }
      }
      children = list;
      render();
    }),
  );

  unsubs.push(
    onSnapshot(collection(db, 'families', fid, 'routes'), (snap) => {
      cache.routes = [];
      snap.forEach((d) => cache.routes.push({ id: d.id, ...d.data() }));
      if (section === 'routes') render();
    }),
  );

  unsubs.push(
    onSnapshot(collection(db, 'families', fid, 'geofences'), (snap) => {
      cache.fences = [];
      snap.forEach((d) => cache.fences.push({ id: d.id, ...d.data() }));
      if (section === 'fences') render();
    }),
  );

  unsubs.push(
    onSnapshot(collection(db, 'families', fid, 'places'), (snap) => {
      cache.places = [];
      snap.forEach((d) => cache.places.push({ id: d.id, ...d.data() }));
      if (section === 'places') render();
    }),
  );

  unsubs.push(
    onSnapshot(collection(db, 'families', fid, 'trails'), (snap) => {
      cache.trails = [];
      snap.forEach((d) => cache.trails.push({ id: d.id, ...d.data() }));
      if (section === 'trails') render();
    }),
  );

  render();
}

function render() {
  const listEl = document.getElementById('records-list');
  const toolEl = document.getElementById('records-toolbar');
  if (!listEl || !toolEl) return;

  if (section === 'routes') renderRoutes(listEl, toolEl);
  else if (section === 'fences') renderFences(listEl, toolEl);
  else if (section === 'places') renderPlaces(listEl, toolEl);
  else renderTrails(listEl, toolEl);
}

function renderRoutes(el, tool) {
  tool.innerHTML = `<p class="hint">Yeni rota: Harita → Araçlar → Rota çiz.</p>`;
  const list = sortByCreated(cache.routes);
  if (!list.length) {
    el.innerHTML = `<div class="empty">Kayıtlı rota yok.</div>`;
    return;
  }
  el.innerHTML = list
    .map((r) => {
      const pts = r.points?.length || 0;
      const active = r.active !== false && !r.cancelledAt;
      return `
      <div class="row">
        <h3>${escapeHtml(r.name || 'Rota')}
          <span class="badge ${r.isDeviated ? 'danger' : active ? '' : 'warn'}">${r.isDeviated ? 'Sapma' : active ? 'Aktif' : 'Kapalı'}</span>
        </h3>
        <div class="meta">${escapeHtml(childName(r.childId))} · ${pts} nokta · eşik ${Math.round(r.deviationMeters || 80)} m</div>
        <div class="meta">${fmtTime(tsToDate(r.createdAt))}</div>
        <div class="row-actions">
          <button class="btn btn-sm btn-outline" data-toggle="${r.id}" data-active="${active ? '1' : '0'}">${active ? 'Durdur' : 'Başlat'}</button>
          <button class="btn btn-sm btn-outline" data-rename="${r.id}">Ad</button>
          <button class="btn btn-sm btn-outline" data-thresh="${r.id}">Eşik</button>
          <button class="btn btn-sm btn-outline" data-share="${r.id}">Paylaş</button>
          <button class="btn btn-sm btn-outline" data-del="${r.id}">${t('delete')}</button>
        </div>
      </div>`;
    })
    .join('');

  const fid = auth.currentUser.uid;

  el.querySelectorAll('[data-toggle]').forEach((b) => {
    b.onclick = async () => {
      const active = b.dataset.active !== '1';
      try {
        await ensureParentProfile(auth.currentUser);
        await updateDoc(doc(db, 'families', fid, 'routes', b.dataset.toggle), {
          active,
          isDeviated: false,
          ...(active
            ? { cancelledAt: deleteField(), cancelledBy: deleteField() }
            : { cancelledAt: serverTimestamp(), cancelledBy: 'parent' }),
        });
        toast(active ? 'Rota aktif' : 'Rota durduruldu', 'success');
      } catch (e) {
        toast(e.message, 'error');
      }
    };
  });

  el.querySelectorAll('[data-rename]').forEach((b) => {
    b.onclick = async () => {
      const cur = list.find((x) => x.id === b.dataset.rename);
      const name = prompt('Yeni rota adı', cur?.name || '')?.trim();
      if (!name) return;
      try {
        await updateDoc(doc(db, 'families', fid, 'routes', b.dataset.rename), {
          name,
        });
        toast('Güncellendi', 'success');
      } catch (e) {
        toast(e.message, 'error');
      }
    };
  });

  el.querySelectorAll('[data-thresh]').forEach((b) => {
    b.onclick = async () => {
      const cur = list.find((x) => x.id === b.dataset.thresh);
      const v = Number(prompt('Sapma eşiği (metre)', String(cur?.deviationMeters || 80)));
      if (!Number.isFinite(v) || v < 10) return;
      try {
        await updateDoc(doc(db, 'families', fid, 'routes', b.dataset.thresh), {
          deviationMeters: v,
        });
        toast('Eşik güncellendi', 'success');
      } catch (e) {
        toast(e.message, 'error');
      }
    };
  });

  el.querySelectorAll('[data-share]').forEach((b) => {
    b.onclick = () => {
      const r = list.find((x) => x.id === b.dataset.share);
      if (!r) return;
      const pts = r.points || [];
      const text = [
        `Aileİzi rota: ${r.name || 'Rota'}`,
        `Çocuk: ${childName(r.childId)}`,
        `${pts.length} nokta · eşik ${Math.round(r.deviationMeters || 80)} m`,
        pts.length ? mapsDir(pts) : '',
      ]
        .filter(Boolean)
        .join('\n');
      shareText(text, r.name || 'Rota');
    };
  });

  el.querySelectorAll('[data-del]').forEach((b) => {
    b.onclick = async () => {
      if (!confirm('Rota silinsin mi?')) return;
      try {
        await deleteDoc(doc(db, 'families', fid, 'routes', b.dataset.del));
        toast('Silindi', 'success');
      } catch (e) {
        toast(e.message, 'error');
      }
    };
  });
}

function renderFences(el, tool) {
  tool.innerHTML = `<p class="hint">Yeni bölge: Harita veya Bölge sekmesinde + Bölge.</p>`;
  const list = sortByCreated(cache.fences);
  if (!list.length) {
    el.innerHTML = `<div class="empty">Kayıtlı bölge yok.</div>`;
    return;
  }
  el.innerHTML = list
    .map(
      (g) => `
    <div class="row">
      <h3>${escapeHtml(g.name || 'Bölge')}</h3>
      <div class="meta">${Math.round(g.radiusMeters || 0)} m · giriş ${g.notifyOnEnter !== false ? 'açık' : 'kapalı'} · çıkış ${g.notifyOnExit !== false ? 'açık' : 'kapalı'}</div>
      <div class="meta">${fmtTime(tsToDate(g.createdAt))}</div>
      <div class="row-actions">
        <button class="btn btn-sm btn-outline" data-edit="${g.id}">Düzenle</button>
        <button class="btn btn-sm btn-outline" data-share="${g.id}">Paylaş</button>
        <button class="btn btn-sm btn-outline" data-del="${g.id}">${t('delete')}</button>
      </div>
    </div>`,
    )
    .join('');

  const fid = auth.currentUser.uid;

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
        await updateDoc(doc(db, 'families', fid, 'geofences', g.id), {
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

  el.querySelectorAll('[data-share]').forEach((b) => {
    b.onclick = () => {
      const g = list.find((x) => x.id === b.dataset.share);
      if (!g) return;
      const text = [
        `Aileİzi güvenli bölge: ${g.name || 'Bölge'}`,
        `Yarıçap: ${Math.round(g.radiusMeters || 0)} m`,
        mapsPoint(g.centerLat, g.centerLng, 'Merkez'),
      ].join('\n');
      shareText(text, g.name || 'Bölge');
    };
  });

  el.querySelectorAll('[data-del]').forEach((b) => {
    b.onclick = async () => {
      if (!confirm('Bölge silinsin mi?')) return;
      try {
        await deleteDoc(doc(db, 'families', fid, 'geofences', b.dataset.del));
        toast('Silindi', 'success');
      } catch (e) {
        toast(e.message, 'error');
      }
    };
  });
}

function renderPlaces(el, tool) {
  tool.innerHTML = `
    <button class="btn btn-sm btn-primary" id="btn-add-place" type="button">+ Konum ekle</button>
    <p class="hint">Haritada Araçlar → Konum kaydet de kullanılabilir.</p>
  `;
  tool.querySelector('#btn-add-place').onclick = () => addPlaceManual();

  const list = sortByCreated(cache.places);
  if (!list.length) {
    el.innerHTML = `<div class="empty">Kayıtlı konum yok.</div>`;
    return;
  }
  el.innerHTML = list
    .map(
      (p) => `
    <div class="row">
      <h3>${escapeHtml(p.name || 'Konum')}</h3>
      <div class="meta">${Number(p.latitude).toFixed(5)}, ${Number(p.longitude).toFixed(5)}${p.note ? ` · ${escapeHtml(p.note)}` : ''}</div>
      <div class="meta">${fmtTime(tsToDate(p.createdAt))}</div>
      <div class="row-actions">
        <button class="btn btn-sm btn-outline" data-edit="${p.id}">Düzenle</button>
        <button class="btn btn-sm btn-outline" data-share="${p.id}">Paylaş</button>
        <button class="btn btn-sm btn-outline" data-del="${p.id}">${t('delete')}</button>
      </div>
    </div>`,
    )
    .join('');

  const fid = auth.currentUser.uid;

  el.querySelectorAll('[data-edit]').forEach((b) => {
    b.onclick = async () => {
      const p = list.find((x) => x.id === b.dataset.edit);
      if (!p) return;
      const name = prompt('Ad', p.name || '')?.trim();
      if (!name) return;
      const note = prompt('Not (isteğe bağlı)', p.note || '') ?? p.note;
      try {
        await updateDoc(doc(db, 'families', fid, 'places', p.id), {
          name,
          note: (note || '').trim(),
        });
        toast('Güncellendi', 'success');
      } catch (e) {
        toast(e.message, 'error');
      }
    };
  });

  el.querySelectorAll('[data-share]').forEach((b) => {
    b.onclick = () => {
      const p = list.find((x) => x.id === b.dataset.share);
      if (!p) return;
      const text = [
        `Aileİzi konum: ${p.name || 'Konum'}`,
        p.note ? `Not: ${p.note}` : '',
        mapsPoint(p.latitude, p.longitude),
      ]
        .filter(Boolean)
        .join('\n');
      shareText(text, p.name || 'Konum');
    };
  });

  el.querySelectorAll('[data-del]').forEach((b) => {
    b.onclick = async () => {
      if (!confirm('Konum silinsin mi?')) return;
      try {
        await deleteDoc(doc(db, 'families', fid, 'places', b.dataset.del));
        toast('Silindi', 'success');
      } catch (e) {
        toast(e.message, 'error');
      }
    };
  });
}

async function addPlaceManual() {
  const name = prompt('Konum adı', 'Konum')?.trim();
  if (!name) return;
  const lat = Number(prompt('Enlem (latitude)', '41.0082'));
  const lng = Number(prompt('Boylam (longitude)', '28.9784'));
  if (!Number.isFinite(lat) || !Number.isFinite(lng)) {
    toast('Geçersiz koordinat', 'error');
    return;
  }
  const note = prompt('Not (isteğe bağlı)', '')?.trim() || '';
  try {
    await ensureParentProfile(auth.currentUser);
    await addDoc(collection(db, 'families', auth.currentUser.uid, 'places'), {
      name,
      latitude: lat,
      longitude: lng,
      note,
      createdAt: serverTimestamp(),
    });
    toast('Konum kaydedildi', 'success');
  } catch (e) {
    toast(e.message || 'Kayıt başarısız', 'error');
  }
}

function renderTrails(el, tool) {
  tool.innerHTML = `<p class="hint">Yeni iz: Harita → Araçlar → İzi kaydet (geçmiş veya canlı takip).</p>`;
  const list = sortByCreated(cache.trails);
  if (!list.length) {
    el.innerHTML = `<div class="empty">Kayıtlı iz yok.</div>`;
    return;
  }
  el.innerHTML = list
    .map((tr) => {
      const pts = tr.points?.length || 0;
      const src =
        tr.source === 'live' ? 'canlı' : tr.source === 'history' ? 'geçmiş' : '';
      return `
      <div class="row">
        <h3>${escapeHtml(tr.name || 'İz')}</h3>
        <div class="meta">${escapeHtml(childName(tr.childId))} · ${pts} nokta${src ? ` · ${src}` : ''}${tr.hours ? ` · ${tr.hours}s` : ''}</div>
        <div class="meta">${fmtTime(tsToDate(tr.createdAt))}</div>
        <div class="row-actions">
          <button class="btn btn-sm btn-outline" data-rename="${tr.id}">Ad</button>
          <button class="btn btn-sm btn-outline" data-share="${tr.id}">Paylaş</button>
          <button class="btn btn-sm btn-outline" data-del="${tr.id}">${t('delete')}</button>
        </div>
      </div>`;
    })
    .join('');

  const fid = auth.currentUser.uid;

  el.querySelectorAll('[data-rename]').forEach((b) => {
    b.onclick = async () => {
      const cur = list.find((x) => x.id === b.dataset.rename);
      const name = prompt('İz adı', cur?.name || '')?.trim();
      if (!name) return;
      try {
        await updateDoc(doc(db, 'families', fid, 'trails', b.dataset.rename), {
          name,
        });
        toast('Güncellendi', 'success');
      } catch (e) {
        toast(e.message, 'error');
      }
    };
  });

  el.querySelectorAll('[data-share]').forEach((b) => {
    b.onclick = () => {
      const tr = list.find((x) => x.id === b.dataset.share);
      if (!tr) return;
      const pts = tr.points || [];
      const text = [
        `Aileİzi iz: ${tr.name || 'İz'}`,
        `Çocuk: ${childName(tr.childId)}`,
        `${pts.length} nokta`,
        pts.length ? mapsDir(pts) : '',
      ]
        .filter(Boolean)
        .join('\n');
      shareText(text, tr.name || 'İz');
    };
  });

  el.querySelectorAll('[data-del]').forEach((b) => {
    b.onclick = async () => {
      if (!confirm('İz silinsin mi?')) return;
      try {
        await deleteDoc(doc(db, 'families', fid, 'trails', b.dataset.del));
        toast('Silindi', 'success');
      } catch (e) {
        toast(e.message, 'error');
      }
    };
  });
}

export function unmountRecords() {
  unsubs.forEach((u) => {
    try {
      u();
    } catch (_) {}
  });
  unsubs = [];
}
