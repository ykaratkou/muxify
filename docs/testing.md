# Testing

Run the normal suite with `make test`. Live SSH tests are skipped unless you
provide a destination with working key authentication and a verified host key.

## Live SSH test

For an OrbStack Ubuntu VM (use its actual Linux username):

```sh
TEST_RUNNER_MUXIFY_SSH_TEST_HOST=ubuntu.orb.local \
TEST_RUNNER_MUXIFY_SSH_TEST_USER="<user_name>" \
TEST_RUNNER_MUXIFY_SSH_TEST_IDENTITY="$HOME/.orbstack/ssh/id_ed25519" \
  make test
```

`TEST_RUNNER_` forwards these variables through Xcode to the test process.
`MUXIFY_SSH_TEST_PORT` is optional; without it, SSH config supplies the port
(otherwise 22). The live connection reads normal SSH config and forwards the agent.
Set `TEST_RUNNER_MUXIFY_SSH_TEST_REQUIRE_AGENT=1` to also verify the remote
forwarded socket can reach your agent (requires server support).

The live test uses the production SSH attachment, command and event paths.
It checks terminal type/true-color capabilities, client targeting, Window/Pane
mutations, Browser and Agent metadata, detach, connection-loss detection and a
fresh connection with state preserved, and background SSH shutdown that leaves
tmux Sessions and a sibling SSH connection running. Unit tests check cleanup
thread/order and deferred quit replies.
App Window tests check Environment deduplication, focused/originating-window
routing, live ⌘N overrides and isolated Browser views in hidden disposable native
windows, without starting Ghostty or connecting to tmux.
It creates and removes its own isolated remote tmux server; existing Sessions,
Agent configuration and SSH setup are left alone. It does not exercise Ghostty
rendering or the app's UI reconnect scheduler.

## Simulator tests

Run `make test` for CLI, server, browser-script and desktop tests, or `swift test`
for CLI and server tests. `node --test Tests/SimulatorWeb/*.test.mjs` runs only
the browser-script race and input tests (no npm dependencies).

Set `MUXIFY_TEST_WEBKIT=1` when running `swift test` to include the
embedded-browser integration test; it requires a graphical macOS login.
The opt-in [live Simulator test](../Tests/SimulatorSmoke/README.md) uses
disposable Devices to validate real browser rendering, shared control and input.
