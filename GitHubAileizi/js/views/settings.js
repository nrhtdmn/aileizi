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
import { t, setLang, getLang, fmtTime, toast, escapeHtml } from '../utils.js';
import { getAlertPrefs, setAlertPrefs } from '../alerts.js';

let unsubs = [];
let childrenCache = [];

export function mountSettings(root) {
  const user = auth.currentUser;
  const prefs = getAlertPrefs();

  root.innerHTML = `
    <div class="view">
      <div class="panel-title"><h2>${t('nav_settings')}</h2></div>

      <div class="row section">
        <h3>${escapeHtml(user?.displayName || 'Ebeveyn')}</h3>
        <div class="meta">${escapeHtml(user?.email || '')}</div>
        <div class="row-actions">
          <button class="btn btn-sm btn-outline" id="lang-tr" type="button">TR</button>
          <button class="btn btn-sm btn-outline" id="lang-en" type="button">EN</button>
          <button class="btn btn-sm btn-outline" id="btn-logout" type="button">${t('logout')}</button>
        </div>
      </div>

      <div class="settings-menu">
        <button type="button" class="menu-item" data-panel="notify">
          <span>Anlık bildirimler</span><span class="chev">›</span>
        </button>
        <button type="button" class="menu-item" data-panel="invite">
          <span>Davet kodu</span><span class="chev">›</span>
        </button>
        <button type="button" class="menu-item" data-panel="family">
          <span>Aile · çocuklar &amp; sağlık</span><span class="chev">›</span>
        </button>
        <button type="button" class="menu-item" data-panel="tips">
          <span>İpuçları</span><span class="chev">›</span>
        </button>
        <button type="button" class="menu-item" id="btn-open-pw">
          <span>Şifre değiştir</span><span class="chev">›</span>
        </button>
      </div>

      <div class="settings-panel hidden" id="panel-notify">
        <button type="button" class="link-back" data-back>← Geri</button>
        <h3>Anlık bildirimler</h3>
        <p class="meta" style="margin:4px 0 10px">Tarayıcı izni gerekir; sekme açıkken anında gelir.</p>
        <label class="check-row"><input type="checkbox" id="pref-sos" ${prefs.sos ? 'checked' : ''}/> SOS</label>
        <label class="check-row"><input type="checkbox" id="pref-chat" ${prefs.chat ? 'checked' : ''}/> Mesajlar</label>
        <label class="check-row"><input type="checkbox" id="pref-geo" ${prefs.geofence ? 'checked' : ''}/> Bölge giriş/çıkış</label>
        <label class="check-row"><input type="checkbox" id="pref-route" ${prefs.route ? 'checked' : ''}/> Rota sapması</label>
        <label class="check-row"><input type="checkbox" id="pref-bat" ${prefs.batteryLow ? 'checked' : ''}/> Düşük pil</label>
        <label class="check-row"><input type="checkbox" id="pref-sound" ${prefs.sound ? 'checked' : ''}/> Ses</label>
        <button class="btn btn-primary" id="btn-notif" type="button" style="margin-top:10px">Bildirim izni iste</button>
      </div>

      <div class="settings-panel hidden" id="panel-invite">
        <button type="button" class="link-back" data-back>← Geri</button>
        <h3>Davet kodu</h3>
        <p class="meta" style="margin:4px 0 10px">6 haneli kod, 24 saat geçerli.</p>
        <button class="btn btn-primary" id="btn-invite" type="button">${t('invite')}</button>
        <div id="invite-code" class="invite-code"></div>
        <div class="list" id="active-invites"></div>
      </div>

      <div class="settings-panel hidden" id="panel-family">
        <button type="button" class="link-back" data-back>← Geri</button>
        <h3>Bağlı çocuklar</h3>
        <div class="list" id="settings-children" style="margin-top:8px"></div>
        <h3 style="margin-top:18px">Sağlık özeti</h3>
        <p class="meta" style="margin:4px 0 8px">Son görülme, pil ve konum paylaşımı.</p>
        <div class="list" id="health-list"><div class="empty">Yükleniyor…</div></div>
      </div>

      <div class="settings-panel hidden" id="panel-tips">
        <button type="button" class="link-back" data-back>← Geri</button>
        <h3>İpuçları</h3>
        <ul class="tips">
          <li>Çocuk uygulamasını arka planda açık tut — konum ve SOS için.</li>
          <li>Harita’da noktaya tıkla → «+ Bölge» ile güvenli alan ekle.</li>
          <li>Okul yolu için rota çiz; sapma eşiğini Rotalar’dan ayarla.</li>
          <li>Bu sekmeyi açık bırakırsan bildirimler anında gelir.</li>
        </ul>
      </div>
    </div>

    <div class="modal-backdrop hidden" id="pw-modal">
      <div class="modal-card" role="dialog" aria-labelledby="pw-title">
        <h3 id="pw-title">Şifre değiştir</h3>
        <div class="field"><label>Mevcut şifre</label><input type="password" id="pw-cur" /></div>
        <div class="field"><label>Yeni şifre</label><input type="password" id="pw-new" /></div>
        <div class="row-actions" style="margin-top:8px">
          <button class="btn btn-outline" id="pw-cancel" type="button">İptal</button>
          <button class="btn btn-primary" id="pw-save" type="button" style="width:auto">Kaydet</button>
        </div>
      </div>
    </div>
  `;

  const menu = root.querySelector('.settings-menu');
  const showPanel = (id) => {
    menu.classList.add('hidden');
    root.querySelectorAll('.settings-panel').forEach((p) => p.classList.add('hidden'));
    if (id) root.querySelector(`#panel-${id}`)?.classList.remove('hidden');
    else menu.classList.remove('hidden');
  };

  root.querySelectorAll('.menu-item[data-panel]').forEach((b) => {
    b.onclick = () => showPanel(b.dataset.panel);
  });
  root.querySelectorAll('[data-back]').forEach((b) => {
    b.onclick = () => showPanel(null);
  });

  const bindPref = (id, key) => {
    root.querySelector(id).onchange = (e) => {
      setAlertPrefs({ [key]: e.target.checked });
      toast('Kaydedildi', 'success');
    };
  };
  bindPref('#pref-sos', 'sos');
  bindPref('#pref-chat', 'chat');
  bindPref('#pref-geo', 'geofence');
  bindPref('#pref-route', 'route');
  bindPref('#pref-bat', 'batteryLow');
  bindPref('#pref-sound', 'sound');

  root.querySelector('#btn-notif').onclick = async () => {
    if (!('Notification' in window)) {
      toast('Bu tarayıcı bildirim desteklemiyor', 'error');
      return;
    }
    const r = await Notification.requestPermission();
    toast(r === 'granted' ? 'Bildirimler açık' : 'İzin verilmedi', r === 'granted' ? 'success' : 'error');
    if (r === 'granted') {
      new Notification('Aileİzi', {
        body: 'Bildirimler hazır',
        icon: './assets/icons/icon-192.png',
      });
    }
  };

  const modal = root.querySelector('#pw-modal');
  root.querySelector('#btn-open-pw').onclick = () => modal.classList.remove('hidden');
  root.querySelector('#pw-cancel').onclick = () => modal.classList.add('hidden');
  modal.onclick = (e) => {
    if (e.target === modal) modal.classList.add('hidden');
  };
  root.querySelector('#pw-save').onclick = async () => {
    await changePw();
    modal.classList.add('hidden');
  };

  root.querySelector('#lang-tr').onclick = () => {
    setLang('tr');
    location.reload();
  };
  root.querySelector('#lang-en').onclick = () => {
    setLang('en');
    location.reload();
  };
  root.querySelector('#btn-logout').onclick = async () => {
    await signOut(auth);
  };
  root.querySelector('#btn-invite').onclick = () => createInvite();

  const fid = user.uid;
  const u1 = onSnapshot(doc(db, 'families', fid), async (fam) => {
    const ids = fam.data()?.childIds || [];
    const list = [];
    for (const id of ids) {
      try {
        const u = await getDoc(doc(db, 'users', id));
        list.push({
          uid: id,
          name: u.data()?.name || id.slice(0, 6),
          sharing: u.data()?.locationSharingEnabled !== false,
        });
      } catch {
        list.push({ uid: id, name: id.slice(0, 6), sharing: true });
      }
    }
    childrenCache = list;
    renderChildren(list);
    renderHealth(fid, list);
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
          <div class="row" style="margin-top:8px">
            <strong class="invite-code" style="font-size:1.2rem;margin:0">${i.code}</strong>
            <div class="meta">bitiş: ${fmtTime(i.expiresAt)}</div>
            <div class="row-actions">
              <button class="btn btn-sm btn-outline" data-copy="${i.code}">Kopyala</button>
              <button class="btn btn-sm btn-outline" data-share="${i.code}">Paylaş</button>
              <button class="btn btn-sm btn-outline" data-del-inv="${i.code}">Sil</button>
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

  document.getElementById(getLang() === 'en' ? 'lang-en' : 'lang-tr')?.classList.add('btn-primary');
}

async function renderHealth(fid, list) {
  const el = document.getElementById('health-list');
  if (!el) return;
  if (!list.length) {
    el.innerHTML = `<div class="empty">Çocuk yok</div>`;
    return;
  }
  const rows = [];
  for (const c of list) {
    let last = '—';
    let bat = '—';
    let online = false;
    try {
      const st = await getDoc(doc(db, 'families', fid, 'device_status', c.uid));
      if (st.exists()) {
        const d = st.data();
        last = fmtTime(tsToDate(d.lastSeen));
        bat = d.batteryLevel != null ? `%${d.batteryLevel}` : '—';
        online = d.isOnline === true;
      }
    } catch (_) {}
    rows.push(`
      <div class="row">
        <h3>${escapeHtml(c.name)} <span class="badge ${online ? '' : 'warn'}">${online ? 'Çevrimiçi' : 'Çevrimdışı'}</span></h3>
        <div class="meta">Son görülme: ${last} · Pil: ${bat} · Konum: ${c.sharing ? 'açık' : 'kapalı'}</div>
      </div>`);
  }
  el.innerHTML = rows.join('');
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
    <div class="row">
      <h3>${escapeHtml(c.name)}</h3>
      <div class="row-actions">
        <button class="btn btn-sm btn-outline" data-rename="${c.uid}">Ad</button>
        <button class="btn btn-sm btn-outline" data-remove="${c.uid}">Çıkar</button>
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
      if (!confirm('Çocuk aileden çıkarılsın mı? Konum kayıtları da silinir.')) return;
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
        try {
          await deleteDoc(doc(db, 'families', fid, 'locations', childId));
        } catch (_) {}
        try {
          await deleteDoc(doc(db, 'families', fid, 'device_status', childId));
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
    document.getElementById('pw-cur').value = '';
    document.getElementById('pw-new').value = '';
  } catch (e) {
    toast(describeError(e), 'error');
  }
}

export function unmountSettings() {
  unsubs.forEach((u) => u());
  unsubs = [];
}
