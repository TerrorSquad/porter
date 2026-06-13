import jsQR from 'jsqr';
import { Assembler, Transfer } from './assembler.js';
import './styles.css';

// ── Go receiver relay types ───────────────────────────────────────────────────
interface GoUploadResult {
  fileName?: string;
  path?: string;
  size?: number;
  duplicate?: boolean;
  sha256?: string;
  transferId?: string;
  manifestPath?: string;
  complete?: boolean;
  verified?: boolean;
  joinedPath?: string;
}

interface RelayState {
  sent: number; // chunks successfully POSTed
  failed: number; // POST errors
  complete: boolean; // Go receiver reported transfer complete
  joinedPath?: string;
  lastError?: string;
}

// ── DOM refs ──────────────────────────────────────────────────────────────────
const cameraWrap = document.getElementById('camera-wrap') as HTMLDivElement;
const video = document.getElementById('video') as HTMLVideoElement;
const scanCanvas = document.getElementById('scan-canvas') as HTMLCanvasElement;
const camIdle = document.getElementById('cam-idle') as HTMLDivElement;
const scanFlash = document.getElementById('scan-flash') as HTMLDivElement;
const btnStart = document.getElementById('btn-start') as HTMLButtonElement;
const btnStop = document.getElementById('btn-stop') as HTMLButtonElement;
const cameraSelect = document.getElementById('camera-select') as HTMLSelectElement;
const resolutionSelect = document.getElementById('resolution-select') as HTMLSelectElement;
const btnResetAll = document.getElementById('btn-reset-all') as HTMLButtonElement;
const transfersList = document.getElementById('transfers-list') as HTMLDivElement;
const dropZone = document.getElementById('drop-zone') as HTMLDivElement;
const fileInput = document.getElementById('file-input') as HTMLInputElement;
const hudTotal = document.getElementById('hud-total') as HTMLSpanElement;
const hudNew = document.getElementById('hud-new') as HTMLSpanElement;
const hudDupes = document.getElementById('hud-dupes') as HTMLSpanElement;
const relayInput = document.getElementById('relay-url') as HTMLInputElement;
const relayStatus = document.getElementById('relay-status') as HTMLSpanElement;

// ── App state ─────────────────────────────────────────────────────────────────
let rafId = 0;
let cameraRunning = false;
let mediaStream: MediaStream | null = null;

const LS_KEY_CAMERA = 'porter-receiver:camera-device-id';
const LS_KEY_RESOLUTION = 'porter-receiver:camera-resolution';

let statsTotal = 0;
let statsNew = 0;

// Per-transfer server relay state (keyed by transfer ID)
const relayStates = new Map<string, RelayState>();

function relayUrl(): string {
  return relayInput.value.trim().replace(/\/$/, '');
}

async function postChunkToReceiver(raw: string): Promise<void> {
  const url = relayUrl();
  if (!url) return;
  const body = JSON.stringify({ content: raw, format: 'QR_CODE' });
  try {
    const res = await fetch(`${url}/upload`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body,
    });
    if (!res.ok) {
      const text = await res.text().catch(() => res.statusText);
      throw new Error(`HTTP ${res.status}: ${text.slice(0, 120)}`);
    }
    const result: GoUploadResult = await res.json();
    if (result.transferId) {
      const id = result.transferId;
      const prev = relayStates.get(id) ?? { sent: 0, failed: 0, complete: false };
      relayStates.set(id, {
        ...prev,
        sent: prev.sent + (result.duplicate ? 0 : 1),
        complete: result.complete ?? prev.complete,
        joinedPath: result.joinedPath ?? prev.joinedPath,
        lastError: undefined,
      });
      relayStatus.textContent = '●';
      relayStatus.className = 'relay-status relay-ok';
    }
  } catch (err) {
    // Don't surface every error loudly — just record for tooltip
    const msg = err instanceof Error ? err.message : String(err);
    console.warn('porter-receiver: relay error:', msg);
    relayStatus.textContent = '●';
    relayStatus.className = 'relay-status relay-err';
    relayStatus.title = msg;
  }
}

const assembler = new Assembler({
  onProgress: () => rerenderTransfers(),
  onComplete: (t) => {
    rerenderTransfers();
    if (t.assembled && !t.error) triggerDownload(t);
  },
});

// ── Camera ────────────────────────────────────────────────────────────────────
btnStart.addEventListener('click', startCamera);
btnStop.addEventListener('click', stopCamera);

// Restore saved resolution choice (camera choice is restored once the device list loads)
{
  const savedResolution = localStorage.getItem(LS_KEY_RESOLUTION);
  if (savedResolution && resolutionSelect.querySelector(`option[value="${savedResolution}"]`)) {
    resolutionSelect.value = savedResolution;
  }
}

cameraSelect.addEventListener('change', () => {
  localStorage.setItem(LS_KEY_CAMERA, cameraSelect.value);
  if (cameraRunning) void restartCamera();
});

resolutionSelect.addEventListener('change', () => {
  localStorage.setItem(LS_KEY_RESOLUTION, resolutionSelect.value);
  if (cameraRunning) void restartCamera();
});

navigator.mediaDevices.addEventListener?.('devicechange', () => void refreshCameraList());
void refreshCameraList();

// Populate the camera dropdown with available video input devices, preserving
// the saved/selected device where possible (labels only appear after permission).
async function refreshCameraList(): Promise<void> {
  let devices: MediaDeviceInfo[];
  try {
    devices = await navigator.mediaDevices.enumerateDevices();
  } catch {
    return;
  }
  const cams = devices.filter((d) => d.kind === 'videoinput');
  if (cams.length === 0) return;

  const previous = cameraSelect.value || localStorage.getItem(LS_KEY_CAMERA) || '';
  const options = ['<option value="">Default</option>'];
  for (const [i, cam] of cams.entries()) {
    options.push(
      `<option value="${escHtml(cam.deviceId)}">${escHtml(cam.label || `Camera ${i + 1}`)}</option>`,
    );
  }
  cameraSelect.innerHTML = options.join('');
  if (previous && cams.some((d) => d.deviceId === previous)) {
    cameraSelect.value = previous;
  }
}

function currentResolution(): { width: number; height: number } {
  const [width, height] = resolutionSelect.value.split('x').map(Number);
  return { width: width || 1280, height: height || 720 };
}

async function startCamera(): Promise<void> {
  const { width, height } = currentResolution();
  const deviceId = cameraSelect.value;

  const constraintsFor = (withDevice: boolean): MediaStreamConstraints => ({
    video: {
      ...(withDevice && deviceId
        ? { deviceId: { exact: deviceId } }
        : { facingMode: { ideal: 'environment' } }),
      width: { ideal: width },
      height: { ideal: height },
      aspectRatio: { ideal: width / height },
    },
  });

  try {
    try {
      mediaStream = await navigator.mediaDevices.getUserMedia(constraintsFor(true));
    } catch (err) {
      // Saved camera may no longer exist — fall back to the default device
      if (!deviceId) throw err;
      mediaStream = await navigator.mediaDevices.getUserMedia(constraintsFor(false));
    }
    video.srcObject = mediaStream;
    await video.play();
    cameraRunning = true;
    camIdle.classList.add('hidden');
    btnStart.disabled = true;
    btnStop.disabled = false;

    // Match the preview box to whatever shape the camera actually delivered
    // (cameras often can't hit an exact square and will return their closest fit).
    const settings = mediaStream.getVideoTracks()[0]?.getSettings();
    const actualW = settings?.width ?? width;
    const actualH = settings?.height ?? height;
    cameraWrap.style.aspectRatio = `${actualW} / ${actualH}`;

    scanLoop();
    void refreshCameraList();
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    alert(`Camera error: ${msg}\n\nMake sure the page is served over HTTPS or localhost.`);
  }
}

function stopCamera(): void {
  cameraRunning = false;
  cancelAnimationFrame(rafId);
  mediaStream?.getTracks().forEach((t) => t.stop());
  mediaStream = null;
  video.srcObject = null;
  camIdle.classList.remove('hidden');
  cameraWrap.style.aspectRatio = '';
  btnStart.disabled = false;
  btnStop.disabled = true;
}

async function restartCamera(): Promise<void> {
  stopCamera();
  await startCamera();
}

function scanLoop(): void {
  if (!cameraRunning) return;
  if (video.readyState === HTMLMediaElement.HAVE_ENOUGH_DATA) {
    const w = video.videoWidth;
    const h = video.videoHeight;
    if (w > 0 && h > 0) {
      scanCanvas.width = w;
      scanCanvas.height = h;
      const ctx = scanCanvas.getContext('2d')!;
      ctx.drawImage(video, 0, 0);
      const imgData = ctx.getImageData(0, 0, w, h);
      const code = jsQR(imgData.data, w, h, { inversionAttempts: 'dontInvert' });
      if (code?.data) ingest(code.data);
    }
  }
  rafId = requestAnimationFrame(scanLoop);
}

// ── File drop / browse ────────────────────────────────────────────────────────
dropZone.addEventListener('dragover', (e) => {
  e.preventDefault();
  dropZone.classList.add('drag-over');
});
dropZone.addEventListener('dragleave', () => dropZone.classList.remove('drag-over'));
dropZone.addEventListener('drop', (e) => {
  e.preventDefault();
  dropZone.classList.remove('drag-over');
  const files = Array.from(e.dataTransfer?.files ?? []).filter((f) => f.type.startsWith('image/'));
  void processFiles(files);
});

fileInput.addEventListener('change', () => {
  const files = Array.from(fileInput.files ?? []);
  fileInput.value = '';
  void processFiles(files);
});

async function processFiles(files: File[]): Promise<void> {
  for (const file of files) await scanImageFile(file);
}

async function scanImageFile(file: File): Promise<void> {
  let bitmap: ImageBitmap;
  try {
    bitmap = await createImageBitmap(file);
  } catch {
    console.warn(`porter-receiver: could not decode image ${file.name}`);
    return;
  }
  const canvas = document.createElement('canvas');
  canvas.width = bitmap.width;
  canvas.height = bitmap.height;
  const ctx = canvas.getContext('2d')!;
  ctx.drawImage(bitmap, 0, 0);
  const imgData = ctx.getImageData(0, 0, canvas.width, canvas.height);
  // Use attemptBoth so that inverted QR images also work
  const code = jsQR(imgData.data, imgData.width, imgData.height, {
    inversionAttempts: 'attemptBoth',
  });
  if (code?.data) ingest(code.data);
}

// ── Ingest + HUD ──────────────────────────────────────────────────────────────
function ingest(raw: string): void {
  statsTotal++;
  const isNew = assembler.ingest(raw);
  if (isNew) {
    statsNew++;
    flash();
    void postChunkToReceiver(raw);
  }
  hudTotal.textContent = String(statsTotal);
  hudNew.textContent = String(statsNew);
  hudDupes.textContent = String(statsTotal - statsNew);
}

let flashTimeout = 0;
function flash(): void {
  scanFlash.classList.add('active');
  clearTimeout(flashTimeout);
  flashTimeout = window.setTimeout(() => scanFlash.classList.remove('active'), 280);
}

// ── Reset ─────────────────────────────────────────────────────────────────────
btnResetAll.addEventListener('click', () => {
  assembler.reset();
  relayStates.clear();
  relayStatus.textContent = '';
  relayStatus.className = 'relay-status';
  statsTotal = statsNew = 0;
  hudTotal.textContent = hudNew.textContent = hudDupes.textContent = '0';
  rerenderTransfers();
});

// ── Render transfers ──────────────────────────────────────────────────────────
function rerenderTransfers(): void {
  const transfers = Array.from(assembler.getTransfers().values()).sort(
    (a, b) => b.createdAt - a.createdAt,
  );

  if (transfers.length === 0) {
    transfersList.innerHTML = `
      <div class="empty-state">
        <div class="empty-icon">▣</div>
        <div>No transfers yet.</div>
        <div class="empty-hint">Start the camera or drop QR images.</div>
      </div>`;
    return;
  }

  transfersList.innerHTML = transfers.map(cardHtml).join('');

  // Wire per-card buttons
  for (const t of transfers) {
    document.getElementById(`dl-${t.id}`)?.addEventListener('click', () => triggerDownload(t));
    document.getElementById(`rm-${t.id}`)?.addEventListener('click', () => {
      assembler.reset(t.id);
      rerenderTransfers();
    });
  }
}

function cardHtml(t: Transfer): string {
  const pct = t.total > 0 ? Math.round((t.chunks.size / t.total) * 100) : 0;

  const statusBadge = t.error
    ? `<span class="badge badge-error">Error</span>`
    : t.complete && t.assembled
      ? `<span class="badge badge-done">✓ Done</span>`
      : t.complete
        ? `<span class="badge badge-assembling">Assembling…</span>`
        : `<span class="badge badge-scanning">Scanning</span>`;

  const modeBadge = `<span class="badge badge-mode">${escHtml(t.mode)}</span>`;

  const checksumBadge =
    t.verified === true
      ? `<span class="badge badge-verified">✓ SHA-256</span>`
      : t.checksumMismatch === true
        ? `<span class="badge badge-checksum-fail">✗ SHA-256 mismatch</span>`
        : '';

  const progressBar =
    t.total > 0
      ? `<div class="progress-bar"><div class="progress-fill" style="width:${pct}%"></div></div>
       <div class="progress-label">${t.chunks.size} / ${t.total} chunks</div>`
      : `<div class="progress-label">Waiting for data chunks…</div>`;

  const preview =
    t.assembled && t.mode === 'T'
      ? (() => {
          const text = new TextDecoder().decode(t.assembled);
          const shown = text.length > 600 ? text.slice(0, 600) + '\n…' : text;
          return `<pre class="text-preview">${escHtml(shown)}</pre>`;
        })()
      : '';

  const dlBtn =
    t.assembled && !t.error
      ? `<button class="btn-download" id="dl-${t.id}">↓ Download</button>`
      : '';

  const errMsg = t.error ? `<div class="error-msg">${escHtml(t.error)}</div>` : '';

  // Go receiver relay row
  const rs = relayStates.get(t.id);
  const relayRow = (() => {
    if (!relayUrl()) return '';
    if (!rs)
      return `<div class="relay-row relay-row-pending">○ Go receiver: waiting for first chunk…</div>`;
    if (rs.lastError)
      return `<div class="relay-row relay-row-err" title="${escHtml(rs.lastError)}">✕ Go receiver: error — ${escHtml(rs.lastError.slice(0, 80))}</div>`;
    if (rs.complete && rs.joinedPath)
      return `<div class="relay-row relay-row-ok">✓ Go receiver: joined → <code>${escHtml(rs.joinedPath)}</code></div>`;
    if (rs.complete) return `<div class="relay-row relay-row-ok">✓ Go receiver: complete</div>`;
    return `<div class="relay-row relay-row-active">⇡ Go receiver: ${rs.sent} chunk${rs.sent !== 1 ? 's' : ''} saved</div>`;
  })();

  const cardClass = t.error ? 'card-error' : t.complete && t.assembled ? 'card-done' : '';

  return `
    <div class="transfer-card ${cardClass}">
      <div class="card-header">
        <span class="transfer-id">${escHtml(t.id)}</span>
        ${modeBadge}
        ${statusBadge}
        ${checksumBadge}
        <button class="btn-reset-card" id="rm-${t.id}" title="Remove">✕</button>
      </div>
      ${progressBar}
      ${preview}
      ${relayRow}
      ${dlBtn}
      ${errMsg}
    </div>`;
}

// ── Download ──────────────────────────────────────────────────────────────────
function triggerDownload(t: Transfer): void {
  if (!t.assembled) return;
  const filename = `porter-${t.id}-${Date.now()}${guessExt(t)}`;
  // Cast is safe: assembled is always backed by a plain ArrayBuffer
  const blob = new Blob([t.assembled as unknown as Uint8Array<ArrayBuffer>], {
    type: guessMime(t),
  });
  const url = URL.createObjectURL(blob);
  const a = Object.assign(document.createElement('a'), { href: url, download: filename });
  document.body.appendChild(a);
  a.click();
  a.remove();
  URL.revokeObjectURL(url);
}

function guessExt(t: Transfer): string {
  if (t.mode === 'T') return '.txt';
  if (!t.assembled || t.assembled.length < 4) return '.bin';
  const b = t.assembled;
  if (b[0] === 0x89 && b[1] === 0x50 && b[2] === 0x4e && b[3] === 0x47) return '.png';
  if (b[0] === 0xff && b[1] === 0xd8 && b[2] === 0xff) return '.jpg';
  if (b[0] === 0x25 && b[1] === 0x50 && b[2] === 0x44 && b[3] === 0x46) return '.pdf';
  if (b[0] === 0x50 && b[1] === 0x4b && b[2] === 0x03 && b[3] === 0x04) return '.zip';
  return '.bin';
}

function guessMime(t: Transfer): string {
  if (t.mode === 'T') return 'text/plain;charset=utf-8';
  const ext = guessExt(t);
  return (
    (
      {
        '.png': 'image/png',
        '.jpg': 'image/jpeg',
        '.pdf': 'application/pdf',
        '.zip': 'application/zip',
      } as Record<string, string>
    )[ext] ?? 'application/octet-stream'
  );
}

// ── Utils ─────────────────────────────────────────────────────────────────────
function escHtml(s: string): string {
  return s
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}
