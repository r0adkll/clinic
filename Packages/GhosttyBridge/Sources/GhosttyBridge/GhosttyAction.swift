import AppKit
import Foundation
import GhosttyKit

/// The state of an OSC 9;4 progress report (`ghostty_action_progress_report_state_e`).
public enum GhosttyProgressState: Sendable {
    case remove, set, error, indeterminate, pause

    init(_ c: ghostty_action_progress_report_state_e) {
        switch c {
        case GHOSTTY_PROGRESS_STATE_REMOVE: self = .remove
        case GHOSTTY_PROGRESS_STATE_SET: self = .set
        case GHOSTTY_PROGRESS_STATE_ERROR: self = .error
        case GHOSTTY_PROGRESS_STATE_INDETERMINATE: self = .indeterminate
        case GHOSTTY_PROGRESS_STATE_PAUSE: self = .pause
        default: self = .remove
        }
    }
}

/// A libghostty runtime action (`ghostty_action_s`) surfaced to the host app.
///
/// This is the ADR-035 milestone 1 set. Every other action arrives as
/// ``unhandled(kind:)`` carrying the lowercase name of the `ghostty_action_tag_e`
/// case (e.g. `"desktop_notification"`, `"close_window"`).
///
/// `@unchecked Sendable` only because ``mouseShape(_:)`` carries an `NSCursor`;
/// actions are created and consumed exclusively on the main actor.
public enum GhosttyAction: @unchecked Sendable {
    /// The terminal set its title (OSC 0/2).
    case setTitle(String)
    /// The terminal reported its working directory (OSC 7).
    case pwd(String)
    /// BEL.
    case ringBell
    /// OSC 9;4 progress. `percent` is nil when the report carried no value.
    case progressReport(state: GhosttyProgressState, percent: Int?)
    /// Shell integration reported a command finished. `exitCode` is nil when none was
    /// reported; `duration` is the wall-clock run time.
    case commandFinished(exitCode: Int32?, duration: TimeInterval?)
    /// The terminal asked for a pointer shape. `nil` means a shape we don't map to an
    /// `NSCursor` (the view leaves the pointer unchanged). The view already applied the
    /// cursor before the delegate sees this.
    case mouseShape(NSCursor?)
    /// The terminal asked to open a URL/path. `kind` is `"text"`, `"html"` or `"unknown"`
    /// (Ghostty's hint about the target). If neither the surface delegate nor the app
    /// handler returns true, the runtime opens it with `NSWorkspace` like Ghostty does.
    case openURL(URL, kind: String)
    /// Derived from a `color_change` of the background color (OSC 11 / theme): `dark`
    /// is true when the new background's luminance is below 0.5.
    case colorScheme(dark: Bool)
    /// The `quit` keybind/action fired.
    case quit
    /// The `new_tab` keybind/action fired.
    case newTab
    /// The `new_window` keybind/action fired.
    case newWindow
    /// The `new_split` keybind/action fired (direction is not carried in milestone 1).
    case newSplit
    /// Any other action; `kind` is the snake_case name of the C tag.
    case unhandled(kind: String)

    /// Human readable name of a `ghostty_action_tag_e`, in the same snake_case form
    /// Ghostty uses in its own logs/config (index == raw value of the tag).
    static let tagNames: [String] = [
        "quit", "new_window", "new_tab", "close_tab", "new_split", "close_all_windows",
        "toggle_maximize", "toggle_fullscreen", "toggle_tab_overview",
        "toggle_window_decorations", "toggle_quick_terminal", "toggle_command_palette",
        "toggle_visibility", "toggle_background_opacity", "move_tab", "goto_tab",
        "goto_split", "goto_window", "resize_split", "equalize_splits",
        "toggle_split_zoom", "present_terminal", "size_limit", "reset_window_size",
        "initial_size", "cell_size", "scrollbar", "render", "inspector",
        "show_gtk_inspector", "render_inspector", "desktop_notification", "set_title",
        "set_tab_title", "prompt_title", "pwd", "mouse_shape", "mouse_visibility",
        "mouse_over_link", "renderer_health", "open_config", "quit_timer",
        "float_window", "secure_input", "key_sequence", "key_table", "color_change",
        "reload_config", "config_change", "close_window", "ring_bell", "undo", "redo",
        "check_for_updates", "open_url", "show_child_exited", "progress_report",
        "show_on_screen_keyboard", "command_finished", "start_search", "end_search",
        "search_total", "search_selected", "readonly", "copy_title_to_clipboard",
    ]

    static func kindName(_ tag: ghostty_action_tag_e) -> String {
        let i = Int(tag.rawValue)
        return i >= 0 && i < tagNames.count ? tagNames[i] : "unknown_\(i)"
    }

    /// Maps a libghostty mouse shape to an `NSCursor`. Returns nil for shapes without a
    /// reasonable AppKit equivalent. (Mapping mirrors Ghostty's `setCursorShape`.)
    @MainActor
    static func cursor(for shape: ghostty_action_mouse_shape_e) -> NSCursor? {
        switch shape {
        case GHOSTTY_MOUSE_SHAPE_DEFAULT: return .arrow
        case GHOSTTY_MOUSE_SHAPE_TEXT: return .iBeam
        case GHOSTTY_MOUSE_SHAPE_GRAB: return .openHand
        case GHOSTTY_MOUSE_SHAPE_GRABBING: return .closedHand
        case GHOSTTY_MOUSE_SHAPE_POINTER: return .pointingHand
        case GHOSTTY_MOUSE_SHAPE_W_RESIZE: return .resizeLeft
        case GHOSTTY_MOUSE_SHAPE_E_RESIZE: return .resizeRight
        case GHOSTTY_MOUSE_SHAPE_N_RESIZE: return .resizeUp
        case GHOSTTY_MOUSE_SHAPE_S_RESIZE: return .resizeDown
        case GHOSTTY_MOUSE_SHAPE_NS_RESIZE: return .resizeUpDown
        case GHOSTTY_MOUSE_SHAPE_EW_RESIZE: return .resizeLeftRight
        case GHOSTTY_MOUSE_SHAPE_VERTICAL_TEXT: return .iBeamCursorForVerticalLayout
        case GHOSTTY_MOUSE_SHAPE_CONTEXT_MENU: return .contextualMenu
        case GHOSTTY_MOUSE_SHAPE_CROSSHAIR: return .crosshair
        case GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED, GHOSTTY_MOUSE_SHAPE_NO_DROP: return .operationNotAllowed
        case GHOSTTY_MOUSE_SHAPE_COPY: return .dragCopy
        case GHOSTTY_MOUSE_SHAPE_ALIAS: return .dragLink
        default: return nil
        }
    }

    /// Decodes the URL of an `open_url` action the way Ghostty does: absolute URLs with a
    /// scheme are used as-is, anything else is treated as a (tilde-expanded) file path.
    static func url(from v: ghostty_action_open_url_s) -> URL? {
        guard let ptr = v.url else { return nil }
        let raw = String(decoding: UnsafeRawBufferPointer(start: ptr, count: Int(v.len)), as: UTF8.self)
        guard !raw.isEmpty else { return nil }
        if let candidate = URL(string: raw), candidate.scheme != nil { return candidate }
        return URL(filePath: NSString(string: raw).standardizingPath)
    }

    static func urlKind(_ kind: ghostty_action_open_url_kind_e) -> String {
        switch kind {
        case GHOSTTY_ACTION_OPEN_URL_KIND_TEXT: return "text"
        case GHOSTTY_ACTION_OPEN_URL_KIND_HTML: return "html"
        default: return "unknown"
        }
    }
}

/// Which kind of clipboard access libghostty is asking the host to confirm
/// (`ghostty_clipboard_request_e`).
public enum GhosttyClipboardRequest: Sendable {
    /// A user-initiated paste whose contents tripped `clipboard-paste-protection`.
    case paste
    /// A program in the terminal wants to *read* the clipboard (OSC 52).
    case osc52Read
    /// A program in the terminal wants to *write* the clipboard (OSC 52).
    case osc52Write

    init?(_ c: ghostty_clipboard_request_e) {
        switch c {
        case GHOSTTY_CLIPBOARD_REQUEST_PASTE: self = .paste
        case GHOSTTY_CLIPBOARD_REQUEST_OSC_52_READ: self = .osc52Read
        case GHOSTTY_CLIPBOARD_REQUEST_OSC_52_WRITE: self = .osc52Write
        default: return nil
        }
    }
}
