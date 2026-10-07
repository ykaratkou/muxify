# Muxify

A personal macOS front end for tmux with a Sidebar, Terminal and Browser. Muxify also provides a Simulator that can be opened in any web browser to interact with Devices on a local or remote Mac.

## Language

### Environments

**Environment**:
The context whose Sessions, Windows, Panes and Agents Muxify presents. Local is the Environment on the machine running Muxify.
_Avoid_: workspace, project

**Remote Environment**:
An Environment on another machine, presented in the local Muxify app.
_Avoid_: remote Session, SSH session (when you mean the Environment)

**Active Environment**:
The Environment shown in an App Window. Each App Window has one Active Environment.
_Avoid_: current host, active workspace

### tmux

**Session**:
A tmux session, usually one per project. Sessions group Windows in the sidebar.
_Avoid_: project, workspace

**Window**:
A tmux window: the item you pick in the sidebar. Opening it shows all of its Panes.
_Avoid_: tab, workspace

**Pane**:
One split of a Window, laid out by tmux.
_Avoid_: split, terminal

### Browser

**Browser**:
The web browsing view beside the Terminal. Each Window has its own Browser and Tabs; switching Windows switches the Browser too.
_Avoid_: webview, inspector, sidebar browser

**Tab**:
One page in a Window's Browser, with its own back/forward history. "Tab" never means a tmux Window.
_Avoid_: page (when you mean the Tab itself), browser window

### Simulator

**Simulator**:
The browser-based interface for selecting, viewing and controlling Devices on a Mac. It is independent of tmux Windows and can be opened in Muxify's Browser or another web browser. Each browser tab chooses its own Device; multiple tabs may view and control the same Device, sharing its screen, orientation and running state.
_Avoid_: Device Hub, mirror, simulator runtime

**Device**:
A simulated iPhone or iPad used to run and test apps, never a physical phone or tablet. Its selection and running state are independent: selecting or displaying it does not mean starting it.
_Avoid_: simulator (when you mean the Device rather than its view), phone (when you also mean iPad)

**Simulator Server**:
The Muxify process on the Mac that makes its Devices available to the Simulator. Devices can keep running when the Simulator disconnects or the Simulator Server exits.
_Avoid_: desktop streamer, remote desktop

### Agents

**Agent**:
A coding-agent CLI (Claude Code, Codex, OpenCode or Pi) running in a Pane, which reports its Status to Muxify through its Extension. The agent's own conversation is a "conversation", never a Session.
_Avoid_: bot, assistant, agent session

**Status**:
What an Agent is doing: working (a turn is running), blocked (waiting for the user to answer a permission prompt or question), done (the last turn ended, including by Esc) or failed (the last turn ended with an error). An Agent that has not run a turn yet has no Status.
_Avoid_: state, idle

**Unread**:
An Agent that reached done, failed or blocked while the user wasn't looking at its Window. Looking at the Window makes it read.
_Avoid_: unseen, new, notification

**Extension**:
The file or plugin folder installed into an Agent's own plugin or hook system that reports the Agent and its Status to Muxify.
_Avoid_: integration, hook (when you mean the whole file), plugin (when you mean ours)

### Layout

**App Window**:
A native macOS Muxify window, with its own Active Environment, selected tmux Window, terminal and Browser.
_Avoid_: instance, Window (without "App", when you mean the native window)

**Sidebar**:
The panel on the left of the Muxify window that lists Sessions, Windows and Agents.
_Avoid_: left sidebar, left panel

### Configuration

**Config**:
The Muxify config file: settings, in YAML sections, that control how Muxify itself behaves. It never holds what is open or shown now.
_Avoid_: settings, preferences, Muxify settings

**Ghostty config**:
The Ghostty config files that control the terminal: its fonts, theme and terminal keybinds.
_Avoid_: terminal config
