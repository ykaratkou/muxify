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
