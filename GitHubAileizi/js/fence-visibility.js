/** Haritada bölge görünürlüğü (yerel tercih) */

const ALL_KEY = 'aileizi_show_fences';
const HIDDEN_KEY = 'aileizi_hidden_fence_ids';

function notify() {
  window.dispatchEvent(new CustomEvent('aileizi-fences-vis'));
}

export function getShowAllFences() {
  return localStorage.getItem(ALL_KEY) !== '0';
}

export function getHiddenFenceIds() {
  try {
    const a = JSON.parse(localStorage.getItem(HIDDEN_KEY) || '[]');
    return new Set(Array.isArray(a) ? a.map(String) : []);
  } catch {
    return new Set();
  }
}

export function isFenceVisibleOnMap(id) {
  if (!id) return false;
  if (!getShowAllFences()) return false;
  return !getHiddenFenceIds().has(String(id));
}

/** Tüm bölgeler: açınca hepsini gösterir (tekil gizlemeleri temizler) */
export function setAllFencesVisible(on) {
  localStorage.setItem(ALL_KEY, on ? '1' : '0');
  if (on) localStorage.setItem(HIDDEN_KEY, '[]');
  notify();
}

export function toggleFenceVisible(id) {
  const key = String(id);
  const hidden = getHiddenFenceIds();
  if (hidden.has(key)) {
    hidden.delete(key);
    if (!getShowAllFences()) localStorage.setItem(ALL_KEY, '1');
  } else {
    hidden.add(key);
  }
  localStorage.setItem(HIDDEN_KEY, JSON.stringify([...hidden]));
  notify();
}

export function eyeIcon(visible) {
  return visible ? '👁️' : '🚫';
}
