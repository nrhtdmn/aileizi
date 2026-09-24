import {
  auth,
  db,
  collection,
  doc,
  onSnapshot,
  updateDoc,
  deleteDoc,
  getDoc,
  ensureParentProfile,
  serverTimestamp,
  deleteField,
  tsToDate,
} from '../firebase-app.js';
import { t, fmtTime, toast, escapeHtml } from '../utils.js';

let unsub;
let unsubFam;
let children = [];

export function mountRoutes(root) {
  root.innerHTML = `
    <div class="view">
      <div class="panel-title">
        <h2>Rotalar</h2>
      </div>
      <p class="meta" style="margin:-4px 0 12px">Çizilen / kaydedilen rotaları yönet. Sapma bildirimleri Ayar’dan açılır.</p>
      <div class="list" id="routes-list"><div class="empty">${t('loading')}</div></div>
    </div>
  `;

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

  unsub = onSnapshot(collection(db, 'families', fid, 'routes'), (snap) => {
    const list = [];
    snap.forEach((d) => list.push({ id: d.id, ...d.data() }));
    list.sort(
      (a, b) =>
        (tsToDate(b.createdAt)?.getTime() || 0) -
        (tsToDate(a.createdAt)?.getTime() || 0),
    );
    render(list);
  });
}

function childName(id) {
  return children.find((c) => c.uid === id)?.name || (id || '').slice(0, 6);
}

function render(list) {
  const el = document.getElementById('routes-list');
  if (!el) return;
  if (!list.length) {
    el.innerHTML = `<div class="empty">Rota yok. Harita → Rota ile çizebilirsin.</div>`;
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
            : {
                cancelledAt: serverTimestamp(),
                cancelledBy: 'parent',
              }),
        });
        toast(active ? 'Rota aktif' : 'Rota durduruldu', 'success');
      } catch (e) {
        toast(e.message, 'error');
      }
    };
  });

  el.querySelectorAll('[data-rename]').forEach((b) => {
    b.onclick = async () => {
      const name = prompt('Yeni rota adı')?.trim();
      if (!name) return;
      try {
        await updateDoc(doc(db, 'families', fid, 'routes', b.dataset.rename), {
          name,
        });
      } catch (e) {
        toast(e.message, 'error');
      }
    };
  });

  el.querySelectorAll('[data-thresh]').forEach((b) => {
    b.onclick = async () => {
      const v = Number(prompt('Sapma eşiği (metre)', '80'));
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

export function unmountRoutes() {
  if (unsub) unsub();
  if (unsubFam) unsubFam();
  unsub = unsubFam = null;
}
