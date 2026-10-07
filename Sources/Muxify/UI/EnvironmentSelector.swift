import SwiftUI

/// Keep the badge in a SwiftUI button-style Menu. macOS's borderless menu
/// extracts only its label's image/text and discards the capsule and colors.
struct EnvironmentSelector: View {
    let environments: [RemoteEnvironment]
    let activeEnvironment: RemoteEnvironment?
    let isConnected: Bool
    let hasConnectionError: Bool
    let status: String
    let onSelect: (String?) -> Void

    var body: some View {
        Menu {
            Button { onSelect(nil) } label: {
                Label("Local", systemImage: activeEnvironment == nil ? "checkmark" : "desktopcomputer")
            }
            ForEach(environments) { environment in
                Button { onSelect(environment.name) } label: {
                    Label(environment.name, systemImage: activeEnvironment == environment ? "checkmark" : "cloud")
                }
            }
        } label: {
            EnvironmentBadgeLabel(name: activeEnvironment?.name ?? "Local", isRemote: activeEnvironment != nil,
                                  isConnected: isConnected, hasConnectionError: hasConnectionError)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityLabel("Environment")
        .accessibilityValue(activeEnvironment == nil ? "Local" : status)
        .help(status)
    }
}
