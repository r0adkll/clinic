import AppKit
import Carbon
import GhosttyKit
import UniformTypeIdentifiers

// Input conversion helpers. The techniques here are lifted from Ghostty's own macOS
// app (vendor/ghostty/macos/Sources/Ghostty/Ghostty.Input.swift and
// NSEvent+Extension.swift, MIT licensed) so key encoding matches Ghostty exactly.

enum GhosttyMods {
    /// Translate NSEvent modifier flags to a `ghostty_input_mods_e`, including the
    /// left/right "side" bits libghostty uses for sided bindings.
    static func from(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var mods: UInt32 = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { mods |= GHOSTTY_MODS_CAPS.rawValue }

        // Device-dependent bits identify which side of the keyboard the modifier is on.
        let raw = flags.rawValue
        if raw & UInt(NX_DEVICERSHIFTKEYMASK) != 0 { mods |= GHOSTTY_MODS_SHIFT_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERCTLKEYMASK) != 0 { mods |= GHOSTTY_MODS_CTRL_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERALTKEYMASK) != 0 { mods |= GHOSTTY_MODS_ALT_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERCMDKEYMASK) != 0 { mods |= GHOSTTY_MODS_SUPER_RIGHT.rawValue }
        return ghostty_input_mods_e(mods)
    }

    /// The inverse of `from(_:)` for the four primary modifiers.
    static func flags(from mods: ghostty_input_mods_e) -> NSEvent.ModifierFlags {
        var flags = NSEvent.ModifierFlags(rawValue: 0)
        if mods.rawValue & GHOSTTY_MODS_SHIFT.rawValue != 0 { flags.insert(.shift) }
        if mods.rawValue & GHOSTTY_MODS_CTRL.rawValue != 0 { flags.insert(.control) }
        if mods.rawValue & GHOSTTY_MODS_ALT.rawValue != 0 { flags.insert(.option) }
        if mods.rawValue & GHOSTTY_MODS_SUPER.rawValue != 0 { flags.insert(.command) }
        return flags
    }
}

enum GhosttyScrollMods {
    /// Packs precision + momentum into `ghostty_input_scroll_mods_t`
    /// (bit 0 = precision, bits 1-3 = momentum phase; see src/input/mouse.zig).
    static func pack(precision: Bool, momentum: NSEvent.Phase) -> ghostty_input_scroll_mods_t {
        var value: Int32 = 0
        if precision { value |= 1 }
        let phase: Int32
        switch momentum {
        case .began: phase = 1
        case .stationary: phase = 2
        case .changed: phase = 3
        case .ended: phase = 4
        case .cancelled: phase = 5
        case .mayBegin: phase = 6
        default: phase = 0
        }
        value |= phase << 1
        return value
    }
}

enum GhosttyMouseButton {
    static func from(buttonNumber: Int) -> ghostty_input_mouse_button_e {
        switch buttonNumber {
        case 0: return GHOSTTY_MOUSE_LEFT
        case 1: return GHOSTTY_MOUSE_RIGHT
        case 2: return GHOSTTY_MOUSE_MIDDLE
        case 3: return GHOSTTY_MOUSE_FOUR
        case 4: return GHOSTTY_MOUSE_FIVE
        case 5: return GHOSTTY_MOUSE_SIX
        case 6: return GHOSTTY_MOUSE_SEVEN
        case 7: return GHOSTTY_MOUSE_EIGHT
        case 8: return GHOSTTY_MOUSE_NINE
        case 9: return GHOSTTY_MOUSE_TEN
        case 10: return GHOSTTY_MOUSE_ELEVEN
        default: return GHOSTTY_MOUSE_UNKNOWN
        }
    }
}

extension NSEvent {
    /// Create a Ghostty key event for a given keyboard action. Does not set `text`
    /// or `composing` (the caller owns the C string lifetime).
    ///
    /// `translationMods` are the modifiers used for the actual character translation
    /// (after `ghostty_surface_key_translation_mods`), if any.
    func ghosttyKeyEvent(
        _ action: ghostty_input_action_e,
        translationMods: NSEvent.ModifierFlags? = nil
    ) -> ghostty_input_key_s {
        var ev = ghostty_input_key_s()
        ev.action = action
        ev.keycode = UInt32(keyCode)
        ev.text = nil
        ev.composing = false

        // macOS gives no way to know which modifiers were consumed producing text.
        // Ghostty's long-standing heuristic: control and command never contribute to
        // translation, everything else did.
        ev.mods = GhosttyMods.from(modifierFlags)
        ev.consumed_mods = GhosttyMods.from(
            (translationMods ?? modifierFlags).subtracting([.control, .command]))

        // The unshifted codepoint is the codepoint with no modifiers. We use
        // `characters(byApplyingModifiers:)` rather than `charactersIgnoringModifiers`
        // because the latter misbehaves with control pressed.
        ev.unshifted_codepoint = 0
        if type == .keyDown || type == .keyUp,
           let chars = characters(byApplyingModifiers: []),
           let cp = chars.unicodeScalars.first {
            ev.unshifted_codepoint = cp.value
        }
        return ev
    }

    /// The text to pass to libghostty for this key event. Strips single control
    /// characters (Ghostty encodes those itself) and private-use function-key values.
    var ghosttyCharacters: String? {
        guard let characters else { return nil }
        if characters.count == 1, let scalar = characters.unicodeScalars.first {
            if scalar.value < 0x20 {
                return self.characters(byApplyingModifiers: modifierFlags.subtracting(.control))
            }
            if scalar.value >= 0xF700 && scalar.value <= 0xF8FF {
                return nil
            }
        }
        return characters
    }
}

/// Identifies the active keyboard input source (Carbon TIS). Ghostty uses this to
/// detect an input method swallowing a key event mid-`interpretKeyEvents`.
enum KeyboardLayout {
    static var id: String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else {
            return nil
        }
        return unsafeBitCast(ptr, to: CFString.self) as String
    }
}

extension NSPasteboard {
    /// The pasteboard Ghostty uses for the "selection" clipboard (primary selection emulation).
    @MainActor
    static let ghosttySelection = NSPasteboard(name: .init("com.clinic.GhosttyBridge.selection"))

    @MainActor
    static func ghostty(_ clipboard: ghostty_clipboard_e) -> NSPasteboard? {
        switch clipboard {
        case GHOSTTY_CLIPBOARD_STANDARD: return .general
        case GHOSTTY_CLIPBOARD_SELECTION: return ghosttySelection
        default: return nil
        }
    }

    /// Ghostty's "opinionated" string read: file URLs become shell-escaped paths
    /// joined by spaces; otherwise the plain string content.
    func ghosttyStringContents() -> String? {
        if let urls = readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty {
            return urls
                .map { $0.isFileURL ? ShellEscape.escape($0.path) : $0.absoluteString }
                .joined(separator: " ")
        }
        return string(forType: .string)
    }

    static func pasteboardType(forMIME mime: String) -> NSPasteboard.PasteboardType? {
        if mime == "text/plain" { return .string }
        if let ut = UTType(mimeType: mime) { return .init(ut.identifier) }
        return .init(mime)
    }
}
