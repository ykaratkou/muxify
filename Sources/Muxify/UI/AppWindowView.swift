import AppKit
import SwiftUI

struct AppWindowView: View {
    let request: AppWindowRequest
    let windows: AppWindows
    @State private var store: WorkspaceStore
    @Environment(\.openWindow) private var openWindow

    init(request: AppWindowRequest, windows: AppWindows) {
        self.request = request
        self.windows = windows
        _store = State(initialValue: windows.store(for: request))
    }

    var body: some View {
        ContentView(store: store, configStore: windows.configStore)
            .frame(minWidth: 820, minHeight: 480)
            .background(AppWindowRegistration { windows.register($0, for: request.id) })
            .onAppear {
                let action = openWindow
                windows.openWindow = { action(id: "workspace", value: $0) }
            }
            .onChange(of: store.activeEnvironment) { _, _ in windows.updateEnvironment(for: request.id) }
    }
}

private struct AppWindowRegistration: NSViewRepresentable {
    let register: (NSWindow) -> Void
    func makeNSView(context: Context) -> RegistrationView { RegistrationView() }
    func updateNSView(_ view: RegistrationView, context: Context) { view.register = register; view.registerWindow() }

    final class RegistrationView: NSView {
        var register: ((NSWindow) -> Void)?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); registerWindow() }
        func registerWindow() {
            guard let window else { return }
            // Register outside SwiftUI layout; focus can update menu state.
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window, self.window === window else { return }
                self.register?(window)
            }
        }
    }
}
