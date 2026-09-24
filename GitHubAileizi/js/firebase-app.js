import { initializeApp } from 'https://www.gstatic.com/firebasejs/10.14.1/firebase-app.js';
import {
  getAuth,
  onAuthStateChanged,
  signInWithEmailAndPassword,
  createUserWithEmailAndPassword,
  signInWithPopup,
  GoogleAuthProvider,
  signInAnonymously,
  sendPasswordResetEmail,
  signOut,
  updateProfile,
  updatePassword,
  EmailAuthProvider,
  reauthenticateWithCredential,
} from 'https://www.gstatic.com/firebasejs/10.14.1/firebase-auth.js';
import {
  getFirestore,
  doc,
  collection,
  setDoc,
  getDoc,
  getDocs,
  addDoc,
  updateDoc,
  deleteDoc,
  onSnapshot,
  query,
  where,
  orderBy,
  limit,
  serverTimestamp,
  arrayUnion,
  arrayRemove,
  deleteField,
  Timestamp,
  writeBatch,
} from 'https://www.gstatic.com/firebasejs/10.14.1/firebase-firestore.js';
import {
  getStorage,
  ref as storageRef,
  uploadBytes,
  getDownloadURL,
} from 'https://www.gstatic.com/firebasejs/10.14.1/firebase-storage.js';
import { firebaseConfig } from './config.js';

const app = initializeApp(firebaseConfig);
export const auth = getAuth(app);
export const db = getFirestore(app);
export const storage = getStorage(app);

export {
  onAuthStateChanged,
  signInWithEmailAndPassword,
  createUserWithEmailAndPassword,
  signInWithPopup,
  GoogleAuthProvider,
  signInAnonymously,
  sendPasswordResetEmail,
  signOut,
  updateProfile,
  updatePassword,
  EmailAuthProvider,
  reauthenticateWithCredential,
  doc,
  collection,
  setDoc,
  getDoc,
  getDocs,
  addDoc,
  updateDoc,
  deleteDoc,
  onSnapshot,
  query,
  where,
  orderBy,
  limit,
  serverTimestamp,
  arrayUnion,
  arrayRemove,
  deleteField,
  Timestamp,
  writeBatch,
  storageRef,
  uploadBytes,
  getDownloadURL,
};

/** familyId = ebeveyn UID */
export function familyIdOf(user) {
  return user?.uid ?? null;
}

export async function ensureParentProfile(user) {
  if (!user) throw new Error('Oturum bulunamadı.');
  const userRef = doc(db, 'users', user.uid);
  const familyRef = doc(db, 'families', user.uid);
  const famSnap = await getDoc(familyRef);
  const batch = writeBatch(db);

  batch.set(
    userRef,
    {
      uid: user.uid,
      name: user.displayName?.trim() || 'Ebeveyn',
      email: user.email || '',
      role: 'parent',
      familyId: user.uid,
      updatedAt: serverTimestamp(),
    },
    { merge: true },
  );

  if (famSnap.exists()) {
    batch.set(
      familyRef,
      {
        parentIds: arrayUnion(user.uid),
        memberIds: arrayUnion(user.uid),
        updatedAt: serverTimestamp(),
      },
      { merge: true },
    );
  } else {
    batch.set(familyRef, {
      parentIds: [user.uid],
      memberIds: [user.uid],
      childIds: [],
      createdAt: serverTimestamp(),
      updatedAt: serverTimestamp(),
    });
  }
  await batch.commit();
}

export async function registerParent(email, password, name) {
  const cred = await createUserWithEmailAndPassword(auth, email, password);
  await updateProfile(cred.user, { displayName: name });
  await setDoc(
    doc(db, 'users', cred.user.uid),
    {
      uid: cred.user.uid,
      name,
      email,
      role: 'parent',
      familyId: cred.user.uid,
      createdAt: serverTimestamp(),
    },
    { merge: true },
  );
  await setDoc(
    doc(db, 'families', cred.user.uid),
    {
      parentIds: [cred.user.uid],
      childIds: [],
      memberIds: [cred.user.uid],
      createdAt: serverTimestamp(),
    },
    { merge: true },
  );
  return cred.user;
}

export async function signInParent(email, password) {
  const cred = await signInWithEmailAndPassword(auth, email, password);
  await ensureParentProfile(cred.user);
  return cred.user;
}

export async function signInParentGoogle() {
  const provider = new GoogleAuthProvider();
  const cred = await signInWithPopup(auth, provider);
  await ensureParentProfile(cred.user);
  return cred.user;
}

export function tsToDate(v) {
  if (!v) return null;
  if (v instanceof Date) return v;
  if (typeof v.toDate === 'function') return v.toDate();
  if (typeof v.seconds === 'number') return new Date(v.seconds * 1000);
  return null;
}

export function dateKey(d = new Date()) {
  const y = d.getFullYear();
  const m = String(d.getMonth() + 1).padStart(2, '0');
  const day = String(d.getDate()).padStart(2, '0');
  return `${y}-${m}-${day}`;
}

export function describeError(e) {
  const code = e?.code || '';
  const msg = e?.message || String(e);
  if (code === 'auth/invalid-credential' || code === 'auth/wrong-password') {
    return 'E-posta veya şifre hatalı.';
  }
  if (code === 'auth/email-already-in-use') return 'Bu e-posta zaten kayıtlı.';
  if (code === 'auth/weak-password') return 'Şifre en az 6 karakter olmalı.';
  if (code === 'auth/popup-closed-by-user') return 'Google girişi iptal edildi.';
  if (code === 'permission-denied' || msg.includes('permission-denied')) {
    return 'Firestore izni yok. Kuralların yayınlandığından emin olun.';
  }
  return msg.replace(/^Firebase:\s*/i, '').slice(0, 200);
}
