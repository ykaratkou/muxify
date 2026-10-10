import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';

const script = readFileSync(new URL('../../Sources/MuxifySimulatorServer/Web/app.js', import.meta.url), 'utf8');
const deviceA = '11111111-1111-1111-1111-111111111111';
const deviceB = '22222222-2222-2222-2222-222222222222';

// Exercise the actual browser entrypoint with deterministic transport/image completion.
// WebKitTests covers rendering and real DOM integration; this harness covers races.
function browser() {
  const elements = new Map(), sockets = [], images = [], timers = new Map(), storage = new Map();
  let draws = 0, timerID = 0;
  function element(id) {
    if (!elements.has(id)) {
      const classes = new Set();
      const attributes = new Map();
      elements.set(id, {
        value: '', hidden: true, disabled: false, width: 100, height: 200,
        clientWidth: 800, clientHeight: 700, textContent: '',
        style: { setProperty() {} },
        classList: {
          add: name => classes.add(name), remove: name => classes.delete(name),
          contains: name => classes.has(name),
          toggle: (name, value) => value ? classes.add(name) : classes.delete(name),
        },
        replaceChildren(...children) { this.children = children; },
        setAttribute: (name, value) => attributes.set(name, value),
        getAttribute: name => attributes.get(name),
        getContext: () => ({ drawImage() { draws++; } }),
        getBoundingClientRect: () => ({ left: 0, top: 0, width: 100, height: 200 }),
        focus() {}, setPointerCapture() {}, releasePointerCapture() {},
      });
    }
    return elements.get(id);
  }
  class Socket {
    static OPEN = 1;
    readyState = 1;
    messages = [];
    constructor() { sockets.push(this); }
    send(text) { this.messages.push(JSON.parse(text)); }
    close() { this.readyState = 3; this.onclose?.(); }
  }
  class DecodedImage {
    naturalWidth = 100;
    naturalHeight = 200;
    constructor() { images.push(this); }
    decode() { return new Promise(resolve => { this.finish = resolve; }); }
  }
  const context = vm.createContext({
    document: { getElementById: element, querySelector: element, addEventListener() {} },
    window: { addEventListener() {} },
    location: { hash: '#token=test', protocol: 'http:', host: 'localhost' },
    sessionStorage: {
      getItem: key => storage.get(key), setItem: (key, value) => storage.set(key, value),
      removeItem: key => storage.delete(key),
    },
    WebSocket: Socket, Image: DecodedImage, Blob, DataView, URLSearchParams,
    URL: { createObjectURL: () => 'blob:test', revokeObjectURL() {} },
    ResizeObserver: class { observe() {} },
    Option: class { constructor(text, value) { this.text = text; this.value = value; } },
    getComputedStyle: () => ({ paddingLeft: '24' }),
    setTimeout(fn) { timers.set(++timerID, fn); return timerID; },
    clearTimeout: id => timers.delete(id),
  });
  vm.runInContext(script, context);
  const evaluate = code => vm.runInContext(code, context);
  const state = (changes = {}) => ({
    type: 'state', selected: deviceA, status: 'running', rotation: 0, inputEpoch: 0, viewers: 1,
    devices: [deviceA, deviceB].map(udid => ({ udid, state: 'booted', name: 'Test', runtimeName: 'iOS', deviceTypeIdentifier: 'iPhone' })),
    ...changes,
  });
  const update = changes => sockets.at(-1).onmessage({ data: JSON.stringify(state(changes)) });
  const key = (phase, code, flags = {}) => element('screen')[`onkey${phase}`]({
    code, preventDefault() {}, ctrlKey: false, shiftKey: false, altKey: false, metaKey: false, ...flags,
  });
  const frame = (id, rotation = 0) => {
    const buffer = new ArrayBuffer(10), view = new DataView(buffer);
    view.setUint32(0, id); view.setUint32(4, rotation);
    return sockets.at(-1).onmessage({ data: buffer });
  };
  sockets[0].onopen();
  update();
  return { element, sockets, images, timers, storage, evaluate, update, key, frame, get draws() { return draws; } };
}

test('device selector marks every running Device, independently of selection', () => {
  const b = browser();
  b.update({ selected: null, status: 'choosing' });
  const options = b.element('devices').children;
  assert.equal(options[0].text, 'Choose a Device');
  assert.equal(options[1].text, 'Test · iOS · ▶ Running');
  assert.equal(options[2].text, 'Test · iOS · ▶ Running');
  assert.equal(options[1].value, deviceA);
  assert.equal(options[2].value, deviceB);
});

test('device selector does not mark stopped or transitioning Devices as running', () => {
  const b = browser();
  for (const state of ['shutdown', 'booting', 'shuttingDown', 'unknown']) {
    b.update({ devices: [{ udid: deviceA, state, name: 'Test', runtimeName: 'iOS', deviceTypeIdentifier: 'iPhone' }] });
    assert.equal(b.element('devices').children[1].text, 'Test · iOS');
  }
});

test('device selector updates running markers without changing selection', () => {
  const b = browser();
  const devices = state => [
    { udid: deviceA, state: 'booted', name: 'Test', runtimeName: 'iOS', deviceTypeIdentifier: 'iPhone' },
    { udid: deviceB, state, name: 'Other', runtimeName: 'iOS', deviceTypeIdentifier: 'iPad' },
  ];
  b.update({ devices: devices('shutdown') });
  assert.equal(b.element('devices').children[2].text, 'Other · iOS');
  b.update({ devices: devices('booted') });
  assert.equal(b.element('devices').children[2].text, 'Other · iOS · ▶ Running');
  assert.equal(b.element('devices').value, deviceA);
  b.update({ devices: devices('shutdown') });
  assert.equal(b.element('devices').children[2].text, 'Other · iOS');
  assert.equal(b.element('devices').value, deviceA);
  assert.equal(b.sockets[0].messages.length, 0);
});

test('Stop immediately shows progress and locks controls until shutdown completes', async () => {
  const b = browser(), stop = b.element('stop');
  const pending = b.frame(1);
  b.key('down', 'KeyA');
  stop.onclick();
  assert.equal(stop.hidden, false);
  assert.equal(stop.disabled, true);
  assert.equal(stop.classList.contains('stopping'), true);
  assert.equal(stop.getAttribute('aria-busy'), 'true');
  assert.equal(stop.getAttribute('aria-label'), 'Stopping Device');
  assert.equal(b.element('stop-label').textContent, 'Stopping…');
  assert.equal(b.element('placeholder').textContent, 'Stopping Device…');
  for (const id of ['devices', 'start', 'home', 'rotate', 'retry']) assert.equal(b.element(id).disabled, true);
  assert.equal(b.evaluate('heldKeys.size'), 0);
  assert.deepEqual(b.sockets[0].messages.slice(-2), [{ type: 'release' }, { type: 'stop' }]);

  stop.onclick();
  b.element('home').onclick();
  b.key('down', 'KeyB');
  b.key('up', 'ShiftLeft', { shiftKey: true });
  b.element('screen').onpointerdown({ button: 0, pointerId: 1, clientX: 50, clientY: 100, preventDefault() {} });
  assert.equal(b.evaluate('pointer'), null);
  assert.equal(b.evaluate('heldKeys.size'), 0);
  b.images[0].finish();
  await pending;
  assert.equal(b.draws, 0);
  assert.equal(b.sockets[0].messages.filter(m => m.type === 'stop').length, 1);
  assert.equal(b.sockets[0].messages.some(m => m.type === 'home'), false);

  // An already-in-flight running snapshot must not cancel optimistic feedback.
  b.update();
  assert.equal(stop.disabled, true);
  assert.equal(b.element('stop-label').textContent, 'Stopping…');
  b.update({ status: 'stopping' });
  assert.equal(stop.disabled, true);
  b.update({ status: 'stopped', devices: [{ udid: deviceA, state: 'shutdown', name: 'Test', runtimeName: 'iOS', deviceTypeIdentifier: 'iPhone' }] });
  assert.equal(stop.hidden, true);
  assert.equal(stop.classList.contains('stopping'), false);
  assert.equal(stop.getAttribute('aria-busy'), 'false');
  assert.equal(b.element('start').disabled, false);
  assert.equal(b.element('devices').disabled, false);
  assert.equal(b.element('stop-label').textContent, 'Stop');
});

test('a peer stopping the Device also shows progress and locks controls', () => {
  const b = browser();
  b.update({ status: 'stopping' });
  assert.equal(b.element('stop-label').textContent, 'Stopping…');
  assert.equal(b.element('stop').disabled, true);
  assert.equal(b.element('devices').disabled, true);
  assert.equal(b.element('home').disabled, true);
});

test('failed Stop clears progress and restores controls with an error', () => {
  const b = browser();
  b.element('stop').onclick();
  b.update({ status: 'unavailable', message: 'Could not stop Device.' });
  assert.equal(b.element('stop-label').textContent, 'Stop');
  assert.equal(b.element('stop').disabled, false);
  assert.equal(b.element('devices').disabled, false);
  assert.equal(b.element('retry').disabled, false);
  assert.equal(b.element('message').textContent, 'Could not stop Device.');
  assert.equal(b.element('message').classList.contains('error'), true);
  b.element('stop').onclick();
  assert.equal(b.element('stop').disabled, true);
  assert.equal(b.element('stop-label').textContent, 'Stopping…');
});

test('a rejected Stop command clears optimistic progress', () => {
  const b = browser();
  b.element('stop').onclick();
  b.sockets[0].onmessage({ data: JSON.stringify({ type: 'error', message: 'Command rejected.' }) });
  assert.equal(b.element('stop').disabled, false);
  assert.equal(b.element('stop-label').textContent, 'Stop');
  assert.equal(b.element('message').textContent, 'Command rejected.');
});

test('disconnect during Stop resets progress and stays locked until reconnect', () => {
  const b = browser();
  b.element('stop').onclick();
  b.sockets[0].close();
  assert.equal(b.element('stop-label').textContent, 'Stop');
  assert.equal(b.element('stop').getAttribute('aria-busy'), 'false');
  assert.equal(b.element('stop').disabled, true);
  assert.equal(b.element('devices').disabled, true);
  assert.equal(b.element('retry').disabled, false);
  [...b.timers.values()][0]();
  b.sockets[1].onopen();
  b.update();
  assert.equal(b.element('stop').disabled, false);
  assert.equal(b.element('stop-label').textContent, 'Stop');
});

test('selection releases input, never boots, and ignores old frames while pending', async () => {
  const b = browser(), socket = b.sockets[0];
  b.key('down', 'KeyA');
  const pending = b.frame(1);
  b.element('devices').value = deviceB;
  b.element('devices').onchange();
  b.key('down', 'KeyB');
  b.images[0].finish();
  await pending;
  assert.equal(b.draws, 0);
  assert.deepEqual(socket.messages.slice(-3), [
    { type: 'release' }, { type: 'select', device: deviceB }, { type: 'ack', frame: 1 },
  ]);
  assert.equal(b.evaluate('heldKeys.size'), 0);
  assert.equal(socket.messages.some(m => m.type === 'start'), false);
  b.update({ selected: deviceB });
  assert.equal(b.evaluate('selectionPending'), false);
});

test('a stale rotation is acknowledged without resizing or drawing the canvas', async () => {
  const b = browser();
  const pending = b.frame(1, 0);
  b.images[0].naturalWidth = 777;
  b.update({ rotation: 90, inputEpoch: 1 });
  b.images[0].finish();
  await pending;
  assert.equal(b.draws, 0);
  assert.equal(b.element('screen').width, 100);
  assert.deepEqual(b.sockets[0].messages.at(-1), { type: 'ack', frame: 1 });
  const next = b.frame(2, 90);
  b.images[1].finish();
  await next;
  assert.equal(b.draws, 1);
  assert.equal(b.evaluate('shownRotation'), 90);
});

test('reconnect restores selection and ignores a previous socket decode', async () => {
  const b = browser();
  b.element('devices').value = deviceA;
  b.element('devices').onchange();
  b.update();
  const pending = b.frame(1);
  const old = b.sockets[0];
  old.close();
  assert.equal(b.element('screen').hidden, true);
  [...b.timers.values()][0]();
  const replacement = b.sockets[1];
  replacement.onopen();
  b.update();
  b.images[0].finish();
  await pending;
  assert.equal(b.draws, 0);
  assert.deepEqual(replacement.messages, [{ type: 'select', device: deviceA }]);
  old.onclose();
  assert.equal(b.element('connection').textContent, 'Connected');
});

test('shared input epoch releases local modifiers and pointer', () => {
  const b = browser();
  b.key('down', 'ShiftLeft', { shiftKey: true });
  b.element('screen').onpointerdown({ button: 0, pointerId: 1, clientX: 50, clientY: 100, preventDefault() {} });
  b.update({ inputEpoch: 1 });
  assert.equal(b.evaluate('heldKeys.size'), 0);
  assert.equal(b.evaluate('pointer'), null);
  assert.deepEqual(b.sockets[0].messages.at(-1), { type: 'release' });
});

test('right modifiers do not synthesize a second left modifier', () => {
  const b = browser();
  b.key('down', 'AltRight', { altKey: true });
  assert.deepEqual(b.sockets[0].messages, [{ type: 'key', phase: 'down', usage: 0xe6 }]);
  b.key('up', 'AltRight');
  assert.equal(b.evaluate('heldKeys.size'), 0);
});

test('Command release clears keys whose keyup macOS omitted', () => {
  const b = browser();
  b.key('down', 'MetaLeft', { metaKey: true });
  b.key('down', 'KeyA', { metaKey: true });
  b.key('up', 'MetaLeft');
  assert.equal(b.evaluate('heldKeys.size'), 0);
  assert.deepEqual(b.sockets[0].messages.at(-1), { type: 'release' });
  b.key('down', 'KeyA');
  assert.deepEqual(b.sockets[0].messages.at(-1), { type: 'key', phase: 'down', usage: 4 });
});

test('keyup during selection does not reintroduce modifiers on another Device', () => {
  const b = browser();
  b.element('devices').value = deviceB;
  b.element('devices').onchange();
  b.key('up', 'KeyA', { shiftKey: true });
  assert.equal(b.evaluate('heldKeys.size'), 0);
  assert.deepEqual(b.sockets[0].messages.at(-1), { type: 'select', device: deviceB });
});
