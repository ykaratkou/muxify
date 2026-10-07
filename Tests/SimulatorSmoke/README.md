# Live Simulator smoke test

Run from the repository root on Apple silicon with Xcode 27+ and an installed
iOS 26+ runtime:

```sh
python3 scripts/test-simulator.py
```

Requires `agent-browser` and a local Chrome installation. The script builds the
standalone `muxify` CLI (including the Simulator Server) and a tiny SwiftUI fixture, creates two disposable iPhone
17 Pro Devices, and controls them through the actual web interface in isolated
browser sessions. It installs the fixture **only on its main Device** and shuts down
and deletes only its own Devices in `finally`, even when a test fails. It never closes
Apple's Device Hub or changes Xcode preferences. This runner is not part of Muxify.

Checks cover selection without booting, explicit browser Start/Stop Device,
real IOSurface frames encoded as JPEG and drawn in a browser canvas, pointer
events dispatched by Chrome (not calls directly into the backend), taps/swipes,
Shift-modified `Ab!` typing, confirmed guest landscape layout and matching input
coordinates, four-way physical rotation on the portrait-only Home screen, Home,
and disconnect/reconnect without shutdown. Multiple tabs in one browser and a second
browser share a Device, propagate rotation/Stop, and survive peer disconnection.
A peer can select, start, rotate and stop a different Device without affecting the original.
The page is checked for fitting frames and horizontal overflow at widths from 320 to 1280 px.

Verified locally with Xcode 27.0 (`27A266a`) and iOS 26.5 on iPhone 17 Pro and
iPad Pro 13-inch (M5). The server is launched as a standalone CLI, without
Muxify's desktop app, in a logged-in macOS session. SSH launch, Tailscale routing
and operation without a graphical login still require validation on the remote Mac.
The fixture records its state in `Documents/smoke.json`.
The normal `make test` suite does not create or change real Devices.
The runner saves screenshots to `build/simulator-browser-portrait.png`,
`build/simulator-browser-landscape.png` and `build/simulator-browser-<width>.png`.

An additional opt-in check exercises the same web page in WKWebView, the browser
engine embedded by Muxify, using a fake Device (requires a graphical login):

```sh
MUXIFY_TEST_WEBKIT=1 swift test --filter WebKitTests
```

To check an iPad instead, pass its identifier from `xcrun simctl list devicetypes`
with `--device-type <identifier>`. The script still creates and removes its own Device.
