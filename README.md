# Muxify

A native macOS app for coding agents in tmux, locally or over SSH. Track Claude
Code, Codex, OpenCode and Pi in a sidebar, give each Window its own Browser, and
control simulated iPhones and iPads from any web browser.

## Download the beta

Download the Apple-silicon ZIP from [GitHub Releases](https://github.com/ykaratkou/muxify/releases),
unzip it, and move `Muxify.app` into `/Applications`.

Requires **macOS 14+** and `tmux` for Local (`brew install tmux`). Ghostty is
bundled; Xcode is not needed to run the desktop app.

Betas are **ad-hoc signed, not notarized**. If macOS blocks a download you trust,
use **System Settings → Privacy & Security → Open Anyway**. Do not disable
Gatekeeper globally. [Verify the download](docs/development.md#verify-a-download).

## Setup

From the **Muxify** menu:

- **Install Command Line Tool** adds `muxify` to `~/.local/bin`.
- **Install Extensions** enables Agent statuses. Restart running Agents;
  see [Agent setup](extensions/README.md#install) for dependencies and Codex requirements.

From a tmux Pane:

```sh
muxify browser open localhost:3000
muxify session open "my project"
```

⌘B toggles the Browser; ⌘N opens another Local App Window.

## Simulator Server

```sh
muxify simulator serve --port 8787
```

Run on the Mac that owns the Devices, with Xcode 27+ and an iOS runtime installed.
Open the printed URL in any browser and keep its token secret.
See the [Simulator guide](docs/simulator.md) for standalone builds and Tailscale/SSH access.

## Build from source

Requires Apple silicon, macOS 14+, Xcode 26+, Homebrew and `tmux`.

```sh
make run       # build and open
make test      # run tests
make install   # install a Release build into /Applications
```

## Documentation

- [Configuration](docs/configuration.md) — Remote Environments, Browser and header height
- [Keybindings](docs/keybindings.md)
- [Development](docs/development.md) — internals, Ghostty setup and beta releases
- [Testing](docs/testing.md)
- [Vocabulary](CONTEXT.md) and [design decisions](docs/adr)
