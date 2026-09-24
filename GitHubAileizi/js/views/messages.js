import {
  auth,
  db,
  collection,
  doc,
  onSnapshot,
  addDoc,
  updateDoc,
  getDocs,
  query,
  where,
  orderBy,
  limit,
  serverTimestamp,
  writeBatch,
  ensureParentProfile,
  storage,
  storageRef,
  uploadBytes,
  getDownloadURL,
  getDoc,
  tsToDate,
} from '../firebase-app.js';
import { t, fmtTime, toast, escapeHtml, notifyBrowser } from '../utils.js';

let unsubs = [];
let children = [];
let activeChildId = null;

export function mountMessages(root) {
  root.innerHTML = `
    <div class="view">
      <div class="panel-title"><h2>${t('nav_messages')}</h2></div>
      <div class="chat-layout">
        <div class="chat-threads" id="threads"></div>
        <div class="chat-pane">
          <div class="chat-msgs" id="msgs"><div class="empty">Çocuk seçin</div></div>
          <div class="chat-compose">
            <input type="file" id="chat-file" accept="image/*" hidden />
            <button class="btn btn-sm btn-outline" id="btn-img" title="Fotoğraf">📷</button>
            <button class="btn btn-sm btn-outline" id="btn-loc" title="Konum">📍</button>
            <input id="chat-input" placeholder="Mesaj yaz…" />
            <button class="btn btn-sm btn-primary" id="btn-send">${t('send')}</button>
          </div>
        </div>
      </div>
    </div>
  `;

  const fid = auth.currentUser?.uid;
  if (!fid) return;

  const u1 = onSnapshot(doc(db, 'families', fid), async (fam) => {
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
    renderThreads();
    if (!activeChildId && children[0]) selectChild(children[0].uid);
  });
  unsubs.push(u1);

  root.querySelector('#btn-send').onclick = () => sendText();
  root.querySelector('#chat-input').onkeydown = (e) => {
    if (e.key === 'Enter') sendText();
  };
  root.querySelector('#btn-img').onclick = () => root.querySelector('#chat-file').click();
  root.querySelector('#chat-file').onchange = (e) => {
    const file = e.target.files?.[0];
    if (file) sendImage(file);
    e.target.value = '';
  };
  root.querySelector('#btn-loc').onclick = () => sendLocation();
}

function renderThreads() {
  const el = document.getElementById('threads');
  if (!el) return;
  if (!children.length) {
    el.innerHTML = `<div class="empty">Henüz çocuk yok</div>`;
    return;
  }
  el.innerHTML = children
    .map(
      (c) => `
    <button type="button" class="thread-item ${activeChildId === c.uid ? 'active' : ''}" data-id="${c.uid}">
      <strong>${escapeHtml(c.name)}</strong>
      <div class="meta" id="preview-${c.uid}">…</div>
    </button>`,
    )
    .join('');
  el.querySelectorAll('.thread-item').forEach((b) => {
    b.onclick = () => selectChild(b.dataset.id);
  });

  // previews
  const fid = auth.currentUser.uid;
  children.forEach((c) => {
    const qy = query(
      collection(db, 'families', fid, 'chats', c.uid, 'messages'),
      orderBy('createdAt', 'desc'),
      limit(1),
    );
    getDocs(qy).then((snap) => {
      const prev = document.getElementById(`preview-${c.uid}`);
      if (!prev) return;
      if (snap.empty) {
        prev.textContent = 'Mesaj yok';
        return;
      }
      const m = snap.docs[0].data();
      prev.textContent = m.text || m.type || '';
    });
  });
}

let msgUnsub = null;
function selectChild(id) {
  activeChildId = id;
  renderThreads();
  if (msgUnsub) msgUnsub();
  const fid = auth.currentUser.uid;
  const qy = query(
    collection(db, 'families', fid, 'chats', id, 'messages'),
    orderBy('createdAt', 'asc'),
    limit(200),
  );
  msgUnsub = onSnapshot(qy, (snap) => {
    const msgs = [];
    snap.forEach((d) => msgs.push({ id: d.id, ...d.data() }));
    const box = document.getElementById('msgs');
    if (!box) return;
    if (!msgs.length) {
      box.innerHTML = `<div class="empty">Henüz mesaj yok</div>`;
    } else {
      box.innerHTML = msgs
        .map((m) => {
          const role = m.senderRole === 'parent' ? 'parent' : 'child';
          let body = escapeHtml(m.text || '');
          if (m.type === 'image' && m.imageUrl) {
            body += `<img src="${escapeHtml(m.imageUrl)}" alt="" />`;
          }
          if (m.type === 'location' && m.latitude != null) {
            body += `<div class="meta">📍 ${m.latitude.toFixed(5)}, ${m.longitude.toFixed(5)}</div>`;
          }
          if (m.type === 'route' && m.routeName) {
            body += `<div class="meta">🛣 ${escapeHtml(m.routeName)}</div>`;
          }
          return `<div class="bubble ${role}">${body}<div class="meta" style="opacity:.7;font-size:.7rem;margin-top:4px">${fmtTime(tsToDate(m.createdAt))}</div></div>`;
        })
        .join('');
      box.scrollTop = box.scrollHeight;
    }
    markRead(id);
    const unread = msgs.filter((m) => m.senderRole === 'child' && !m.readByParent);
    if (unread.length) {
      notifyBrowser('Yeni mesaj', unread[unread.length - 1].text || 'Mesaj', `chat-${id}`);
    }
  });
}

async function markRead(childId) {
  try {
    const fid = auth.currentUser.uid;
    const snap = await getDocs(
      query(
        collection(db, 'families', fid, 'chats', childId, 'messages'),
        where('readByParent', '==', false),
        limit(50),
      ),
    );
    if (snap.empty) return;
    const batch = writeBatch(db);
    snap.forEach((d) => batch.update(d.ref, { readByParent: true }));
    await batch.commit();
  } catch (_) {}
}

async function sendText() {
  const input = document.getElementById('chat-input');
  const text = input?.value?.trim();
  if (!text || !activeChildId) return;
  try {
    await ensureParentProfile(auth.currentUser);
    await addDoc(
      collection(db, 'families', auth.currentUser.uid, 'chats', activeChildId, 'messages'),
      {
        childId: activeChildId,
        senderId: auth.currentUser.uid,
        senderRole: 'parent',
        type: 'text',
        text,
        createdAt: serverTimestamp(),
        readByParent: true,
        readByChild: false,
      },
    );
    input.value = '';
  } catch (e) {
    toast(e.message, 'error');
  }
}

async function sendImage(file) {
  if (!activeChildId) return;
  if (file.size > 7 * 1024 * 1024) {
    toast('Fotoğraf çok büyük', 'error');
    return;
  }
  try {
    await ensureParentProfile(auth.currentUser);
    const fid = auth.currentUser.uid;
    const name = `${Date.now()}_${fid}.jpg`;
    const ref = storageRef(storage, `families/${fid}/chats/${activeChildId}/${name}`);
    await uploadBytes(ref, file, { contentType: file.type || 'image/jpeg' });
    const url = await getDownloadURL(ref);
    await addDoc(collection(db, 'families', fid, 'chats', activeChildId, 'messages'), {
      childId: activeChildId,
      senderId: fid,
      senderRole: 'parent',
      type: 'image',
      text: '',
      imageUrl: url,
      createdAt: serverTimestamp(),
      readByParent: true,
      readByChild: false,
    });
    toast('Fotoğraf gönderildi', 'success');
  } catch (e) {
    toast(e.message || 'Yükleme hatası', 'error');
  }
}

async function sendLocation() {
  if (!activeChildId) return;
  if (!navigator.geolocation) {
    toast('Konum desteklenmiyor', 'error');
    return;
  }
  navigator.geolocation.getCurrentPosition(
    async (pos) => {
      try {
        await ensureParentProfile(auth.currentUser);
        await addDoc(
          collection(db, 'families', auth.currentUser.uid, 'chats', activeChildId, 'messages'),
          {
            childId: activeChildId,
            senderId: auth.currentUser.uid,
            senderRole: 'parent',
            type: 'location',
            text: 'Konum paylaşıldı',
            latitude: pos.coords.latitude,
            longitude: pos.coords.longitude,
            createdAt: serverTimestamp(),
            readByParent: true,
            readByChild: false,
          },
        );
      } catch (e) {
        toast(e.message, 'error');
      }
    },
    () => toast('Konum alınamadı', 'error'),
    { enableHighAccuracy: true },
  );
}

export function unmountMessages() {
  unsubs.forEach((u) => u());
  unsubs = [];
  if (msgUnsub) msgUnsub();
  msgUnsub = null;
}
