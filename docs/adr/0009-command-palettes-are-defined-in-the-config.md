# Command Palettes are defined in the Config, with their own keybinding and Sources

`command_palettes` is a list. Each Command Palette has a unique `name`, the `sources` selected when it opens (`sessions`, `windows`, `agents`) and its own `keybinding`. Sources are not a hard limit: every palette has a chip for each Source, and the user can switch any of them on or off while it is open. That keybinding works anywhere in Muxify, and it follows the `keybindings` collision rules: it counts as explicitly assigned, it is removed from other actions' defaults, and when two claim the same trigger the first keeps it and the second is a problem. Leaving the section out gives one "Go to…" palette with every Source on `cmd+shift+p`, and `[]` removes every palette. Shortcuts that act only while a palette is open (`jump_to`, `copy_path`, `copy_target`, `show_actions`, `select_next`, `select_prev`) live under `keybindings.command_palette`. They follow the same overlay rules and win over global keybindings while the palette is open, so they never conflict with those.

The `sessions` Source also lists Session Paths: the folders in `sessions.paths`, plus the git worktrees of those that are repos. These replace the user's tmux-sessionizer script. A Session Path matches the Session started in that folder, not a Session with the same name, so two folders with the same basename stay separate and renaming a Session does not lose the match.

## Considered Options

- **One fixed palette over everything.** Rejected: the user wants a Sessions palette on `cmd+p` and an Agents palette on a separate key.
- **`sources` as a hard filter.** Rejected: a palette is a starting point. The Sessions palette should still reach an Agent without closing it and opening another.
- **Palette triggers inside `keybindings`** (for example `open_palette_sessions: cmd+p`). Rejected: action names would come from user-chosen palette names, and the palette's definition would be split across two sections.
- **A separate `paths` Source.** Rejected: a Session Path is a Session that isn't running yet, and the sessionizer listed both in one list.
- **Match Session Paths by Session name**, as the sessionizer did. Rejected: two folders with the same basename land on one Session.
- **Worktrees found by folder conventions** (`~/worktrees/<project>/<name>`, `.worktree.json`). Rejected: `git worktree list` finds them wherever they live.
