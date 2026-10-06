# Muxify

A native macOS app for running coding agents in tmux. It lists your tmux
Sessions and Windows in a sidebar, shows which Agents (Claude Code, Codex,
OpenCode, Pi) are working, blocked or done and waiting for you, and gives every
Window its own browser panel for docs and dev servers.

## How it works

Muxify runs a single `tmux attach` client in a libghostty terminal, so tmux
draws your Windows and Panes exactly as it does in Ghostty, with your
`~/.config/ghostty/config`. A tmux control-mode client and a once-a-second poll
keep the sidebar in sync, and Muxify keeps its own state (Browser Tabs, Agent
Statuses) in tmux options on the Window or Pane it belongs to, so it survives a
relaunch and goes away with the Window. Agents report their Status through small
Extensions installed into each Agent's own hook or plugin system. The vocabulary
is in [CONTEXT.md](CONTEXT.md), the design decisions in [docs/adr](docs/adr).

## Build

Requires macOS 14+ on Apple silicon, Xcode, Homebrew, `tmux` and Ghostty.app
(its terminfo and themes are bundled into the app).

```sh
make run    # vendors libghostty, generates the Xcode project, builds and opens the app
```

`make setup`, which every other target runs first, prepares a fresh machine: it
installs `xcodegen` with Homebrew if it is missing, then runs
`scripts/setup-ghostty.sh` if no libghostty is vendored yet. The script looks for
a local Ghostty build in `~/projects/`; if there is none, it clones Ghostty at the
pinned commit and builds it with zig, installing Zig and Xcode's Metal Toolchain
when they are missing. To use another build:

```sh
GHOSTTYKIT=/path/to/GhosttyKit.xcframework ./scripts/setup-ghostty.sh
GHOSTTY_SRC=~/src/ghostty ./scripts/setup-ghostty.sh    # builds it with zig
```

## Install

```sh
make install    # a Release build, into /Applications (or INSTALL_DIR)
```

Then open the installed app and, from the **Muxify** menu:

- **Install Command Line Tool** links `muxify` into `~/.local/bin`. Programs in
  a Pane use it to open Tabs in their Window's Browser (`muxify browser open
  localhost:3000`), and launchers use it to jump to a Session (`muxify session
  open "my project"`). The link points into the app bundle, so install it from
  the copy you keep.
- **Install Extensions** installs or updates the status Extension for every
  supported Agent it finds in your home directory: Claude Code, Codex, OpenCode
  and Pi. Claude Code and Codex need `jq`. For Codex, trust the hooks once with
  `/hooks` and launch it with `codex --no-daemon`. Restart running Agents to
  load the Extension. See [extensions/README.md](extensions/README.md) for what
  each one does.

## Benchmark

```sh
make bench    # run in a Pane of the terminal you want to measure
```

The script finds the terminal app that draws the Pane. It stops if another tmux
client shows the same Window, because tmux then draws every update twice, and
prints the command that detaches that client. Then it measures the app's idle CPU
for 10 seconds (`IDLE_SECS`), then measures PTY throughput with
[vtebench](https://github.com/alacritty/vtebench), which it builds with cargo on
first use. To see what Muxify costs, run it in Muxify, then in Ghostty.app attached
to the same Session, with the same Window size. Each run adds a line to
`build/bench/runs.tsv`, and with `gnuplot` installed, `build/bench/summary.svg`
plots every run side by side.
