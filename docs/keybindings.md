# Keybindings

## Configurable actions

These keybindings work throughout Muxify, including while a Browser page or its
address bar has focus. All available `keybindings` actions are listed below.

| Action | Default shortcuts | What it does |
| --- | --- | --- |
| `new_app_window` | ⌘N | Open a new Local Muxify App Window |
| `toggle_sidebar` | ⌘S, ⌃⌘S | Show or hide the Sidebar |
| `toggle_browser` | ⌘B | Show or hide the current Window's Browser |
| `select_window_1` | ⌘1 | Select the first Window in the current Session |
| `select_window_2` | ⌘2 | Select the second Window |
| `select_window_3` | ⌘3 | Select the third Window |
| `select_window_4` | ⌘4 | Select the fourth Window |
| `select_window_5` | ⌘5 | Select the fifth Window |
| `select_window_6` | ⌘6 | Select the sixth Window |
| `select_window_7` | ⌘7 | Select the seventh Window |
| `select_window_8` | ⌘8 | Select the eighth Window |
| `select_window_9` | ⌘9 | Select the ninth Window, not the last one |
| `select_next_window` | Unbound | Select the next Window, wrapping to the first |
| `select_prev_window` | Unbound | Select the previous Window, wrapping to the last |

All tmux Window navigation stays within the focused App Window's current Session
and follows sidebar order, not tmux's window indices.
Switching Windows also restores that Window's Browser and focuses the terminal. If a
numbered position does not exist, the shortcut does nothing.

Use **Muxify → Open Config** to open `~/.config/muxify/config.yaml` (or
`$XDG_CONFIG_HOME/muxify/config.yaml`). This example lists every configurable
action, keeps the default bindings, and assigns optional next/previous shortcuts:

```yaml
keybindings:
  new_app_window: cmd+n
  toggle_sidebar: [cmd+s, ctrl+cmd+s]
  toggle_browser: cmd+b
  select_window_1: cmd+1
  select_window_2: cmd+2
  select_window_3: cmd+3
  select_window_4: cmd+4
  select_window_5: cmd+5
  select_window_6: cmd+6
  select_window_7: cmd+7
  select_window_8: cmd+8
  select_window_9: cmd+9
  # These two actions are unbound by default.
  select_next_window: ctrl+cmd+right
  select_prev_window: ctrl+cmd+left
```

Triggers use Ghostty-style names: `cmd`, `ctrl`, `alt` (Option), and `shift`,
followed by a character or a named key such as `left`, `right`, `tab`, or
`left_bracket`. An action accepts one trigger or a list, such as
`select_window_2: [cmd+2, ctrl+cmd+2]`.

Actions not listed keep their defaults. Naming an action replaces its defaults;
`[]` disables it (for example, `select_window_9: []`). A trigger explicitly
assigned to an action is removed from other actions' defaults. If two actions
explicitly claim the same trigger, the first keeps it and Muxify reports the
conflict. Muxify reloads the Config when it changes. Its bindings take precedence
over Ghostty and Browser page bindings, but only inside Muxify—not while another
app is active.

To change New App Window, use `new_app_window: cmd+shift+n`; use
`new_app_window: []` to disable its shortcuts. This also removes the terminal's
default ⌘N behavior. New tmux Session remains available from the File menu.

## Built-in shortcuts

These shortcuts are not configurable as actions in Muxify's `keybindings`
section. Configured Muxify bindings still take precedence over them. When the
terminal has focus, Ghostty bindings can take precedence over menu shortcuts.

| Shortcut | Action |
| --- | --- |
| ⌘ + backquote | Focus the terminal |
| ⌘⇧, | Reload the Muxify Config and Ghostty config |

**Browser shortcuts** apply when the Browser has focus. Menu clicks work even
when it does not. New Tab and Open Location can reveal a hidden Browser:

| Shortcut | Action |
| --- | --- |
| ⌘T | Open a new Browser Tab |
| ⌘L | Focus the address bar, opening the Browser if hidden |
| ⌘W | Close the active Browser Tab |
| ⌘⇧] or ⌃Tab | Select the next Browser Tab |
| ⌘⇧[ or ⌃⇧Tab | Select the previous Browser Tab |
| ⌘[ | Go back |
| ⌘] | Go forward |
| ⌘R | Reload the page, or stop it while loading |
| Enter (address bar) | Navigate to the entered URL or search |
| Escape (address bar) | Restore the current URL and focus the page |

The ⌃Tab shortcuts also require the Browser to be open. ⌘W never closes the
Muxify app window; when the terminal has focus, it does nothing unless you
assign it to a configurable action.

Other terminal keybindings come from your Ghostty config and tmux bindings,
not the Muxify Config.

**Simulator input** is handled by its web page after clicking the Device screen.
Drag to swipe and type ordinary keys/modifiers; losing focus or disconnecting
releases held input. Home, rotation, Start Device and Stop Device are web controls,
not desktop menu actions. Browser/OS-reserved shortcuts and Muxify's configured
bindings remain on the Mac. There is no `toggle_simulator` action or native phone
toggle; open the Simulator Server's URL as an ordinary Browser Tab.
