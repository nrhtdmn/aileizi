import {
  auth,
  db,
  collection,
  onSnapshot,
  updateDoc,
  deleteDoc,
  doc,
  serverTimestamp,
  deleteField,
  ensureParentProfile,
  tsToDate,
} from '../firebase-app.js';
import { t, fmtTime, toast, escapeHtml, notifyBrowser } from '../utils.js';
import { focusMapOn } from './map.js';

let unsub;
const seen = new Set();

export function mountSos(root, { onOpenMap } = {}) {
  root.innerHTML = `
    <div class="view">
      <div class="panel-title"><h2>SOS</h2></div>
      <div class="card-list" id="sos-list"><div class="empty">${t('loading')}</div></div>
    </div>
  `;
  const fid = auth.currentUser?.uid;
  if (!fid) return;

  unsub = onSnapshot(collection(db, 'families', fid, 'sos_events'), (snap) => {
    const list = [];
    snap.forEach((d) => list.push({ id: d.id, ...d.data() }));
    list.sort((a, b) => {
      const ta = tsToDate(a.timestamp)?.getTime() || 0;
      const tb = tsToDate(b.timestamp)?.getTime() || 0;
      return tb - ta;
    });
    const top = list.slice(0, 30);
    for (const e of top) {
      if (!e.acknowledged && !seen.has(e.id)) {
        seen.add(e.id);
        notifyBrowser('SOS!', `${e.childName || 'Çocuk'} yardım istiyor`, e.id);
      }
    }
    render(top, onOpenMap);
  });
}

function render(list, onOpenMap) {
  const el = document.getElementById('sos-list');
  if (!el) return;
  if (!list.length) {
    el.innerHTML = `<div class="empty">Aktif SOS yok</div>`;
    return;
  }
  el.innerHTML = list
    .map((e) => {
      const ack = e.acknowledged;
      return `
      <div class="card">
        <h3>${escapeHtml(e.childName || 'Çocuk')}
          <span class="badge ${ack ? '' : 'danger'}">${ack ? 'Onaylandı' : 'AKTİF'}</span>
        </h3>
        <div class="meta">${fmtTime(tsToDate(e.timestamp))}</div>
        <div class="meta">${e.hasLocation === false ? 'Konum yok' : `${e.latitude?.toFixed?.(5)}, ${e.longitude?.toFixed?.(5)}`}</div>
        <div class="row-actions">
          ${!ack ? `<button class="btn btn-sm btn-primary" data-ack="${e.id}">${t('acknowledge')}</button>` : `<button class="btn btn-sm btn-outline" data-react="${e.id}">Yeniden aktif</button>`}
          <button class="btn btn-sm btn-outline" data-map="${e.id}">Haritada aç</button>
          <button class="btn btn-sm btn-danger" data-del="${e.id}">${t('delete')}</button>
        </div>
      </div>`;
    })
    .join('');

  el.querySelectorAll('[data-ack]').forEach((b) => {
    b.onclick = async () => {
      try {
        await updateDoc(doc(db, 'families', auth.currentUser.uid, 'sos_events', b.dataset.ack), {
          acknowledged: true,
          acknowledgedBy: auth.currentUser.uid,
          acknowledgedAt: serverTimestamp(),
        });
        toast('SOS onaylandı', 'success');
      } catch (err) {
        toast(err.message, 'error');
      }
    };
  });
  el.querySelectorAll('[data-react]').forEach((b) => {
    b.onclick = async () => {
      try {
        await ensureParentProfile(auth.currentUser);
        await updateDoc(doc(db, 'families', auth.currentUser.uid, 'sos_events', b.dataset.react), {
          acknowledged: false,
          acknowledgedBy: deleteField(),
          acknowledgedAt: deleteField(),
        });
      } catch (err) {
        toast(err.message, 'error');
      }
    };
  });
  el.querySelectorAll('[data-del]').forEach((b) => {
    b.onclick = async () => {
      if (!confirm('SOS silinsin mi?')) return;
      try {
        await deleteDoc(doc(db, 'families', auth.currentUser.uid, 'sos_events', b.dataset.del));
      } catch (err) {
        toast(err.message, 'error');
      }
    };
  });
  el.querySelectorAll('[data-map]').forEach((b) => {
    b.onclick = () => {
      const e = list.find((x) => x.id === b.dataset.map);
      if (!e) return;
      if (onOpenMap) onOpenMap(e.latitude, e.longitude);
      else focusMapOn(e.latitude, e.longitude);
    };
  });
}

export function unmountSos() {
  if (unsub) unsub();
  unsub = null;
}
