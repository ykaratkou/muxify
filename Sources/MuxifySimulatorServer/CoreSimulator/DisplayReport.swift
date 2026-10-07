import CoreGraphics
import Foundation
import XPC

/// The guest's display report identifies the input target and initial orientation.
struct DisplayReport: Sendable {
    struct Display: Sendable {
        let uniqueID: String
        let displayID: Int
        let isActive: Bool
        let isIntegrated: Bool
        let pixelSize: CGSize
        /// Clockwise degrees the guest's layout on this screen is turned from the framebuffer.
        let currentRotation: Int
    }

    private enum Backlight: String {
        case off
        case inactiveOn
        case activeOn
        case activeDimmed
        case unknown
    }

    let displays: [Display]

    /// The screen the guest is laying out on. Two active ones mean the report cannot be trusted.
    var activeIntegrated: Display? {
        let active = displays.filter { $0.isActive && $0.isIntegrated }
        return active.count == 1 ? active[0] : nil
    }

    static let maximumDisplays = 32

    /// Refuses a report that does not hold together: the wrong panel is worse than no panel.
    static func parse(_ output: xpc_object_t) throws -> DisplayReport {
        guard XPCValue.bool(output, "current") == true else {
            throw CoreSimulatorError.privateCall(symbol: "displayinfo", message: "the report is not current")
        }
        guard let records = XPCValue.array(output, "displays") else {
            throw CoreSimulatorError.privateCall(symbol: "displayinfo", message: "the report lists no displays")
        }
        guard records.count <= maximumDisplays else {
            throw CoreSimulatorError.privateCall(symbol: "displayinfo", message: "the report lists too many displays")
        }
        let carriesLayoutActivity = records.contains { XPCValue.bool($0, "active") != nil }
        // iOS 26.5 under Xcode 27 identifies displays by displayId, marks the
        // active built-in display as primary, and reports backlight at the top level.
        // Keep the newer per-panel format strict rather than mixing the two schemas.
        let legacy = !carriesLayoutActivity && records.allSatisfy { XPCValue.string($0, "uniqueId") == nil }
        var seen: Set<String> = []
        var displays: [Display] = []
        for record in records {
            let legacyID = XPCValue.number(record, "displayId").flatMap { $0 > 0 ? "display:\(Int($0))" : nil }
            guard let uniqueID = XPCValue.string(record, "uniqueId") ?? (legacy ? legacyID : nil), !uniqueID.isEmpty,
                  seen.insert(uniqueID).inserted else {
                throw CoreSimulatorError.privateCall(symbol: "displayinfo", message: "a display has no identity of its own")
            }
            let integrated = XPCValue.dictionary(record, "type").map {
                xpc_dictionary_get_value($0, "integrated") != nil
            } ?? false
            let primary = XPCValue.bool(record, "primary") ?? false
            let backlight = Backlight(rawValue: XPCValue.string(record, "backlightState") ??
                                     (legacy && primary ? XPCValue.string(output, "backlightState") : nil) ?? "") ?? .unknown
            let isActive: Bool
            if carriesLayoutActivity {
                // Layout is the authority when present; the backlight can lag it mid fold.
                guard let active = XPCValue.bool(record, "active") else {
                    throw CoreSimulatorError.privateCall(symbol: "displayinfo", message: "a display has no activity")
                }
                isActive = active
            } else if legacy {
                guard XPCValue.bool(record, "primary") != nil else {
                    throw CoreSimulatorError.privateCall(symbol: "displayinfo", message: "a legacy display has no primary flag")
                }
                isActive = primary
            } else {
                switch backlight {
                case .activeOn, .activeDimmed: isActive = true
                case .off, .inactiveOn: isActive = false
                case .unknown:
                    throw CoreSimulatorError.privateCall(symbol: "displayinfo", message: "a display's activity is unknown")
                }
            }

            let bounds = XPCValue.array(record, "bounds")?.compactMap { corner -> CGPoint? in
                guard let values = XPCValue.array(corner), values.count == 2,
                      let x = XPCValue.number(values[0]), let y = XPCValue.number(values[1]) else { return nil }
                return CGPoint(x: x, y: y)
            } ?? []
            let size: CGSize = bounds.count == 2
                ? CGSize(width: bounds[1].x - bounds[0].x, height: bounds[1].y - bounds[0].y)
                : .zero
            guard !isActive || (size.width > 0 && size.height > 0) else {
                throw CoreSimulatorError.privateCall(symbol: "displayinfo", message: "the active display has no size")
            }

            displays.append(Display(
                uniqueID: uniqueID,
                displayID: Int(XPCValue.number(record, "displayId") ?? 0),
                isActive: isActive,
                isIntegrated: integrated,
                pixelSize: size,
                currentRotation: Self.degrees(XPCValue.string(record, "currentOrientation"))
            ))
        }
        return DisplayReport(displays: displays)
    }

    /// The report writes a rotation as `rot0`, `rot90`, `rot180` or `rot270`.
    static func degrees(_ rotation: String?) -> Int {
        guard let rotation, rotation.hasPrefix("rot"), let value = Int(rotation.dropFirst(3)) else { return 0 }
        return ((value % 360) + 360) % 360
    }
}

/// XPC reports encode numbers as signed, unsigned or double values.
enum XPCValue {
    static func string(_ dictionary: xpc_object_t, _ key: String) -> String? {
        guard let value = xpc_dictionary_get_value(dictionary, key), xpc_get_type(value) == XPC_TYPE_STRING,
              let text = xpc_string_get_string_ptr(value) else { return nil }
        return String(cString: text)
    }

    static func bool(_ dictionary: xpc_object_t, _ key: String) -> Bool? {
        guard let value = xpc_dictionary_get_value(dictionary, key), xpc_get_type(value) == XPC_TYPE_BOOL else { return nil }
        return xpc_bool_get_value(value)
    }

    static func number(_ dictionary: xpc_object_t, _ key: String) -> Double? {
        xpc_dictionary_get_value(dictionary, key).flatMap { number($0) }
    }

    static func number(_ value: xpc_object_t) -> Double? {
        switch xpc_get_type(value) {
        case XPC_TYPE_INT64: Double(xpc_int64_get_value(value))
        case XPC_TYPE_UINT64: Double(xpc_uint64_get_value(value))
        case XPC_TYPE_DOUBLE: xpc_double_get_value(value)
        default: nil
        }
    }

    static func array(_ dictionary: xpc_object_t, _ key: String) -> [xpc_object_t]? {
        xpc_dictionary_get_value(dictionary, key).flatMap { array($0) }
    }

    static func array(_ value: xpc_object_t) -> [xpc_object_t]? {
        guard xpc_get_type(value) == XPC_TYPE_ARRAY else { return nil }
        return (0..<xpc_array_get_count(value)).map { xpc_array_get_value(value, $0) }
    }

    static func dictionary(_ dictionary: xpc_object_t, _ key: String) -> xpc_object_t? {
        guard let value = xpc_dictionary_get_value(dictionary, key), xpc_get_type(value) == XPC_TYPE_DICTIONARY else { return nil }
        return value
    }
}
