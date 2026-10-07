# Configuration

Muxify reads `~/.config/muxify/config.yaml` (or
`$XDG_CONFIG_HOME/muxify/config.yaml`). Use **Muxify → Open Config** to edit it.

## Remote Environments

Manage tmux on Linux or macOS over SSH. The remote needs **tmux 3.2+**, not
Muxify. Add destinations to the Config:

```yaml
remote_environments:
  - name: Macbook Home
    host: macbook-home.example.ts.net
    username: your-user
    # port: 22
    # identity_file: ~/.ssh/id_ed25519
    # forward_agent: false
```

Names must be unique; `Local` is reserved. SSH reads `~/.ssh/config`, including
1Password's `IdentityAgent`. YAML `port` overrides SSH config; `identity_file`
names a local key. Password authentication is disabled.
Agent forwarding (`-A`) is on by default; set `forward_agent: false` for hosts
you don't trust with access to your agent.

Choose an Environment in the header to open its App Window, or focus it if
already open. ⌘N opens another Local App Window. Closing a window leaves tmux
running; dropped connections reconnect automatically. Muxify remembers the last
focused Environment and creates `main` in the remote home if no Session exists.

The Browser stays local: use reachable URLs, such as Tailscale URLs. There is
no port forwarding or remote dev-server discovery; Reveal in Finder is disabled.
Install [Agent Extensions](../extensions/README.md#install) manually on the remote.

## Header height

```yaml
ui:
  header_height: 30
```

The height is in macOS points, defaults to 30, and must be a finite number of
at least 24 so the buttons fit. Changes apply live. Removing the setting restores
the default; invalid values use the default and appear in the Config problems
banner. A YAML syntax error keeps the last good Config.

## Browser and keybindings

The top-right header toggles the Sidebar and Browser. ⌘B toggles the current
Window's Browser. Each Window remembers its Browser Tabs and visibility.
Browser-opening requests (`muxify browser open …`, terminal Cmd-click links)
reveal its Browser. The [Simulator](simulator.md) runs in a browser, not a native
panel.

Configurable [Keybindings](keybindings.md) work throughout the app, including in
Browser pages. The guide lists all actions, defaults, built-in shortcuts and a
complete Config example.
