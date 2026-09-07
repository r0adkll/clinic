import Foundation
import GhosttyKit

/// A single `key = value` line appended to the Ghostty configuration.
public struct GhosttyConfigOverride: Sendable, Hashable {
    public let key: String
    public let value: String
    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}

/// Wraps a finalized `ghostty_config_t`.
///
/// Loading order (mirrors `Ghostty.Config.loadConfig` in Ghostty's macOS app, minus
/// CLI args): `ghostty_config_new` (which installs Ghostty's default keybinds) →
/// optionally `ghostty_config_load_default_files` + `ghostty_config_load_recursive_files`
/// → an override file generated from ``clinicUnboundActions`` and `overrides` →
/// `ghostty_config_finalize`.
///
/// ## Unbinding by action
/// libghostty has no "set" API and no "unbind by action" syntax: the config language
/// only supports `keybind = <trigger>=unbind`. We therefore resolve each action in
/// ``clinicUnboundActions`` to its *current* trigger with `ghostty_config_trigger`
/// (after the user's files are loaded, before finalize), format that trigger back into
/// Ghostty's trigger syntax (`super+shift+n`, `ctrl+key_a`, …) and emit an
/// `unbind` line for it. `ghostty_config_trigger` returns a single trigger per
/// action, so if the user bound the same action to several triggers only one is
/// removed; the remaining ones still reach the app as ``GhosttyAction`` values
/// (`.newWindow`, `.quit`, …) via the runtime's action callback and can be ignored
/// there. The resolved pairs are exposed in ``unboundTriggers``.
@MainActor
public final class GhosttyConfig {
    /// The underlying C handle. Owned by this object; freed in `deinit`.
    /// (`nonisolated(unsafe)` only so the nonisolated deinit may read it.)
    nonisolated(unsafe) let handle: ghostty_config_t

    /// Actions whose (single) trigger is unbound by ``clinicUnboundActions``, with the
    /// trigger string that was written to the override file.
    public private(set) var unboundTriggers: [(action: String, trigger: String)] = []

    /// The Clinic override list from ADR-034 (plain `key = value` lines).
    /// Keybind removal is handled separately via ``clinicUnboundActions``.
    public static let clinicOverrides: [GhosttyConfigOverride] = [
        .init(key: "confirm-close-surface", value: "false"),
    ]

    /// Keybind actions Clinic takes over (ADR-034). Parameterized actions must be given
    /// with every parameter Ghostty binds by default because `ghostty_config_trigger`
    /// looks up the exact action (`new_split:right` and `new_split:down` are distinct).
    public static let clinicUnboundActions: [String] = [
        "new_window", "new_tab", "close_surface", "close_window",
        "close_tab", "quit", "toggle_fullscreen",
        "new_split:right", "new_split:down", "new_split:left", "new_split:up", "new_split:auto",
        "goto_split:previous", "goto_split:next",
        "goto_split:up", "goto_split:left", "goto_split:down", "goto_split:right",
    ]

    /// - Parameters:
    ///   - loadUserDefaults: load `~/.config/ghostty/config` and friends
    ///     (`ghostty_config_load_default_files`) plus any `config-file` includes.
    ///   - overrides: `key = value` lines applied after the user's files.
    ///   - unbindActions: keybind actions to unbind (see the class documentation).
    public init(
        loadUserDefaults: Bool = true,
        overrides: [GhosttyConfigOverride] = GhosttyConfig.clinicOverrides,
        unbindActions: [String] = GhosttyConfig.clinicUnboundActions
    ) throws {
        // Config APIs use the global allocator installed by ghostty_init.
        try GhosttyRuntime.ensureInitialized()

        guard let cfg = ghostty_config_new() else { throw GhosttyError.configCreateFailed }
        self.handle = cfg

        if loadUserDefaults {
            ghostty_config_load_default_files(cfg)
            ghostty_config_load_recursive_files(cfg)
        }

        // Unbind in rounds: `ghostty_config_trigger` reports one trigger per action, and
        // an action may have several (toggle_fullscreen defaults to super+enter *and*
        // super+ctrl+f). After each round of unbinds we query again until every action
        // resolves to nothing (bounded to guard against a trigger we cannot express).
        var pending = Set(unbindActions)
        var round = 0
        while !pending.isEmpty && round < 8 {
            round += 1
            var lines: [String] = []
            for action in pending.sorted() {
                guard let trigger = Self.triggerString(ghostty_config_trigger(cfg, action, UInt(action.utf8.count))) else {
                    pending.remove(action)
                    continue
                }
                unboundTriggers.append((action: action, trigger: trigger))
                lines.append("keybind = \(trigger)=unbind")
            }
            guard !lines.isEmpty else { break }
            Self.load(lines: lines, into: cfg)
        }
        if !pending.isEmpty {
            ghosttyLog.warning("could not fully unbind actions: \(pending.sorted().joined(separator: ", "))")
        }

        if !overrides.isEmpty {
            Self.load(lines: overrides.map { "\($0.key) = \($0.value)" }, into: cfg)
        }

        ghostty_config_finalize(cfg)

        let diags = diagnostics
        if !diags.isEmpty {
            ghosttyLog.warning("ghostty config loaded with \(diags.count) diagnostic(s): \(diags.joined(separator: "; "))")
        }
    }

    deinit {
        ghostty_config_free(handle)
    }

    /// libghostty has no "set" API; extra lines are applied by loading a temporary
    /// config file (`ghostty_config_load_file`), which is removed immediately after.
    private static func load(lines: [String], into cfg: ghostty_config_t) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghostty-bridge-\(UUID().uuidString).conf")
        do {
            try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        } catch {
            ghosttyLog.error("failed to write override config: \(String(describing: error))")
            return
        }
        ghostty_config_load_file(cfg, url.path)
        try? FileManager.default.removeItem(at: url)
    }

    /// Diagnostics (errors/warnings) produced while loading and finalizing.
    public var diagnostics: [String] {
        let count = ghostty_config_diagnostics_count(handle)
        return (0..<count).map { String(cString: ghostty_config_get_diagnostic(handle, $0).message) }
    }

    // MARK: - Typed getters
    //
    // `ghostty_config_get` writes the value's *native* representation into the pointer
    // you pass (see src/config/c_get.zig): strings and enums as `const char*`, bools as
    // `bool`, f32/f64 as-is, u8/u32/packed structs as `unsigned int`. There is no
    // runtime type check, so each getter below must only be used with keys of the
    // matching type. Unknown keys return nil.

    /// Value of a string- or enum-typed key (e.g. `"theme"`, `"window-theme"`, `"shell-integration"`).
    public func string(forKey key: String) -> String? {
        var v: UnsafePointer<CChar>? = nil
        guard ghostty_config_get(handle, &v, key, UInt(key.utf8.count)), let v else { return nil }
        return String(cString: v)
    }

    /// Value of a bool-typed key (e.g. `"confirm-close-surface"`, `"wait-after-command"`).
    public func bool(forKey key: String) -> Bool? {
        var v = false
        guard ghostty_config_get(handle, &v, key, UInt(key.utf8.count)) else { return nil }
        return v
    }

    /// Value of an f32-typed key (e.g. `"font-size"`).
    public func float(forKey key: String) -> Float? {
        var v: Float = 0
        guard ghostty_config_get(handle, &v, key, UInt(key.utf8.count)) else { return nil }
        return v
    }

    /// Value of an f64-typed key (e.g. `"background-opacity"`, `"bell-audio-volume"`).
    public func double(forKey key: String) -> Double? {
        var v: Double = 0
        guard ghostty_config_get(handle, &v, key, UInt(key.utf8.count)) else { return nil }
        return v
    }

    /// Value of a u8/u32/packed-struct-typed key (e.g. `"scrollback-limit"`, `"bell-features"`).
    public func uint(forKey key: String) -> UInt32? {
        var v: CUnsignedInt = 0
        guard ghostty_config_get(handle, &v, key, UInt(key.utf8.count)) else { return nil }
        return UInt32(v)
    }

    /// `font-size` in points (Ghostty's default is 13 on macOS).
    public var fontSize: Float { float(forKey: "font-size") ?? 13 }

    /// The trigger currently bound to `action` in Ghostty's trigger syntax
    /// (e.g. `"super+n"`), or nil if the action is unbound.
    public func trigger(forAction action: String) -> String? {
        Self.triggerString(ghostty_config_trigger(handle, action, UInt(action.utf8.count)))
    }

    // MARK: - Trigger formatting

    /// Names of `ghostty_input_key_e` values as Ghostty's config parser accepts them
    /// (the Zig enum field names from src/input/key.zig; index == raw value).
    static let keyNames: [String] = [
        "unidentified",
        "backquote", "backslash", "bracket_left", "bracket_right", "comma",
        "digit_0", "digit_1", "digit_2", "digit_3", "digit_4", "digit_5", "digit_6", "digit_7", "digit_8", "digit_9",
        "equal", "intl_backslash", "intl_ro", "intl_yen",
        "key_a", "key_b", "key_c", "key_d", "key_e", "key_f", "key_g", "key_h", "key_i", "key_j", "key_k",
        "key_l", "key_m", "key_n", "key_o", "key_p", "key_q", "key_r", "key_s", "key_t", "key_u", "key_v",
        "key_w", "key_x", "key_y", "key_z",
        "minus", "period", "quote", "semicolon", "slash",
        "alt_left", "alt_right", "backspace", "caps_lock", "context_menu", "control_left", "control_right",
        "enter", "meta_left", "meta_right", "shift_left", "shift_right", "space", "tab",
        "convert", "kana_mode", "non_convert",
        "delete", "end", "help", "home", "insert", "page_down", "page_up",
        "arrow_down", "arrow_left", "arrow_right", "arrow_up",
        "num_lock",
        "numpad_0", "numpad_1", "numpad_2", "numpad_3", "numpad_4", "numpad_5", "numpad_6", "numpad_7", "numpad_8", "numpad_9",
        "numpad_add", "numpad_backspace", "numpad_clear", "numpad_clear_entry", "numpad_comma", "numpad_decimal",
        "numpad_divide", "numpad_enter", "numpad_equal", "numpad_memory_add", "numpad_memory_clear",
        "numpad_memory_recall", "numpad_memory_store", "numpad_memory_subtract", "numpad_multiply",
        "numpad_paren_left", "numpad_paren_right", "numpad_subtract", "numpad_separator",
        "numpad_up", "numpad_down", "numpad_right", "numpad_left", "numpad_begin", "numpad_home", "numpad_end",
        "numpad_insert", "numpad_delete", "numpad_page_up", "numpad_page_down",
        "escape",
        "f1", "f2", "f3", "f4", "f5", "f6", "f7", "f8", "f9", "f10", "f11", "f12", "f13", "f14", "f15", "f16",
        "f17", "f18", "f19", "f20", "f21", "f22", "f23", "f24", "f25",
        "fn", "fn_lock", "print_screen", "scroll_lock", "pause",
        "browser_back", "browser_favorites", "browser_forward", "browser_home", "browser_refresh",
        "browser_search", "browser_stop", "eject", "launch_app_1", "launch_app_2", "launch_mail",
        "media_play_pause", "media_select", "media_stop", "media_track_next", "media_track_previous",
        "power", "sleep", "audio_volume_down", "audio_volume_mute", "audio_volume_up", "wake_up",
        "copy", "cut", "paste",
    ]

    /// Formats a `ghostty_input_trigger_s` in the syntax `Binding.Trigger.parse` accepts.
    /// Returns nil for an unset trigger (no binding) or one we cannot express.
    static func triggerString(_ t: ghostty_input_trigger_s) -> String? {
        var parts: [String] = []
        let m = t.mods.rawValue
        if m & GHOSTTY_MODS_CTRL.rawValue != 0 { parts.append("ctrl") }
        if m & GHOSTTY_MODS_ALT.rawValue != 0 { parts.append("alt") }
        if m & GHOSTTY_MODS_SHIFT.rawValue != 0 { parts.append("shift") }
        if m & GHOSTTY_MODS_SUPER.rawValue != 0 { parts.append("super") }

        switch t.tag {
        case GHOSTTY_TRIGGER_PHYSICAL:
            let i = Int(t.key.physical.rawValue)
            guard i > 0, i < keyNames.count else { return nil }  // 0 == unidentified == unset
            parts.append(keyNames[i])
        case GHOSTTY_TRIGGER_UNICODE:
            guard let scalar = Unicode.Scalar(t.key.unicode) else { return nil }
            switch scalar {
            case "+": parts.append("plus")
            case "=", ">", " ", "\t", "\n", "\r": return nil   // would break the keybind grammar
            default: parts.append(String(Character(scalar)))
            }
        case GHOSTTY_TRIGGER_CATCH_ALL:
            parts.append("catch_all")
        default:
            return nil
        }
        return parts.joined(separator: "+")
    }
}
