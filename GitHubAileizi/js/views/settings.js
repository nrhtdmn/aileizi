import {
  auth,
  db,
  doc,
  collection,
  onSnapshot,
  setDoc,
  updateDoc,
  deleteDoc,
  getDoc,
  query,
  where,
  arrayRemove,
  deleteField,
  serverTimestamp,
  Timestamp,
  ensureParentProfile,
  signOut,
  updatePassword,
  EmailAuthProvider,
  reauthenticateWithCredential,
  describeError,
  tsToDate,
} from '../firebase-app.js';
import { Brand } from '../config.js';
import { t, setLang, getLang, fmtTime, toast, escapeHtml } from '../utils.js';

let unsubs = [];

export function mountSettings(root) {
  const user = auth.currentUser;
  root.innerHTML = `
    <div class="view">
      <div class="panel-title"><h2>${t('nav_settings')}</h2></div>
      <div class="card" style="margin-bottom:12px">
        <h3>${escapeHtml(user?.displayName || 'Ebeveyn')}</h3>
        <div class="meta">${escapeHtml(user?.email || '')}</div>
        <div class="row-actions" style="margin-top:12px">
          <button class="btn btn-sm btn-outline" id="lang-tr">TR</button>
          <button class="btn btn-sm btn-outline" id="lang-en">EN</button>
          <button class="btn btn-sm btn-danger" id="btn-logout">${t('logout')}</button>
        </div>
      </div>

      <div class="card" style="margin-bottom:12px">
        <h3>Davet kodu</h3>
        <p class="meta">Çocuk uygulaması veya web çocuk modu için 6 haneli kod (24 saat).</p>
        <button class="btn btn-primary" id="btn-invite">${t('invite')}</button>
        <div id="invite-code" style="font-size:2rem;font-weight:900;letter-spacing:.2em;margin:12px 0;color:var(--parent-primary)"></div>
        <div class="card-list" id="active-invites"></div>
      </div>

      <div class="card" style="margin-bottom:12px">
        <h3>${t('children')}</h3>
        <div class="card-list" id="settings-children"></div>
      </div>

      <div class="card" style="margin-bottom:12px">
        <h3>Dijital ebeveynlik</h3>
        <div class="field"><label>Çocuk</label><select id="pol-child"></select></div>
        <div class="field"><label>Günlük ekran limiti (dk, boş=yok)</label><input id="pol-limit" type="number" min="0" /></div>
        <div class="field"><label>Yatış başlangıç (HH:MM)</label><input id="pol-bed-start" placeholder="22:00" /></div>
        <div class="field"><label>Yatış bitiş (HH:MM)</label><input id="pol-bed-end" placeholder="07:00" /></div>
        <button class="btn btn-primary" id="pol-save">Politikayı kaydet</button>
      </div>

      <div class="card">
        <h3>Şifre değiştir</h3>
        <div class="field"><label>Mevcut şifre</label><input type="password" id="pw-cur" /></div>
        <div class="field"><label>Yeni şifre</label><input type="password" id="pw-new" /></div>
        <button class="btn btn-outline" id="pw-save">Güncelle</button>
      </div>

      <p class="meta" style="margin-top:16px;text-align:center">${Brand.fullName} · Web PWA</p>
    </div>
  `;

  root.querySelector('#lang-tr').onclick = () => {
    setLang('tr');
    toast('Türkçe');
    location.reload();
  };
  root.querySelector('#lang-en').onclick = () => {
    setLang('en');
    toast('English');
    location.reload();
  };
  root.querySelector('#btn-logout').onclick = async () => {
    await signOut(auth);
  };
  root.querySelector('#btn-invite').onclick = () => createInvite();
  root.querySelector('#pw-save').onclick = () => changePw();
  root.querySelector('#pol-save').onclick = () => savePolicies();
  root.querySelector('#pol-child').onchange = () => loadPolicies();

  const fid = user.uid;
  const u1 = onSnapshot(doc(db, 'families', fid), async (fam) => {
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
    renderChildren(list);
    const sel = document.getElementById('pol-child');
    sel.innerHTML = list
      .map((c) => `<option value="${c.uid}">${escapeHtml(c.name)}</option>`)
      .join('');
    if (list[0]) loadPolicies();
  });
  unsubs.push(u1);

  const u2 = onSnapshot(
    query(collection(db, 'invites'), where('familyId', '==', fid)),
    (snap) => {
      const now = Date.now();
      const list = [];
      snap.forEach((d) => {
        const m = d.data();
        if (m.used) return;
        const exp = tsToDate(m.expiresAt);
        if (exp && exp.getTime() < now) return;
        list.push({ code: d.id, ...m, expiresAt: exp });
      });
      list.sort(
        (a, b) =>
          (tsToDate(b.createdAt)?.getTime() || 0) -
          (tsToDate(a.createdAt)?.getTime() || 0),
      );
      const el = document.getElementById('active-invites');
      if (!el) return;
      el.innerHTML = list.length
        ? list
            .map(
              (i) => `
          <div class="card" style="margin-top:8px">
            <strong style="letter-spacing:.15em">${i.code}</strong>
            <div class="meta">bitiş: ${fmtTime(i.expiresAt)}</div>
            <div class="row-actions">
              <button class="btn btn-sm btn-outline" data-copy="${i.code}">Kopyala</button>
              <button class="btn btn-sm btn-outline" data-share="${i.code}">Paylaş</button>
              <button class="btn btn-sm btn-danger" data-del-inv="${i.code}">Sil</button>
            </div>
          </div>`,
            )
            .join('')
        : `<div class="meta" style="margin-top:8px">Aktif davet yok</div>`;

      el.querySelectorAll('[data-copy]').forEach((b) => {
        b.onclick = () => {
          navigator.clipboard?.writeText(b.dataset.copy);
          toast('Kopyalandı', 'success');
        };
      });
      el.querySelectorAll('[data-share]').forEach((b) => {
        b.onclick = async () => {
          const text = `Aileİzi davet kodu: ${b.dataset.share}`;
          if (navigator.share) {
            try {
              await navigator.share({ title: 'Aileİzi', text });
            } catch (_) {}
          } else {
            navigator.clipboard?.writeText(text);
            toast('Kopyalandı', 'success');
          }
        };
      });
      el.querySelectorAll('[data-del-inv]').forEach((b) => {
        b.onclick = async () => {
          try {
            await deleteDoc(doc(db, 'invites', b.dataset.delInv));
          } catch (e) {
            toast(describeError(e), 'error');
          }
        };
      });
    },
  );
  unsubs.push(u2);

  // highlight lang
  document.getElementById(getLang() === 'en' ? 'lang-en' : 'lang-tr')?.classList.add('btn-primary');
}

function renderChildren(list) {
  const el = document.getElementById('settings-children');
  if (!el) return;
  if (!list.length) {
    el.innerHTML = `<div class="empty">Henüz çocuk bağlı değil. Davet kodu oluşturun.</div>`;
    return;
  }
  el.innerHTML = list
    .map(
      (c) => `
    <div class="card">
      <h3>${escapeHtml(c.name)}</h3>
      <div class="row-actions">
        <button class="btn btn-sm btn-outline" data-rename="${c.uid}">Yeniden adlandır</button>
        <button class="btn btn-sm btn-danger" data-remove="${c.uid}">Aileden çıkar</button>
      </div>
    </div>`,
    )
    .join('');

  el.querySelectorAll('[data-rename]').forEach((b) => {
    b.onclick = async () => {
      const name = prompt('Yeni ad')?.trim();
      if (!name) return;
      try {
        await ensureParentProfile(auth.currentUser);
        await updateDoc(doc(db, 'users', b.dataset.rename), {
          name,
          updatedAt: serverTimestamp(),
        });
        toast('Güncellendi', 'success');
      } catch (e) {
        toast(describeError(e), 'error');
      }
    };
  });
  el.querySelectorAll('[data-remove]').forEach((b) => {
    b.onclick = async () => {
      if (!confirm('Çocuk aileden çıkarılsın mı?')) return;
      const childId = b.dataset.remove;
      const fid = auth.currentUser.uid;
      try {
        await ensureParentProfile(auth.currentUser);
        await updateDoc(doc(db, 'families', fid), {
          childIds: arrayRemove(childId),
          memberIds: arrayRemove(childId),
        });
        try {
          await updateDoc(doc(db, 'users', childId), {
            familyId: deleteField(),
            locationSharingEnabled: false,
            updatedAt: serverTimestamp(),
          });
        } catch (_) {}
        toast('Çıkarıldı', 'success');
      } catch (e) {
        toast(describeError(e), 'error');
      }
    };
  });
}

async function createInvite() {
  try {
    await ensureParentProfile(auth.currentUser);
    const code = String(100000 + (Date.now() % 900000));
    await setDoc(doc(db, 'invites', code), {
      familyId: auth.currentUser.uid,
      createdBy: auth.currentUser.uid,
      createdAt: serverTimestamp(),
      expiresAt: Timestamp.fromDate(new Date(Date.now() + 24 * 3600 * 1000)),
      used: false,
    });
    const el = document.getElementById('invite-code');
    if (el) el.textContent = code;
    toast('Davet kodu oluşturuldu', 'success');
    if (navigator.share) {
      try {
        await navigator.share({
          title: 'Aileİzi',
          text: `Aileİzi davet kodu: ${code}`,
        });
      } catch (_) {}
    }
  } catch (e) {
    toast(describeError(e), 'error');
  }
}

async function changePw() {
  const cur = document.getElementById('pw-cur')?.value;
  const neu = document.getElementById('pw-new')?.value;
  if (!cur || !neu || neu.length < 6) {
    toast('Şifreleri kontrol edin', 'error');
    return;
  }
  try {
    const user = auth.currentUser;
    const cred = EmailAuthProvider.credential(user.email, cur);
    await reauthenticateWithCredential(user, cred);
    await updatePassword(user, neu);
    toast('Şifre güncellendi', 'success');
  } catch (e) {
    toast(describeError(e), 'error');
  }
}

async function loadPolicies() {
  const childId = document.getElementById('pol-child')?.value;
  if (!childId) return;
  try {
    const snap = await getDoc(
      doc(db, 'families', auth.currentUser.uid, 'child_policies', childId),
    );
    const p = snap.data() || {};
    document.getElementById('pol-limit').value = p.dailyScreenLimitMinutes ?? '';
    document.getElementById('pol-bed-start').value = p.bedTimeStart || '';
    document.getElementById('pol-bed-end').value = p.bedTimeEnd || '';
  } catch (_) {}
}

async function savePolicies() {
  const childId = document.getElementById('pol-child')?.value;
  if (!childId) return;
  const limitRaw = document.getElementById('pol-limit').value;
  try {
    await ensureParentProfile(auth.currentUser);
    await setDoc(
      doc(db, 'families', auth.currentUser.uid, 'child_policies', childId),
      {
        childId,
        dailyScreenLimitMinutes: limitRaw === '' ? null : Number(limitRaw),
        bedTimeStart: document.getElementById('pol-bed-start').value.trim() || null,
        bedTimeEnd: document.getElementById('pol-bed-end').value.trim() || null,
        updatedAt: serverTimestamp(),
      },
      { merge: true },
    );
    toast('Politika kaydedildi', 'success');
  } catch (e) {
    toast(describeError(e), 'error');
  }
}

export function unmountSettings() {
  unsubs.forEach((u) => u());
  unsubs = [];
}
