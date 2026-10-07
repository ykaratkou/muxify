# Simulator Server

On the Mac that owns the Devices:

```sh
muxify simulator serve --port 8787
```

Open the printed URL, including `#token=…`, in any web browser. To use Muxify's
Browser, run `muxify browser open '<printed-url>'` in a tmux Pane.

## Device control

The Simulator lists available iPhones/iPads and provides **Start Device**,
**Stop Device**, Home, rotation, taps, swipes and keyboard input. Selection never
starts a stopped Device. Closing a browser or the server only disconnects;
Devices keep running.

Each browser tab has its own selection. Multiple browsers and tabs can view and
control the same Device, or select different Devices. Tabs sharing a Device
share its screen, rotation and start/stop actions; closing one tab does not
disconnect the others. Selection is restored per tab after reconnecting,
without starting a stopped Device.

Commands are ordered per Device. A swipe belongs to the tab that began it
(overlapping swipes from other tabs are ignored). Disconnecting a tab releases
only its own held input; Home, rotation and Stop reset held input for every
viewer. Rotation turns the physical frame even when a portrait-only app keeps
its layout.

## Standalone CLI

The Simulator Server is built into the `muxify` CLI, not a separate executable.
Both Debug and Release desktop app builds bundle that same CLI. Simulator
serving is independent of Muxify's desktop app, Ghostty and tmux.
To build only the CLI on a remote Mac:

```sh
make cli
./build/bin/muxify simulator serve --port 8787
```

`swift build --product muxify` also builds the CLI.

Copy `build/bin/` (the `muxify` executable and its `ThirdPartyNotices` directory)
to another supported Mac of the same architecture. The server embeds its web
assets and needs no resource bundle, CDN or companion app.

## Requirements and limits

Run as the user who owns the Devices, with a full Xcode 27+ installation selected
and an iOS runtime installed. Support is best-effort and uses private
CoreSimulator interfaces, including Xcode 27 screen callbacks and screen-addressed input.
It does not change Xcode preferences, manage physical devices, or build/install
apps. Operation without a graphical macOS login remains unverified.

The server streams JPEG frames at up to 15 fps, with browser acknowledgements
and a 1280-pixel longest edge to bound bandwidth. It does not stream audio,
clipboard, multi-touch or arbitrary browser-reserved keyboard shortcuts.

## Remote access

SSH can start the process; run it in tmux if it should survive SSH disconnection.
The server binds **only to 127.0.0.1** and requires a random per-process token.
Treat the complete URL as a secret. Optionally set `MUXIFY_SIMULATOR_TOKEN` to a
stable secret of 32–128 URL-safe characters before starting the server.

For a private Tailscale URL, configure Serve on the remote Mac (not Funnel):

```sh
# Replace this example origin with the HTTPS origin Tailscale assigns your Mac.
muxify simulator serve --port 8787 --origin https://your-mac.your-tailnet.ts.net
tailscale serve --bg http://127.0.0.1:8787
```

Open `https://your-mac.your-tailnet.ts.net/#token=<printed-token>` from a browser
on your tailnet. The `--origin` option allows that browser origin through the
reverse proxy. Muxify does not configure Tailscale or expose the server publicly.

Alternatively, forward the port with SSH:

```sh
ssh -N -L 8787:127.0.0.1:8787 your-mac
```

Then open the printed `http://127.0.0.1:8787/#token=…` URL locally.

## Development

The browser sources live in `Sources/MuxifySimulatorServer/Web/`. SwiftPM's
`EmbedWebAssetsPlugin` embeds them in the server executable at build time, so the
standalone distribution needs no resource bundle or JavaScript runtime.
The backend lives in `Sources/MuxifySimulatorServer/CoreSimulator/`, with only its
Objective-C declarations in `Sources/MuxifySimulatorPrivate/`. Incorporated code's
required copyright and MIT license notices are retained in
[`Simulator.txt`](../Resources/ThirdPartyNotices/Simulator.txt) and bundled with distributions.
See [Testing](testing.md#simulator-tests) for server, browser and live Device tests.
