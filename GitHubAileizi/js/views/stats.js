import {
  auth,
  db,
  doc,
  getDoc,
  onSnapshot,
  dateKey,
  tsToDate,
} from '../firebase-app.js';
import { t, escapeHtml, toast } from '../utils.js';

let unsub;
let children = [];

export function mountStats(root) {
  root.innerHTML = `
    <div class="view">
      <div class="panel-title"><h2>${t('nav_screen')}</h2></div>
      <div class="card" style="margin-bottom:12px">
        <div class="field">
          <label>Çocuk</label>
          <select id="stats-child"></select>
        </div>
        <div class="field">
          <label>Tarih</label>
          <input type="date" id="stats-date" />
        </div>
        <button class="btn btn-primary" id="stats-load">Yenile</button>
      </div>
      <div id="stats-series" class="card" style="margin-bottom:12px"></div>
      <div class="card-list" id="stats-list"><div class="empty">${t('no_data')}</div></div>
    </div>
  `;

  const dateInput = root.querySelector('#stats-date');
  dateInput.value = dateKey();

  const fid = auth.currentUser?.uid;
  if (!fid) return;

  unsub = onSnapshot(doc(db, 'families', fid), async (fam) => {
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
    const sel = root.querySelector('#stats-child');
    sel.innerHTML = children
      .map((c) => `<option value="${c.uid}">${escapeHtml(c.name)}</option>`)
      .join('');
    if (children[0]) loadStats();
  });

  root.querySelector('#stats-load').onclick = () => loadStats();
  root.querySelector('#stats-child').onchange = () => loadStats();
  root.querySelector('#stats-date').onchange = () => loadStats();
}

async function loadStats() {
  const fid = auth.currentUser?.uid;
  const childId = document.getElementById('stats-child')?.value;
  const date = document.getElementById('stats-date')?.value;
  if (!fid || !childId || !date) return;

  try {
    const snap = await getDoc(
      doc(db, 'families', fid, 'screen_stats', childId, 'daily', date),
    );
    const list = document.getElementById('stats-list');
    if (!snap.exists()) {
      list.innerHTML = `<div class="empty">${t('no_data')}</div>`;
    } else {
      const apps = snap.data()?.apps || [];
      const max = Math.max(1, ...apps.map((a) => a.totalTimeMinutes || 0));
      apps.sort((a, b) => (b.totalTimeMinutes || 0) - (a.totalTimeMinutes || 0));
      list.innerHTML = apps.length
        ? apps
            .map(
              (a) => `
          <div class="card">
            <h3>${escapeHtml(a.appName || a.packageName || '?')}</h3>
            <div class="meta">${a.totalTimeMinutes || 0} dk</div>
            <div class="stat-bar"><span style="width:${((a.totalTimeMinutes || 0) / max) * 100}%"></span></div>
          </div>`,
            )
            .join('')
        : `<div class="empty">${t('no_data')}</div>`;
    }

    // 7-day series
    const seriesEl = document.getElementById('stats-series');
    const now = new Date(date + 'T12:00:00');
    const bars = [];
    for (let i = 6; i >= 0; i--) {
      const d = new Date(now);
      d.setDate(d.getDate() - i);
      const key = dateKey(d);
      const s = await getDoc(
        doc(db, 'families', fid, 'screen_stats', childId, 'daily', key),
      );
      let total = 0;
      if (s.exists()) {
        for (const a of s.data()?.apps || []) total += a.totalTimeMinutes || 0;
        if (!total) total = s.data()?.totalMinutes || 0;
      }
      bars.push({ key, total });
    }
    const maxT = Math.max(1, ...bars.map((b) => b.total));
    seriesEl.innerHTML = `
      <h3 style="margin:0 0 10px">Son 7 gün</h3>
      <div style="display:flex;align-items:flex-end;gap:6px;height:100px">
        ${bars
          .map(
            (b) =>
              `<div title="${b.key}: ${b.total} dk" style="flex:1;background:var(--parent-accent);height:${(b.total / maxT) * 100}%;border-radius:6px 6px 2px 2px;min-height:4px"></div>`,
          )
          .join('')}
      </div>
      <div class="meta" style="margin-top:8px">${bars.map((b) => b.total).join(' · ')} dk</div>
    `;
  } catch (e) {
    toast(e.message, 'error');
  }
}

export function unmountStats() {
  if (unsub) unsub();
  unsub = null;
}
