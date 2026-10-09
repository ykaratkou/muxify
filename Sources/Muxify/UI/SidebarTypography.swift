import AppKit
import SwiftUI

/// Sidebar text keeps its existing hierarchy around a configurable base size.
/// Symbols, logos and status dots deliberately do not use this typography.
struct SidebarTypography: Equatable {
    var fontSize: Double = 12
    var fontFamily: String = "system"

    enum Role: CaseIterable {
        case session, title, section, location, badge

        var defaultSize: CGFloat {
            switch self {
            case .session: return 14
            case .title: return 12
            case .section: return 11
            case .location: return 10.5
            case .badge: return 10
            }
        }

        var weight: Font.Weight {
            switch self {
            case .session, .section: return .semibold
            case .badge: return .medium
            case .title, .location: return .regular
            }
        }

        /// NSFontManager's 0–15 weight scale; its lookup chooses the nearest
        /// available weight in a family when there is no exact match.
        var familyWeight: Int {
            switch self {
            case .session, .section: return 8
            case .badge: return 6
            case .title, .location: return 5
            }
        }
    }

    func size(for role: Role) -> CGFloat {
        // Form the role ratio first to avoid losing tiny positive base sizes
        // or overflowing merely from multiplication by the original size.
        min(CGFloat(fontSize) * (role.defaultSize / 12), .greatestFiniteMagnitude)
    }

    func font(for role: Role,
              lookup: (String, Int, CGFloat) -> NSFont? = Self.lookup) -> Font {
        let size = size(for: role)
        if fontFamily != "system", let font = lookup(fontFamily, role.familyWeight, size) {
            return Font(font)
        }
        return .system(size: size, weight: role.weight)
    }

    static func lookup(family: String, weight: Int, size: CGFloat) -> NSFont? {
        NSFontManager.shared.font(withFamily: family, traits: [], weight: weight, size: size)
    }

    static var fontFamilies: [String] { NSFontManager.shared.availableFontFamilies }

    /// Preserve native system-font selection instead of naming a particular
    /// system face. The catalogue is injectable without requiring test fonts.
    static func canonicalFamily(_ name: String,
                                families: () -> [String] = { Self.fontFamilies }) -> String? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        if name.caseInsensitiveCompare("system") == .orderedSame { return "system" }
        return families().first { $0.caseInsensitiveCompare(name) == .orderedSame }
    }
}

private struct SidebarTypographyKey: EnvironmentKey {
    static let defaultValue = SidebarTypography()
}

extension EnvironmentValues {
    var sidebarTypography: SidebarTypography {
        get { self[SidebarTypographyKey.self] }
        set { self[SidebarTypographyKey.self] = newValue }
    }
}
