'use strict';

const el = id => document.getElementById(id);
const canvas = el('screen');
const ctx = canvas.getContext('2d');
const devices = el('devices');
const frameElement = el('device-frame');
const stage = document.querySelector('.stage');
const heldKeys = new Set();
let ws, state, retryTimer;
let pointer = null;
let shownRotation = 0;
let hasFrame = false;
let selectionEpoch = 0;
let selectionPending = false;
let deviceList = '';
let desiredDevice = sessionStorage.getItem('muxify-device') || '';

const fragment = new URLSearchParams(location.hash.slice(1));
const token = fragment.get('token') || sessionStorage.getItem('muxify-token');
if (token) sessionStorage.setItem('muxify-token', token);

function send(message) {
  if (ws?.readyState === WebSocket.OPEN) ws.send(JSON.stringify(message));
}

function note(message, error = false) {
  el('message').textContent = message;
  el('message').hidden = !message;
  el('message').classList.toggle('error', error);
}

function clearScreen() {
  hasFrame = false;
  canvas.hidden = true;
  frameElement.hidden = true;
  el('empty').hidden = false;
}

function release() {
  send({ type: 'release' });
  heldKeys.clear();
  pointer = null;
}

function fit() {
  if (!hasFrame) return;
  const padding = parseFloat(getComputedStyle(stage).paddingLeft) * 2;
  const ipad = frameElement.classList.contains('ipad');
  const rim = ipad ? 10 : 7;
  const scale = Math.max(0.001, Math.min(
    (stage.clientWidth - padding - rim * 2) / canvas.width,
    (stage.clientHeight - padding - rim * 2) / canvas.height,
  ));
  const width = canvas.width * scale;
  const height = canvas.height * scale;
  const radius = Math.min(width, height) * (ipad ? 0.045 : 0.105);
  canvas.style.width = `${width}px`;
  canvas.style.height = `${height}px`;
  frameElement.style.setProperty('--rim', `${rim}px`);
  frameElement.style.setProperty('--inner-radius', `${radius}px`);
  frameElement.style.setProperty('--outer-radius', `${radius + rim}px`);
}

new ResizeObserver(fit).observe(stage);

function render(next) {
  const changed = state?.selected !== next.selected;
  if (state && (changed || state.rotation !== next.rotation || state.inputEpoch !== next.inputEpoch
      || (state.status === 'running' && next.status !== 'running'))) release();
  if (changed) selectionEpoch++;
  if (changed || !['running', 'rotating', 'connecting'].includes(next.status)) clearScreen();
  state = next;

  const list = JSON.stringify(next.devices);
  if (list !== deviceList) {
    const options = [new Option('Choose a Device', '')];
    for (const device of next.devices) {
      options.push(new Option(`${device.name} · ${device.runtimeName}`, device.udid));
    }
    devices.replaceChildren(...options);
    deviceList = list;
  }
  const selected = next.devices.find(d => d.udid === next.selected);
  if (desiredDevice && !next.devices.some(d => d.udid === desiredDevice)) {
    desiredDevice = '';
    sessionStorage.removeItem('muxify-device');
  }
  if ((next.selected || '') === desiredDevice) selectionPending = false;
  devices.value = selectionPending ? desiredDevice : next.selected || '';

  const busy = selectionPending || ['connecting', 'stopping', 'rotating'].includes(next.status);
  const running = ['running', 'rotating', 'connecting', 'stopping'].includes(next.status)
    || ['booted', 'booting'].includes(selected?.state);
  frameElement.classList.toggle('ipad', !!selected?.deviceTypeIdentifier.includes('iPad'));
  frameElement.classList.toggle('iphone', !selected?.deviceTypeIdentifier.includes('iPad'));
  devices.disabled = busy;
  el('start').disabled = busy || selected?.state !== 'shutdown';
  el('start').hidden = !!selected && running;
  el('stop').hidden = !selected || !running;
  el('stop').disabled = selectionPending || next.status === 'stopping' || !selected
    || (!['booted', 'booting'].includes(selected.state) && !['running', 'rotating'].includes(next.status));
  for (const id of ['home', 'rotate']) el(id).disabled = selectionPending || next.status !== 'running';
  el('retry').disabled = busy;

  const labels = {
    choosing: 'Choose a Device', stopped: 'Device is stopped', connecting: 'Connecting to Device…',
    stopping: 'Stopping Device…', unavailable: 'Device is unavailable',
  };
  const descriptions = {
    choosing: 'Select an iPhone or iPad above. It only starts when you choose Start Device.',
    stopped: 'Choose Start Device to boot it.', unavailable: 'Use the refresh button to retry.',
  };
  el('placeholder').textContent = labels[next.status] || 'Waiting for display…';
  el('empty-detail').textContent = descriptions[next.status] || 'Your display will appear here shortly.';
  const direction = { 0: 'Portrait', 90: 'Landscape', 180: 'Upside down', 270: 'Landscape' }[next.rotation];
  const statusLabel = next.status === 'running' ? direction : next.status.charAt(0).toUpperCase() + next.status.slice(1);
  el('device-detail').textContent = selected ? `${selected.runtimeName} · ${statusLabel}` : 'No Device selected';
  el('viewers').hidden = !selected || !next.viewers;
  el('viewers').textContent = `${next.viewers} ${next.viewers === 1 ? 'viewer' : 'viewers'} · Shared control`;
  note(next.message || '', !!next.message);
  fit();
}

async function receiveFrame(socket, data) {
  if (data.byteLength < 8) { note('Invalid display frame.', true); return; }
  const view = new DataView(data);
  const frame = view.getUint32(0);
  const rotation = view.getUint32(4);
  const selected = state?.selected;
  const epoch = selectionEpoch;
  try {
    const blob = new Blob([data.slice(8)], { type: 'image/jpeg' });
    // HTMLImageElement also works in Safari/WKWebView.
    const image = new Image();
    const url = URL.createObjectURL(blob);
    try {
      image.src = url;
      await image.decode();
      if (ws !== socket || selectionPending || epoch !== selectionEpoch || state?.selected !== selected
          || !['running', 'rotating'].includes(state?.status) || rotation !== state.rotation) return;
      // Validate before touching the visible canvas; a stale decode must not overwrite it.
      canvas.width = image.naturalWidth;
      canvas.height = image.naturalHeight;
      ctx.drawImage(image, 0, 0);
      shownRotation = rotation;
      hasFrame = true;
      canvas.hidden = false;
      frameElement.hidden = false;
      el('empty').hidden = true;
      fit();
    } finally { URL.revokeObjectURL(url); }
  } catch (error) {
    if (ws === socket && epoch === selectionEpoch) note(`Display error: ${error.message}`, true);
  } finally {
    if (ws === socket) send({ type: 'ack', frame });
  }
}

function connect() {
  clearTimeout(retryTimer);
  if (!token) {
    note('Open the full URL printed by muxify simulator serve, including its access token.', true);
    el('connection').textContent = 'Access token required';
    return;
  }
  const previous = ws;
  ws = null;
  previous?.close();
  selectionEpoch++;
  selectionPending = !!desiredDevice;
  el('connection').textContent = 'Connecting…';
  el('connection-dot').classList.remove('online');
  const protocol = location.protocol === 'https:' ? 'wss:' : 'ws:';
  const socket = new WebSocket(`${protocol}//${location.host}/ws?token=${encodeURIComponent(token)}`);
  ws = socket;
  socket.binaryType = 'arraybuffer';
  socket.onopen = () => {
    if (ws !== socket) return;
    el('connection').textContent = 'Connected';
    el('connection-dot').classList.add('online');
    if (desiredDevice) send({ type: 'select', device: desiredDevice });
  };
  socket.onmessage = ({ data }) => {
    if (ws !== socket) return;
    if (typeof data !== 'string') return receiveFrame(socket, data);
    const message = JSON.parse(data);
    if (message.type === 'state') render(message);
    else if (message.type === 'error') note(message.message, true);
  };
  socket.onclose = () => {
    if (ws !== socket) return;
    heldKeys.clear();
    pointer = null;
    state = undefined;
    clearScreen();
    devices.disabled = true;
    for (const id of ['start', 'stop', 'home', 'rotate']) el(id).disabled = true;
    el('connection').textContent = 'Disconnected';
    el('connection-dot').classList.remove('online');
    note('Connection lost. Devices are still running. Reconnecting…', true);
    retryTimer = setTimeout(connect, 2000);
  };
  socket.onerror = () => {
    if (ws === socket) note('Could not connect. Check the server, proxy origin and access token.', true);
  };
}

devices.onchange = () => {
  release();
  clearScreen();
  selectionEpoch++;
  selectionPending = true;
  desiredDevice = devices.value;
  sessionStorage.setItem('muxify-device', desiredDevice);
  for (const id of ['start', 'stop', 'home', 'rotate']) el(id).disabled = true;
  send({ type: 'select', device: desiredDevice || null });
};
for (const type of ['start', 'stop', 'home', 'rotate']) {
  el(type).onclick = () => { release(); send({ type }); };
}
el('retry').onclick = () => {
  if (ws?.readyState === WebSocket.OPEN) send({ type: 'refresh' });
  else connect();
};

function touch(phase, event) {
  const rect = canvas.getBoundingClientRect();
  const x = Math.max(0, Math.min(1, (event.clientX - rect.left) / rect.width));
  const y = Math.max(0, Math.min(1, (event.clientY - rect.top) / rect.height));
  send({ type: 'touch', phase, x, y, rotation: shownRotation });
}
canvas.onpointerdown = event => {
  if (selectionPending || state?.status !== 'running' || pointer !== null || event.button !== 0) return;
  event.preventDefault();
  canvas.focus();
  canvas.setPointerCapture(event.pointerId);
  pointer = event.pointerId;
  touch('began', event);
};
canvas.onpointermove = event => { if (event.pointerId === pointer) touch('moved', event); };
canvas.onpointerup = event => {
  if (event.pointerId !== pointer) return;
  touch('ended', event);
  pointer = null;
  canvas.releasePointerCapture(event.pointerId);
};
canvas.onpointercancel = event => {
  if (event.pointerId !== pointer) return;
  touch('cancelled', event);
  pointer = null;
};
canvas.onlostpointercapture = () => { if (pointer !== null) release(); };
canvas.oncontextmenu = event => event.preventDefault();

const usages = {
  Enter: 0x28, Escape: 0x29, Backspace: 0x2a, Tab: 0x2b, Space: 0x2c,
  Minus: 0x2d, Equal: 0x2e, BracketLeft: 0x2f, BracketRight: 0x30, Backslash: 0x31,
  Semicolon: 0x33, Quote: 0x34, Backquote: 0x35, Comma: 0x36, Period: 0x37, Slash: 0x38,
  CapsLock: 0x39, Delete: 0x4c, Home: 0x4a, End: 0x4d, PageUp: 0x4b, PageDown: 0x4e,
  ArrowRight: 0x4f, ArrowLeft: 0x50, ArrowDown: 0x51, ArrowUp: 0x52,
  ControlLeft: 0xe0, ShiftLeft: 0xe1, AltLeft: 0xe2, MetaLeft: 0xe3,
  ControlRight: 0xe4, ShiftRight: 0xe5, AltRight: 0xe6, MetaRight: 0xe7,
};
for (let i = 0; i < 26; i++) usages[`Key${String.fromCharCode(65 + i)}`] = 4 + i;
for (let i = 1; i <= 9; i++) usages[`Digit${i}`] = 0x1d + i;
usages.Digit0 = 0x27;
for (let i = 1; i <= 12; i++) usages[`F${i}`] = 0x39 + i;

function syncModifiers(event) {
  const modifiers = [
    ['ctrlKey', 0xe0, 0xe4], ['shiftKey', 0xe1, 0xe5],
    ['altKey', 0xe2, 0xe6], ['metaKey', 0xe3, 0xe7],
  ];
  for (const [flag, left, right] of modifiers) {
    if (event[flag] && !heldKeys.has(left) && !heldKeys.has(right)) {
      // Preserve the side when this is the modifier's own keydown.
      const usage = usages[event.code] === right ? right : left;
      heldKeys.add(usage);
      send({ type: 'key', phase: 'down', usage });
    }
    if (!event[flag]) {
      for (const usage of [left, right]) {
        if (heldKeys.delete(usage)) send({ type: 'key', phase: 'up', usage });
      }
    }
  }
}
canvas.onkeydown = event => {
  if (selectionPending || state?.status !== 'running') return;
  const usage = usages[event.code];
  if (!usage) return;
  event.preventDefault();
  syncModifiers(event);
  if (event.repeat) return;
  if (!heldKeys.has(usage)) {
    heldKeys.add(usage);
    send({ type: 'key', phase: 'down', usage });
  }
};
canvas.onkeyup = event => {
  const usage = usages[event.code];
  if (!usage) return;
  event.preventDefault();
  if (heldKeys.delete(usage)) send({ type: 'key', phase: 'up', usage });
  // macOS may omit non-modifier keyup events while Command is held.
  if ((usage === 0xe3 || usage === 0xe7) && !event.metaKey) release();
  if (!selectionPending && state?.status === 'running') syncModifiers(event);
};
canvas.onblur = release;
window.addEventListener('blur', release);
document.addEventListener('visibilitychange', () => { if (document.hidden) release(); });
window.addEventListener('pagehide', () => { release(); clearTimeout(retryTimer); ws?.close(); });

connect();
