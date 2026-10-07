import SwiftUI

// Disposable on-device fixture for testing real input, not just successful HID calls.
@main
struct SimulatorSmokeApp: App {
    var body: some Scene { WindowGroup { FixtureView() } }
}

private struct FixtureView: View {
    @State private var text = ""
    @State private var taps = 0
    @State private var drags = 0
    @State private var size = CGSize.zero
    @State private var lastTap = CGPoint.zero
    @FocusState private var textFocused: Bool
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        GeometryReader { geometry in
            Text("Muxify Simulator Smoke Test")
                .position(x: geometry.size.width / 2, y: geometry.size.height * 0.1)
            TextField("Type here", text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($textFocused)
                .submitLabel(.done)
                .onSubmit { textFocused = false }
                .textFieldStyle(.roundedBorder)
                .frame(width: geometry.size.width * 0.8)
                .position(x: geometry.size.width / 2, y: geometry.size.height * 0.25)
            Rectangle().fill(.blue)
                .frame(width: 150, height: 150)
                .gesture(DragGesture(minimumDistance: 0).onEnded { _ in drags += 1; save() })
                .position(x: geometry.size.width / 2, y: geometry.size.height * 0.5)
            Button("Tap: \(taps)") { taps += 1; save() }
                .frame(width: 150, height: 60)
                .position(x: geometry.size.width / 2, y: geometry.size.height * 0.75)
            Color.clear.allowsHitTesting(false)
                .onAppear { size = geometry.size; save() }
                .onChange(of: geometry.size) { _, value in size = value; save() }
        }
        .ignoresSafeArea()
        .simultaneousGesture(SpatialTapGesture().onEnded { value in lastTap = value.location; save() })
        .onAppear { save() }
        .onChange(of: text) { _, _ in save() }
        .onChange(of: textFocused) { _, _ in save() }
        .onChange(of: scenePhase) { _, _ in save() }
    }

    private func save() {
        let path = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("smoke.json")
        let state: [String: Any] = ["text": text, "textFocused": textFocused, "taps": taps, "drags": drags,
                                    "width": size.width, "height": size.height,
                                    "lastTapX": size.width > 0 ? lastTap.x / size.width : 0,
                                    "lastTapY": size.height > 0 ? lastTap.y / size.height : 0,
                                    "phase": String(describing: scenePhase)]
        if let data = try? JSONSerialization.data(withJSONObject: state) { try? data.write(to: path, options: .atomic) }
    }
}
