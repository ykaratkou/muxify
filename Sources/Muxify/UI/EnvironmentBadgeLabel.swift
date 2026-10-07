import SwiftUI

/// Blue identifies a Remote Environment, even while its SSH connection is down.
/// Connection status is a separate indicator; Local keeps neutral chrome.
struct EnvironmentBadgeLabel: View {
    let name: String
    let isRemote: Bool
    let isConnected: Bool
    let hasConnectionError: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    enum Indicator { case none, connecting, disconnected }

    var indicator: Indicator {
        guard isRemote, !isConnected else { return .none }
        return hasConnectionError ? .disconnected : .connecting
    }

    /// A slightly deeper blue keeps small white text readable in both themes.
    private static let remoteBlue = Color(red: 0.12, green: 0.35, blue: 0.76)

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: isRemote ? "cloud.fill" : "desktopcomputer")
                .accessibilityHidden(true)
            Text(name)
                .lineLimit(1)
                .truncationMode(.tail)
            switch indicator {
            case .none:
                EmptyView()
            case .connecting:
                // Keep the activity indicator in SwiftUI, like the rest of the badge.
                TimelineView(.animation(minimumInterval: 1.0 / 24, paused: reduceMotion)) { context in
                    Circle()
                        .trim(from: 0.1, to: 0.85)
                        .stroke(.white, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                        .rotationEffect(.degrees(reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1) * 360))
                }
                .frame(width: 10, height: 10)
                .accessibilityHidden(true)
            case .disconnected:
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.yellow)
                    .accessibilityHidden(true)
            }
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .semibold))
                .accessibilityHidden(true)
        }
        .font(.system(size: 12, weight: isRemote ? .medium : .regular))
        .foregroundStyle(isRemote ? Color.white : Color.primary)
        .padding(.horizontal, 8)
        .frame(maxWidth: 200)
        .frame(height: 22)
        .background(Capsule().fill(isRemote ? Self.remoteBlue : Color.primary.opacity(0.05)))
        .contentShape(Capsule())
    }
}
