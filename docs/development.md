# Development

## How it works

Each Muxify App Window runs a `tmux attach` client in a libghostty terminal, so
tmux draws your Windows and Panes exactly as it does in Ghostty, with your
`~/.config/ghostty/config`. A tmux control-mode client and a once-a-second poll
keep the sidebar in sync. Muxify keeps its own state (Browser Tabs and visibility,
Agent Statuses) in tmux options on the Window or Pane it belongs to, so it
survives a relaunch and goes away with the Window. Agents report their Status
through Extensions installed into each Agent's own hook or plugin system.

See [CONTEXT.md](../CONTEXT.md) for vocabulary and [ADRs](adr) for design decisions.

## Build

Requires macOS 14+ on Apple silicon, Xcode 26+, and Homebrew. Running the app
also requires `tmux`.

```sh
make run       # vendor libghostty, generate the Xcode project, build and open
make install   # install a Release build into /Applications (or INSTALL_DIR)
```

Desktop build targets run `make setup` first to prepare a fresh machine: it
installs `xcodegen` with Homebrew if missing, then runs `scripts/setup-ghostty.sh`
if the library or resources are not vendored yet. The script builds the exact
commit in `scripts/ghostty-version.env`, in the ignored `vendor/ghostty-src/`
directory. It downloads that commit's exact Zig compiler with a SHA-256 check
and installs Xcode's Metal Toolchain if missing. The library, terminfo, themes,
shell integration, and upstream dependency notices are vendored together;
an installed Ghostty.app is not used.

Explicit development overrides (not accepted by release packaging):

```sh
GHOSTTYKIT=/path/to/GhosttyKit.xcframework \
  GHOSTTY_RESOURCES=/path/to/ghostty/zig-out/share \
  ./scripts/setup-ghostty.sh
GHOSTTY_SRC=~/src/ghostty ./scripts/setup-ghostty.sh    # builds it with zig
```

If a custom checkout requires another Zig version, set `ZIG=/path/to/zig`.
For prebuilt development overrides, `GHOSTTY_NOTICES=/path/to/notices.txt` can
supply the matching build's dependency notices. To refresh the default pinned
library and resources, run `./scripts/setup-ghostty.sh` without overrides.

From the installed app's **Muxify** menu, **Install Command Line Tool** links
`muxify` into `~/.local/bin`. The link points into the app bundle, so install it
from the copy you keep. See [Extensions](../extensions/README.md#install) for
Agent setup and [Testing](testing.md) for unit and live tests.

## Beta releases

### Verify a download

Betas are ad-hoc signed, not Developer ID signed or notarized. Each release
includes `SHA256SUMS`. Download it alongside the ZIP and run:

```sh
shasum -a 256 -c SHA256SUMS
```

This checks file integrity, not the publisher's identity. No Ghostty, Zig or
Xcode installation is needed to run the desktop beta; Simulator serving has
[additional requirements](simulator.md#requirements-and-limits).

### Publish

The [release workflow](../.github/workflows/release-beta.yml) runs on `macos-26`
with Xcode 26.6. It caches the pinned Ghostty build, tests Muxify, builds a Release
app, verifies its ad-hoc signature, and publishes a **GitHub prerelease**, never
the latest stable release. No Apple account or signing secrets are needed.
Pull requests and pushes to `master`/`main` run the tests without publishing.
Default-branch builds warm the dependency cache that beta tags can reuse
(GitHub does not share tag-only caches between different tags).

After committing and pushing the release tooling and app changes, publish a beta:

```sh
git tag v0.1.0-beta.1
git push origin v0.1.0-beta.1
```

The version must use `vMAJOR.MINOR.PATCH-beta.N` with a positive beta number.
The app's marketing version comes from the tag and its build number from the
GitHub Actions run number. The workflow can also be dispatched manually with an
existing beta tag. It refuses to replace an existing GitHub release; use a new
beta tag instead.

To test the tooling or build the same package locally without publishing:

```sh
make test-release
make test
make release TAG=v0.1.0-beta.1 BUILD_NUMBER=1
```

Packages are written under `build/releases/<tag>/`: the ZIP, `SHA256SUMS`,
release notes, and build provenance. Dependency notices are bundled under
`Muxify.app/Contents/Resources/ThirdPartyNotices/`.
