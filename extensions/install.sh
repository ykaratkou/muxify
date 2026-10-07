#!/bin/sh
# Installs or updates the Muxify Extension of every Agent set up under $HOME.
#
# Muxify ▸ Install Extensions and `muxify extensions install` run this script inside the
# app; the Extension files are found next to it, so the bundled installer
# installs the bundled Extensions. An Agent counts as set up when its config
# directory exists (a Finder-launched app can't rely on PATH to find the
# Agents' binaries). Running it again updates the Extensions and adds nothing
# twice.
#
# Prints exactly one line per Agent:
#   <agent>: installed | updated | not found | failed (<reason>)
# followed, for Codex once installed or updated, by indented reminder lines;
# exits non-zero when any Agent failed.

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) || exit 1
failed=0

# add_hook_entries <file> <entries>
#
# <entries> is a JSON object {"<Event>": <entry>, ...}, each entry in the
# hooks-file shape {"matcher"?: "...", "hooks": [{"type": "command",
# "command": "...", ...}]}. Appends each entry to the file's .hooks.<Event>
# list unless that event already has a hook running the identical command.
# Other entries, their order and every other key are left as they are. When
# something is added, the file is first copied to <file>.bak; when nothing is
# missing, neither file is written. A missing or empty file counts as {}.
add_hook_entries() {
	hooks_file=$1
	merged=$(
		{ if [ -s "$hooks_file" ]; then cat "$hooks_file"; else echo '{}'; fi; } |
			jq --argjson add "$2" '
				. as $doc
				| def runs($cmd): any((.hooks // [])[]; .command == $cmd);
				reduce ($add | to_entries[]) as $e (.;
					if any((.hooks[$e.key] // [])[]; runs($e.value.hooks[0].command)) then .
					else .hooks[$e.key] = (.hooks[$e.key] // []) + [$e.value]
					end)
				| if . == $doc then empty else . end'
	) || return 1
	[ -n "$merged" ] || return 0
	if [ -e "$hooks_file" ]; then
		cp -p "$hooks_file" "$hooks_file.bak" || return 1
	fi
	printf '%s\n' "$merged" >"$hooks_file"
}

# Claude Code: one hook script for every event, registered in settings.json.
install_claude() {
	claude_dir=$HOME/.claude
	if [ ! -d "$claude_dir" ]; then
		echo "claude: not found"
		return 0
	fi
	if ! command -v jq >/dev/null 2>&1; then
		echo "claude: failed (jq not found)"
		return 1
	fi

	claude_script=$claude_dir/hooks/muxify-status.sh
	# $HOME stays literal: Claude Code expands it when it runs the hook.
	claude_command='sh "$HOME/.claude/hooks/muxify-status.sh"'
	# Synchronous (no "async") so events stay in order.
	claude_entries=$(jq -n --arg cmd "$claude_command" '
		reduce ("SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest",
			"PostToolUse", "Elicitation", "ElicitationResult", "Stop", "StopFailure",
			"SessionEnd") as $event ({};
			.[$event] =
				(if $event == "PreToolUse" then {matcher: "AskUserQuestion|ExitPlanMode"} else {} end)
				+ {hooks: [{type: "command", command: $cmd, timeout: 5}]})')

	if [ -e "$claude_script" ]; then result=updated; else result=installed; fi
	if ! { mkdir -p "$claude_dir/hooks" &&
		cp "$here/claude/muxify-status.sh" "$claude_script" &&
		chmod 755 "$claude_script"; }; then
		echo "claude: failed (could not copy the hook script)"
		return 1
	fi
	if ! add_hook_entries "$claude_dir/settings.json" "$claude_entries"; then
		echo "claude: failed (could not update settings.json)"
		return 1
	fi
	echo "claude: $result"
}

# Codex CLI: one hook script for every event, registered in hooks.json.
install_codex() {
	codex_dir=$HOME/.codex
	if [ ! -d "$codex_dir" ]; then
		echo "codex: not found"
		return 0
	fi
	if ! command -v jq >/dev/null 2>&1; then
		echo "codex: failed (jq not found)"
		return 1
	fi

	codex_script=$codex_dir/muxify-status.sh
	# Codex runs hook commands through the user's login shell (fish here), so
	# the command is a plain line every shell reads the same way; that shell
	# expands $HOME.
	codex_command='sh "$HOME/.codex/muxify-status.sh"'
	# No matcher (every tool), synchronous so events stay in order.
	codex_entries=$(jq -n --arg cmd "$codex_command" '
		reduce ("SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest",
			"PostToolUse", "Stop", "Interrupt", "SessionEnd") as $event ({};
			.[$event] = {hooks: [{type: "command", command: $cmd, timeout: 5}]})')

	if [ -e "$codex_script" ] || [ -L "$codex_script" ]; then result=updated; else result=installed; fi
	# Remove first, so a symlink in its place is replaced, not written through.
	if ! { rm -f "$codex_script" &&
		cp "$here/codex/muxify-status.sh" "$codex_script" &&
		chmod 755 "$codex_script"; }; then
		echo "codex: failed (could not copy the hook script)"
		return 1
	fi
	if ! add_hook_entries "$codex_dir/hooks.json" "$codex_entries"; then
		echo "codex: failed (could not update hooks.json)"
		return 1
	fi
	echo "codex: $result"
	echo "  Trust the new hooks once: run /hooks in Codex and approve them."
	echo "  Launch Codex with codex --no-daemon (fish: alias codex 'command codex --no-daemon'), or it can't report its Status."
}

# OpenCode 2: a TUI plugin directory, which OpenCode discovers in its plugins
# folder by itself, so no config file is edited.
install_opencode() {
	opencode_dir=$HOME/.config/opencode
	if [ ! -d "$opencode_dir" ]; then
		echo "opencode: not found"
		return 0
	fi

	opencode_plugin=$opencode_dir/plugins/muxify-status
	if [ -e "$opencode_plugin" ] || [ -L "$opencode_plugin" ]; then result=updated; else result=installed; fi
	# Replace the whole directory, so files dropped from the plugin don't linger.
	if ! { mkdir -p "$opencode_dir/plugins" &&
		rm -rf "$opencode_plugin" &&
		cp -R "$here/opencode/muxify-status" "$opencode_plugin"; }; then
		echo "opencode: failed (could not copy the plugin)"
		return 1
	fi
	echo "opencode: $result"
}

# Pi: a single TypeScript file, which Pi loads from its extensions folder by
# itself, so no config file is edited.
install_pi() {
	pi_dir=$HOME/.pi/agent
	if [ ! -d "$pi_dir" ]; then
		echo "pi: not found"
		return 0
	fi

	pi_extension=$pi_dir/extensions/muxify-status.ts
	if [ -e "$pi_extension" ] || [ -L "$pi_extension" ]; then result=updated; else result=installed; fi
	# Remove first, so a symlink in its place is replaced, not written through.
	if ! { mkdir -p "$pi_dir/extensions" &&
		rm -f "$pi_extension" &&
		cp "$here/pi/muxify-status.ts" "$pi_extension"; }; then
		echo "pi: failed (could not copy the extension)"
		return 1
	fi
	echo "pi: $result"
}

for agent in claude codex opencode pi; do
	"install_$agent" || failed=1
done
exit "$failed"
