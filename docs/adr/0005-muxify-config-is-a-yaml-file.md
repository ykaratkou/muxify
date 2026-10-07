# Muxify's Config is a YAML file, and its keybinds win over Ghostty's

Muxify's desktop settings live only in its Config, `$XDG_CONFIG_HOME/muxify/config.yaml`: one YAML file, with `snake_case` keys grouped in sections. The UI never writes or overrides a setting. It can open the file and show which keybinds are in effect. What is open or shown now (Sidebar and Browser visibility, Browser Tabs, and the Simulator's selected Device) stays UI state and is never in the Config. The standalone Simulator Server uses explicit CLI options rather than the desktop Config so it can run without the app. The Config also names the Ghostty config the terminal uses (`ghostty.config_file`). Muxify loads it the same way as `ghostty --config-file=`: Ghostty's default files first, then that file on top.

```yaml
ghostty:
  config_file: ~/.config/ghostty/personal
keybindings:
  toggle_sidebar: ctrl+cmd+s   # replaces this action's defaults, so cmd+s reaches tmux
  toggle_browser: []           # no keybinding
```

`keybindings` maps an action to one trigger or a list of them, spelled as in Ghostty (`ctrl+cmd+s`). An action named here uses only the triggers listed; an action not named keeps its defaults. A trigger listed for one action is taken from any other action's defaults. The same trigger under two actions is a problem, and the first action in the file keeps it.

A value Muxify cannot apply (an unknown section, key or action, a bad trigger, a wrong type) is skipped, the rest applies, and a banner shows the line. A YAML syntax error keeps the last good Config, or the defaults at launch, and the banner shows the error. A half-typed edit does not reset the keybinds in use.

A Muxify keybind acts before the terminal gets the key, so it wins over a Ghostty keybind for the same trigger even when the terminal has focus. Before this, Ghostty keybinds won in the terminal, so a Ghostty config that maps ⌘-keys to tmux (`cmd+s` → `C-b s`) made the Sidebar toggle unreachable from where focus almost always is. One place now decides every collision: the Config.

## Considered Options

- **Ghostty's syntax** (`key = value` lines, `keybind = <trigger>=<action>`, `config-file` includes). Rejected: it has no sections, and the Config will grow groups of settings beyond keybinds. It was the first design and was never released.
- **TOML.** It has sections without YAML's indentation and implicit typing traps. Rejected for familiarity: YAML is the format the user reads and writes elsewhere. Both need a parser package.
- **JSON5.** Foundation reads it with no dependency. Rejected: braces and quoted strings are noisy to write by hand.
- **Trigger → action keybindings with `unbind` and `clear`**, as in Ghostty. Rejected: action → triggers reads like other apps' settings, and naming an action to replace its defaults removes the need for `unbind`.
- **Includes.** Dropped for now: one file is simpler to read and to watch, and chezmoi templates cover per-machine files.
- **The UI edits the file.** Rejected: the Config is a dotfile under chezmoi, so a UI write changes the target, not the source, and the next `chezmoi apply` undoes it.
- **UI overrides stored apart from the file.** Rejected: two sources mean a line can look right in the file and still not apply. That is the same hidden-source problem that made the user's Ghostty keybinds silently fail in Muxify.
- **Ghostty keybinds win in the terminal.** Rejected: Muxify keybinds would then act only when the Browser or Sidebar has focus.
