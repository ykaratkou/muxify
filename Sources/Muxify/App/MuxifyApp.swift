import AppKit
import SwiftUI

@main
struct MuxifyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var windows: AppWindows

    init() {
        AppEnvironment.prepare()
        let configStore = ConfigStore()
        configStore.start()
        let windows = AppWindows(configStore: configStore)
        _windows = State(initialValue: windows)
        GhosttyRuntime.shared.delegate = windows
    }

    var body: some Scene {
        WindowGroup("Muxify", id: "workspace", for: AppWindowRequest.self) { request in
            AppWindowView(request: request.wrappedValue, windows: windows)
                .onAppear {
                    appDelegate.shutdown = windows.shutdown
                    appDelegate.openURLs = { $0.forEach(windows.handle) }
                }
        } defaultValue: {
            windows.initialRequest
        }
        .defaultSize(width: 1500, height: 920)
        .windowStyle(.hiddenTitleBar)
        .commands { MuxifyCommands(windows: windows) }
    }
}

enum AppEnvironment {
    /// Process environment fixes that must happen before libghostty and the
    /// first tmux invocation, since both are inherited by child processes.
    static func prepare() {
        // Launched from inside tmux (e.g. `open` in a pane), tmux refuses to nest.
        unsetenv("TMUX")
        unsetenv("TMUX_PANE")

        // Finder-launched apps get no locale; tmux then draws Unicode as `_`.
        if getenv("LANG") == nil { setenv("LANG", "en_US.UTF-8", 1) }

        // Finder-launched apps get a minimal PATH; make Homebrew tools visible.
        var path = (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
            .split(separator: ":").map(String.init)
        for dir in ["/usr/local/bin", "/opt/homebrew/sbin", "/opt/homebrew/bin"] where !path.contains(dir) {
            path.insert(dir, at: 0)
        }
        setenv("PATH", path.joined(separator: ":"), 1)

        // libghostty finds terminfo/themes inside our bundle (copied at build
        // time). If they are missing, borrow them from an installed Ghostty.app.
        let fm = FileManager.default
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("terminfo/78/xterm-ghostty").path ?? ""
        let installed = "/Applications/Ghostty.app/Contents/Resources/ghostty"
        if !fm.fileExists(atPath: bundled), getenv("GHOSTTY_RESOURCES_DIR") == nil, fm.fileExists(atPath: installed) {
            setenv("GHOSTTY_RESOURCES_DIR", installed, 1)
        }
    }
}
