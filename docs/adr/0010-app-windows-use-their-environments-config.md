# An App Window uses the Config of its Environment's machine

A Remote Environment's App Window reads that machine's `~/.config/muxify/config.yaml` over the Environment's owned SSH connection. When the file exists, it is that App Window's whole Config, with defaults for anything it leaves out. When it doesn't, the local Config applies, and its Session Paths are scanned on the remote. The App Window behaves as if Muxify were running on that machine. This matters most for Session Paths, which name folders on the machine where the Sessions run, but it also covers keybindings, Command Palettes and `ui`, so the menu shows the focused App Window's shortcuts. Two sections describe the local app and are ignored in a remote Config without reporting a problem: `ghostty`, because every App Window shares one Ghostty runtime, and `remote_environments`, because the Environment list belongs to the running app.

The remote file is not watched. It is read when the Environment connects, on Reload Config, and each time a Command Palette opens. A syntax error keeps that Environment's last good Config, and its problems appear in that App Window with the host in front of the path. Open Config in a remote App Window opens a new tmux Window on the remote that runs `$EDITOR` on the file.

This partly supersedes ADR-0007 ("App Windows share one … Config") and narrows ADR-0005's single-file rule: one file per machine. The remote still needs only tmux, not Muxify.

## Considered Options

- **Local Config only, with Session Paths local-only.** Rejected: remote App Windows would offer no folders.
- **Per-Environment `session_paths` in `remote_environments`.** Rejected: the folders belong in that machine's own Config, which is valid there too.
- **Per-section or per-setting overlay of remote on local.** Rejected: harder to predict, and keybinding collision rules would span two files.
- **Watching the remote file.** Rejected: it would need a long-running process over SSH, and reading on connect, Reload and palette open is enough.
