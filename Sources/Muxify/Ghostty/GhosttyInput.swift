import AppKit
import GhosttyKit

/// NSEvent -> libghostty input conversions.
enum GhosttyInput {
    // Device-dependent right-side modifier bits (IOKit's NX_DEVICER*KEYMASK).
    private static let rightShift: UInt = 0x0000_0004
    private static let rightControl: UInt = 0x0000_2000
    private static let rightOption: UInt = 0x0000_0040
    private static let rightCommand: UInt = 0x0000_0010

    static let modifierPairs: [(NSEvent.ModifierFlags, ghostty_input_mods_e)] = [
        (.shift, GHOSTTY_MODS_SHIFT),
        (.control, GHOSTTY_MODS_CTRL),
        (.option, GHOSTTY_MODS_ALT),
        (.command, GHOSTTY_MODS_SUPER),
    ]

    static func mods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var mods = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { mods |= GHOSTTY_MODS_CAPS.rawValue }
        let raw = flags.rawValue
        if raw & rightShift != 0 { mods |= GHOSTTY_MODS_SHIFT_RIGHT.rawValue }
        if raw & rightControl != 0 { mods |= GHOSTTY_MODS_CTRL_RIGHT.rawValue }
        if raw & rightOption != 0 { mods |= GHOSTTY_MODS_ALT_RIGHT.rawValue }
        if raw & rightCommand != 0 { mods |= GHOSTTY_MODS_SUPER_RIGHT.rawValue }
        return ghostty_input_mods_e(rawValue: mods)
    }

    static func keyEvent(
        _ event: NSEvent,
        action: ghostty_input_action_e,
        translationMods: NSEvent.ModifierFlags? = nil
    ) -> ghostty_input_key_s {
        var key = ghostty_input_key_s()
        key.action = action
        key.keycode = UInt32(event.keyCode)
        key.text = nil
        key.composing = false
        key.mods = mods(event.modifierFlags)
        // Control and command never contribute to text translation.
        key.consumed_mods = mods((translationMods ?? event.modifierFlags).subtracting([.control, .command]))
        key.unshifted_codepoint = 0
        if event.type == .keyDown || event.type == .keyUp,
           let chars = event.characters(byApplyingModifiers: []),
           let scalar = chars.unicodeScalars.first {
            key.unshifted_codepoint = scalar.value
        }
        return key
    }

    /// Text for a key event as libghostty expects it: control characters are
    /// re-derived without ctrl, and AppKit's private-use function-key
    /// characters are dropped.
    static func characters(_ event: NSEvent) -> String? {
        guard let characters = event.characters else { return nil }
        if characters.count == 1, let scalar = characters.unicodeScalars.first {
            if scalar.value < 0x20 {
                return event.characters(byApplyingModifiers: event.modifierFlags.subtracting(.control))
            }
            if (0xF700...0xF8FF).contains(scalar.value) { return nil }
        }
        return characters
    }

    static func modifier(forKeyCode keyCode: UInt16) -> ghostty_input_mods_e? {
        switch keyCode {
        case 0x39: return GHOSTTY_MODS_CAPS
        case 0x38, 0x3C: return GHOSTTY_MODS_SHIFT
        case 0x3B, 0x3E: return GHOSTTY_MODS_CTRL
        case 0x3A, 0x3D: return GHOSTTY_MODS_ALT
        case 0x37, 0x36: return GHOSTTY_MODS_SUPER
        default: return nil
        }
    }

    /// For right-hand modifier keys, whether that side is the one held down.
    static func sidePressed(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        let raw = flags.rawValue
        switch keyCode {
        case 0x3C: return raw & rightShift != 0
        case 0x3E: return raw & rightControl != 0
        case 0x3D: return raw & rightOption != 0
        case 0x36: return raw & rightCommand != 0
        default: return true
        }
    }

    /// Packed scroll mods: bit 0 = precision, bits 1-3 = momentum phase.
    static func scrollMods(precise: Bool, phase: NSEvent.Phase) -> ghostty_input_scroll_mods_t {
        var momentum = GHOSTTY_MOUSE_MOMENTUM_NONE
        switch phase {
        case .began: momentum = GHOSTTY_MOUSE_MOMENTUM_BEGAN
        case .stationary: momentum = GHOSTTY_MOUSE_MOMENTUM_STATIONARY
        case .changed: momentum = GHOSTTY_MOUSE_MOMENTUM_CHANGED
        case .ended: momentum = GHOSTTY_MOUSE_MOMENTUM_ENDED
        case .cancelled: momentum = GHOSTTY_MOUSE_MOMENTUM_CANCELLED
        case .mayBegin: momentum = GHOSTTY_MOUSE_MOMENTUM_MAY_BEGIN
        default: break
        }
        var value: Int32 = precise ? 1 : 0
        value |= Int32(momentum.rawValue) << 1
        return value
    }

    // MARK: - Drag and drop

    static let dropTypes: [NSPasteboard.PasteboardType] = [.string, .fileURL]

    private static let promisedFileURL = NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-url")

    /// Text a drop pastes, as Ghostty does: file paths shell-escaped, other
    /// items as plain text, joined by spaces. Programs like Claude Code turn a
    /// pasted image path into an attachment.
    ///
    /// Promised files (e.g. the screenshot thumbnail) live in a private
    /// TemporaryItems folder only the drop target may read, not processes
    /// under the tmux server, so they are copied into `stagingDirectory` first.
    static func dropText(_ pasteboard: NSPasteboard, stagingDirectory: URL? = nil) -> String? {
        let items = (pasteboard.pasteboardItems ?? []).compactMap { item -> String? in
            if let plist = item.propertyList(forType: .fileURL),
               var url = NSURL(pasteboardPropertyList: plist, ofType: .fileURL) as URL?,
               url.isFileURL {
                if let stagingDirectory, item.types.contains(promisedFileURL) {
                    url = stage(url, in: stagingDirectory) ?? url
                }
                return shellEscape(url.path)
            }
            return item.string(forType: .string)
        }
        return items.isEmpty ? nil : items.joined(separator: " ")
    }

    /// Copies a file into a fresh folder under `directory`, keeping its name.
    static func stage(_ file: URL, in directory: URL) -> URL? {
        let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let copy = folder.appendingPathComponent(file.lastPathComponent)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: file, to: copy)
            return copy
        } catch {
            return nil
        }
    }

    /// Backslash-escapes shell-sensitive characters (Ghostty's set).
    static func shellEscape(_ text: String) -> String {
        let special: Set<Character> = ["\\", " ", "(", ")", "[", "]", "{", "}", "<", ">",
                                       "\"", "'", "`", "!", "#", "$", "&", ";", "|", "*", "?", "\t"]
        var result = ""
        for char in text {
            if special.contains(char) { result.append("\\") }
            result.append(char)
        }
        return result
    }
}
