/** Keep screen on while map focus (Gizle) mode is active */
let wakeLock = null;
let wantLock = false;
let dummyVideo = null;

async function requestLock() {
  if (!wantLock) return;
  try {
    if ('wakeLock' in navigator) {
      wakeLock = await navigator.wakeLock.request('screen');
      wakeLock.addEventListener('release', () => {
        if (wantLock) setTimeout(() => requestLock(), 500);
      });
      return;
    }
  } catch (_) {}
  // Fallback: silent looping video (older browsers)
  try {
    if (!dummyVideo) {
      dummyVideo = document.createElement('video');
      dummyVideo.setAttribute('playsinline', '');
      dummyVideo.setAttribute('muted', '');
      dummyVideo.muted = true;
      dummyVideo.loop = true;
      dummyVideo.style.cssText =
        'position:fixed;width:1px;height:1px;opacity:0;pointer-events:none;bottom:0;left:0';
      // tiny transparent webm data is heavy; use canvas stream instead
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

document.addEventListener('visibilitychange', () => {
  if (document.visibilityState === 'visible' && wantLock) requestLock();
});

export function setKeepAwake(on) {
  wantLock = !!on;
  if (on) requestLock();
  else releaseLock();
}

export function isKeepAwake() {
  return wantLock;
}
