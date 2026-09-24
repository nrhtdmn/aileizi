/** Keep screen on while any reason is active (Gizle / Takip) */
let wakeLock = null;
let dummyVideo = null;
const reasons = new Set();

async function requestLock() {
  if (!reasons.size) return;
  try {
    if ('wakeLock' in navigator) {
      wakeLock = await navigator.wakeLock.request('screen');
      wakeLock.addEventListener('release', () => {
        if (reasons.size) setTimeout(() => requestLock(), 400);
      });
      return;
    }
  } catch (_) {}
  try {
    if (!dummyVideo) {
      dummyVideo = document.createElement('video');
      dummyVideo.setAttribute('playsinline', '');
      dummyVideo.muted = true;
      dummyVideo.loop = true;
      dummyVideo.style.cssText =
        'position:fixed;width:1px;height:1px;opacity:0;pointer-events:none;bottom:0;left:0';
      const c = document.createElement('canvas');
      c.width = 2;
      c.height = 2;
      const stream = c.captureStream?.(1);
      if (stream) {
        dummyVideo.srcObject = stream;
        document.body.appendChild(dummyVideo);
        await dummyVideo.play();
      }
    } else {
      await dummyVideo.play();
    }
  } catch (_) {}
}

async function releaseLock() {
  try {
    await wakeLock?.release();
  } catch (_) {}
  wakeLock = null;
  try {
    dummyVideo?.pause();
  } catch (_) {}
}

function sync() {
  if (reasons.size) requestLock();
  else releaseLock();
}

document.addEventListener('visibilitychange', () => {
  if (document.visibilityState === 'visible' && reasons.size) requestLock();
});

/** @param {string} reason @param {boolean} on */
export function setKeepAwake(reason, on) {
  if (typeof reason === 'boolean') {
    // backward compat: setKeepAwake(true/false) → 'ui'
    on = reason;
    reason = 'ui';
  }
  if (on) reasons.add(reason || 'ui');
  else reasons.delete(reason || 'ui');
  sync();
}

export function isKeepAwake() {
  return reasons.size > 0;
}

export function clearKeepAwake() {
  reasons.clear();
  sync();
}
