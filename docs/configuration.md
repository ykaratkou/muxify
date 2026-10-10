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

## Sidebar typography

```yaml
ui:
  sidebar:
    font_size: 12
    font_family: system
```

These are the current defaults. `font_size` is a base size in macOS points:
Window and Agent titles use it directly, while Session names, headings,
metadata and numeric badges scale proportionally to preserve their existing
hierarchy and weights. It must be a finite number greater than zero; fractional
sizes are supported. Session rows grow to accommodate larger text.

`font_family` is `system` for the native macOS system font, or an installed macOS
font family name, such as `Helvetica`. Names are case-insensitive and surrounding
whitespace is ignored. Use a family name, not a font-file path or an individual
face/PostScript name. A family without an exact medium or semibold weight uses
its closest available weight.

Both options apply live to text in the Sessions and Agents sections of every
App Window, without changing selection, expansion or visibility. Symbols,
logos, status dots, the App Window header and Terminal fonts are unchanged.
Configure Terminal fonts in the Ghostty config instead.

Each option is independent: removing it restores its default, and an invalid
value uses its default and appears with its line in the Config problems banner
while valid sibling settings still apply. An unavailable family is also a
problem and uses `system`. A YAML syntax error keeps the entire last good Config.

## Command Palettes

A Command Palette searches Sessions, Windows and Agents and acts on the
highlighted result. Each palette has a name, a keybinding that works anywhere
in Muxify, and the sources selected when it opens:

```yaml
command_palettes:
  - name: Sessions
    keybinding: cmd+p
    sources: [sessions, windows]
  - name: Agents
    keybinding: cmd+shift+o
    sources: [agents]
```

Without `command_palettes` there is one palette, **Go to…**, on ⇧⌘P with every
source; `command_palettes: []` removes it. Names must be unique, and `sources`
lists `sessions` (running Sessions and the [Session Paths](#session-paths)
without one), `windows` or `agents`. They aren't a hard limit: every palette
has a chip for each source, its own first and on, and ⌘1–⌘3 or a click turn
any chip on or off. The last chip that is on stays on. A palette's `keybinding` takes one trigger
or a list and follows the [keybindings](keybindings.md) rules: it is removed
from other actions' defaults, and when two claim the same trigger the first in
the file keeps it. Each palette is also in the View menu.

Its own keybinding closes a palette; another palette's keybinding switches to
that one and keeps what you typed. With nothing typed, a palette lists:

- **Sessions**, most recently active first and the current one last, then the
  Session Paths that have no Session.
- **Agents** that need you (blocked, failed or unread), then working ones, then
  the rest.
- **Windows** only once you type, or when theirs is the only chip on.

Typing ranks everything in one list. A Window with an Agent is left out while
the Agents chip is on. ⎋ closes the actions menu, then clears the search and
puts the chips back, then closes the palette. The keys inside a palette are
[configurable](keybindings.md#command-palette-keybindings).

| Action | Session | Window | Agent | Session Path |
| --- | --- | --- | --- | --- |
| Jump to (↩) | Switch to it | Select it | Select its Window and Pane | Create the Session there, then switch |
| Copy Path (⌘C) | Its start folder | The active Pane's folder | The Pane's folder | The folder |
| Copy tmux Target (⌘⇧C) | Session name | `session:index` | Pane ID | — |

⌘K opens these actions in a menu by the highlighted row.

## Session Paths

Folders the Command Palette offers as Sessions, for those that aren't running
yet, replacing a sessionizer script:

```yaml
sessions:
  paths:
    - path: ~/projects
      depth: 1
    - path: ~/.dotfiles
```

`path` is absolute or starts with `~/`. `depth` defaults to 0, the folder
itself; 1 lists its subfolders, and 2 also their subfolders. Hidden folders are
skipped, and so are folders this machine doesn't have, so one Config can serve
several Macs. The git worktrees of these folders are listed too, after their
repository.

A Session Path matches the Session started in its folder, whatever the Session
is called. Choosing one switches to that Session, or creates it named after
the folder (`.` becomes `_`, spaces go) or, for a worktree,
`<project> [<worktree>]`. If another folder's Session has that name, the parent
folder goes in front: `work-foo`. Muxify looks for the folders each time a
palette with `sessions` opens.

## A Remote Environment's own Config

A Remote Environment's App Window uses the Config on that machine
(`~/.config/muxify/config.yaml`, or under its `$XDG_CONFIG_HOME`) when there is
one, as if Muxify ran there: its Session Paths, palettes, keybindings and `ui`.
Its `ghostty` and `remote_environments` sections are ignored, because they
describe this Mac's app. Without a remote Config, the local Config applies, and
its Session Paths are looked for on the remote. The menu shows the focused App
Window's keybindings.

Muxify reads the remote file when it connects, on **Reload Config** (⌘⇧,), and
each time a palette opens; it doesn't watch it. A syntax error keeps the last
good remote Config, and its problems show in that App Window with the host in
front of the path. **Open Config** there opens the remote file in the remote's
`$VISUAL` or `$EDITOR` in a new tmux Window.

## Browser and keybindings

The top-right header toggles the Sidebar and Browser. ⌘B toggles the current
Window's Browser. Each Window remembers its Browser Tabs and visibility.
Browser-opening requests (`muxify browser open …`, terminal Cmd-click links)
reveal its Browser. The [Simulator](simulator.md) runs in a browser, not a native
panel.

Configurable [Keybindings](keybindings.md) work throughout the app, including in
Browser pages. The guide lists all actions, defaults, built-in shortcuts and a
complete Config example.
