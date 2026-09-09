import AppKit
import SwiftUI
import ClinicCore

/// Every rebindable command (ADR-073). Defaults are the chords ADR-036 and later ADRs assigned.
enum ShortcutAction: String, CaseIterable, Identifiable {
    case newSession, newSessionInFolder, newChat, newShell, newWindow, closeTab
    case renameSession, toggleFavorite, archiveSession, undoArchive, stopSession, forkSession, backgroundSession, sessionDetails, replaySession, jumpToSession, moveTabToNewWindow
    case mcpServers, selectSessions, notifications, caffeine
    case togglePanel, toggleDiffPage = "toggleGitPage", toggleEditor, toggleAttachments, togglePRPage
    case togglePanelVisibility, zoomPanel, toggleFileTree, nextPanelTab, previousPanelTab, closePanelTab, nextTab, previousTab

    var id: String { rawValue }

    var title: String {
        switch self {
        case .newSession: "New Session"
        case .newSessionInFolder: "New Session in Folder…"
        case .newChat: "New Chat"
        case .newShell: "New Shell"
        case .newWindow: "New Window"
        case .closeTab: "Close Tab"
        case .renameSession: "Rename Session…"
        case .toggleFavorite: "Add to / Remove from Favorites"
        case .archiveSession: "Archive Session"
        case .undoArchive: "Undo Archive"
        case .stopSession: "Stop Session"
        case .forkSession: "Fork Session"
        case .backgroundSession: "Background This Session"
        case .sessionDetails: "Session Details…"
        case .replaySession: "Replay Session…"
        case .jumpToSession: "Jump to Session…"
        case .moveTabToNewWindow: "Move Tab to New Window"
        case .mcpServers: "MCP Servers…"
        case .selectSessions: "Select Sessions"
        case .notifications: "Notifications"
        case .caffeine: "Caffeine Mode"
        case .togglePanel: "Terminal Panel Tab"
        case .toggleDiffPage: "Diff Panel Tab"
        case .toggleEditor: "Files Panel Tab"
        case .toggleAttachments: "Images Panel Tab"
        case .togglePRPage: "Pull Request Panel Tab"
        case .togglePanelVisibility: "Show / Hide Panel"
        case .zoomPanel: "Zoom Panel"
        case .toggleFileTree: "Show / Hide File Tree"
        case .nextPanelTab: "Next Panel Tab"
        case .previousPanelTab: "Previous Panel Tab"
        case .closePanelTab: "Close Panel Tab"
        case .nextTab: "Next Tab"
        case .previousTab: "Previous Tab"
        }
    }

    var section: String {
        switch self {
        case .newSession, .newSessionInFolder, .newChat, .newShell, .newWindow, .closeTab: "File"
        case .renameSession, .toggleFavorite, .archiveSession, .undoArchive, .stopSession, .forkSession, .backgroundSession, .sessionDetails, .replaySession, .jumpToSession, .moveTabToNewWindow: "Session"
        case .mcpServers, .selectSessions, .notifications, .caffeine: "View"
        case .togglePanel, .toggleDiffPage, .toggleEditor, .toggleAttachments, .togglePRPage,
             .togglePanelVisibility, .zoomPanel, .toggleFileTree,
             .nextPanelTab, .previousPanelTab, .closePanelTab: "Panel"
        case .nextTab, .previousTab: "Tabs"
        }
    }

    static let sections = ["File", "Session", "View", "Panel", "Tabs"]

    var defaultChord: KeyChord? {
        let s: String? = switch self {
        case .newSession: "cmd+n"
        case .newSessionInFolder: "cmd+shift+n"
        case .newChat: "cmd+opt+n"
        case .newShell: "cmd+t"
        case .newWindow: "cmd+ctrl+n"
        case .closeTab: "cmd+w"
        case .renameSession: "cmd+shift+r"
        case .toggleFavorite: "cmd+shift+d"
        case .archiveSession: "cmd+shift+a"
        case .undoArchive: "cmd+shift+z"
        case .stopSession: "cmd+."
        case .forkSession: nil
        case .backgroundSession: "cmd+opt+b"
        case .sessionDetails: "cmd+i"
        case .replaySession: "cmd+opt+r"
        case .jumpToSession: "cmd+k"
        case .moveTabToNewWindow: nil
        case .mcpServers: "cmd+shift+m"
        case .selectSessions: "cmd+shift+s"
        case .notifications: "cmd+shift+b"
        case .caffeine: nil
        case .togglePanel: "cmd+j"
        case .toggleDiffPage: "cmd+shift+g"
        case .toggleEditor: "cmd+shift+e"
        case .toggleAttachments: "cmd+shift+i"
        case .togglePRPage: "cmd+shift+p"
        case .togglePanelVisibility: "cmd+opt+j"
        case .zoomPanel: "cmd+opt+shift+j"
        case .toggleFileTree: "cmd+ctrl+e"
        case .nextPanelTab: "cmd+ctrl+]"
        case .previousPanelTab: "cmd+ctrl+["
        case .closePanelTab: "cmd+ctrl+w"
        case .nextTab: "cmd+shift+]"
        case .previousTab: "cmd+shift+["
        }
        return s.flatMap(KeyChord.init(parsing:))
    }
}

/// Resolved chords for the menu; overrides persisted in UserDefaults `ClinicShortcuts` (ADR-073).
@MainActor
@Observable
final class KeyBindings {
    static let defaultsKey = "ClinicShortcuts"
    private(set) var overrides: ShortcutOverrides

    init() {
        overrides = ShortcutOverrides(raw: UserDefaults.standard.dictionary(forKey: Self.defaultsKey) as? [String: String] ?? [:])
    }

    func chord(for action: ShortcutAction) -> KeyChord? { overrides.chord(for: action.rawValue, default: action.defaultChord) }
    func shortcut(for action: ShortcutAction) -> KeyboardShortcut? { chord(for: action).flatMap(Self.keyboardShortcut) }
    func isOverridden(_ action: ShortcutAction) -> Bool { overrides.raw[action.rawValue] != nil }
    /// Display string for help texts, e.g. "(⇧⌘G)"; empty when unbound.
    func hint(_ action: ShortcutAction) -> String { chord(for: action).map { " (\($0.display))" } ?? "" }

    func owner(of chord: KeyChord, except action: ShortcutAction) -> ShortcutAction? {
        let defaults = ShortcutAction.allCases.map { (action: $0.rawValue, chord: $0.defaultChord) }
        return overrides.owner(of: chord, defaults: defaults, except: action.rawValue).flatMap(ShortcutAction.init(rawValue:))
    }

    /// Assigns a chord (nil = unbound). Returns a message when refused.
    @discardableResult
    func set(_ chord: KeyChord?, for action: ShortcutAction) -> String? {
        if let chord {
            guard chord.isUsable else { return "Add a modifier key." }
            guard !chord.isReserved else { return "\(chord.display) is reserved by macOS." }
            if let owner = owner(of: chord, except: action) { return "\(chord.display) is used by “\(owner.title)”." }
        }
        overrides.set(chord, for: action.rawValue, default: action.defaultChord)
        save()
        return nil
    }

    func reset(_ action: ShortcutAction) { overrides.raw[action.rawValue] = nil; save() }
    func resetAll() { overrides.raw = [:]; save() }

    private func save() { UserDefaults.standard.set(overrides.raw, forKey: Self.defaultsKey) }

    static func keyboardShortcut(_ c: KeyChord) -> KeyboardShortcut? {
        var mods: EventModifiers = []
        if c.modifiers.contains(.command) { mods.insert(.command) }
        if c.modifiers.contains(.shift) { mods.insert(.shift) }
        if c.modifiers.contains(.option) { mods.insert(.option) }
        if c.modifiers.contains(.control) { mods.insert(.control) }
        guard let key = keyEquivalent(c.key) else { return nil }
        return KeyboardShortcut(key, modifiers: mods)
    }

    static func keyEquivalent(_ key: String) -> KeyEquivalent? {
        switch key {
        case "return": return .return
        case "escape": return .escape
        case "tab": return .tab
        case "space": return .space
        case "delete": return .delete
        case "up": return .upArrow
        case "down": return .downArrow
        case "left": return .leftArrow
        case "right": return .rightArrow
        case "home": return .home
        case "end": return .end
        case "pageup": return .pageUp
        case "pagedown": return .pageDown
        default:
            if key.hasPrefix("f"), let n = Int(key.dropFirst()), (1...12).contains(n), let scalar = UnicodeScalar(NSF1FunctionKey + n - 1) {
                return KeyEquivalent(Character(scalar))
            }
            guard key.count == 1, let ch = key.first else { return nil }
            return KeyEquivalent(ch)
        }
    }

    private static let namedByKeyCode: [UInt16: String] = [
        36: "return", 76: "return", 53: "escape", 48: "tab", 49: "space", 51: "delete", 117: "delete",
        126: "up", 125: "down", 123: "left", 124: "right", 115: "home", 119: "end", 116: "pageup", 121: "pagedown",
        122: "f1", 120: "f2", 99: "f3", 118: "f4", 96: "f5", 97: "f6", 98: "f7", 100: "f8", 101: "f9", 109: "f10", 103: "f11", 111: "f12",
    ]

    /// The chord a key event represents, or nil for modifier-only / unmappable keys.
    static func chord(from event: NSEvent) -> KeyChord? {
        var mods: KeyChord.Modifiers = []
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) { mods.insert(.command) }
        if flags.contains(.shift) { mods.insert(.shift) }
        if flags.contains(.option) { mods.insert(.option) }
        if flags.contains(.control) { mods.insert(.control) }
        if let named = namedByKeyCode[event.keyCode] { return KeyChord(key: named, modifiers: mods) }
        guard let base = event.characters(byApplyingModifiers: []) ?? event.charactersIgnoringModifiers, let ch = base.first,
              ch.isLetter || ch.isNumber || ch.isPunctuation || ch.isSymbol else { return nil }
        return KeyChord(key: String(ch), modifiers: mods)
    }
}

/// Click, press a chord. ⌫ clears, ⎋ cancels. Captures key equivalents before the menu sees them.
struct ShortcutRecorder: NSViewRepresentable {
    @Environment(KeyBindings.self) private var bindings
    let action: ShortcutAction
    @Binding var message: String?

    func makeNSView(context: Context) -> RecorderView {
        let v = RecorderView()
        v.onChord = { chord in
            if let chord { message = bindings.set(chord, for: action).map { "\(action.title): \($0)" } }
            else { bindings.set(nil, for: action); message = nil }
        }
        return v
    }

    func updateNSView(_ v: RecorderView, context: Context) {
        v.label = bindings.chord(for: action)?.display ?? "None"
        v.needsDisplay = true
    }

    @MainActor
    final class RecorderView: NSView {
        var onChord: ((KeyChord?) -> Void)?
        var label = "None"
        private var recording = false { didSet { needsDisplay = true } }
        /// Focus only after a click, so opening Preferences never starts recording on its own.
        private var clicked = false

        override var acceptsFirstResponder: Bool { clicked }
        override var intrinsicContentSize: NSSize { NSSize(width: 130, height: 22) }
        override func mouseDown(with event: NSEvent) { clicked = true; window?.makeFirstResponder(self) }
        override func becomeFirstResponder() -> Bool { recording = true; return true }
        override func resignFirstResponder() -> Bool { recording = false; clicked = false; return true }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard recording else { return false }
            handle(event); return true
        }
        override func keyDown(with event: NSEvent) {
            guard recording else { super.keyDown(with: event); return }
            handle(event)
        }

        private func handle(_ event: NSEvent) {
            let plain = event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty
            if event.keyCode == 53 && plain { window?.makeFirstResponder(nil); return }
            if event.keyCode == 51 && plain { onChord?(nil); window?.makeFirstResponder(nil); return }
            guard let chord = KeyBindings.chord(from: event), chord.isUsable else { NSSound.beep(); return }
            onChord?(chord)
            window?.makeFirstResponder(nil)
        }

        override func draw(_ dirtyRect: NSRect) {
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
            (recording ? NSColor.controlAccentColor.withAlphaComponent(0.15) : NSColor.controlBackgroundColor).setFill(); path.fill()
            (recording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke(); path.stroke()
            let text = recording ? "Type shortcut…" : label
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: recording ? NSColor.controlAccentColor : (label == "None" ? NSColor.secondaryLabelColor : NSColor.labelColor)]
            let size = text.size(withAttributes: attrs)
            text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attrs)
        }
    }
}

/// Preferences → Shortcuts (ADR-073).
struct ShortcutsPreferences: View {
    @Environment(KeyBindings.self) private var bindings
    @State private var message: String?

    var body: some View {
        Form {
            ForEach(ShortcutAction.sections, id: \.self) { section in
                Section(section) {
                    ForEach(ShortcutAction.allCases.filter { $0.section == section }) { action in
                        LabeledContent(action.title) {
                            HStack(spacing: 6) {
                                ShortcutRecorder(action: action, message: $message).fixedSize()
                                Button { bindings.reset(action); message = nil } label: { Image(systemName: "arrow.uturn.backward") }
                                    .buttonStyle(.borderless).help("Reset to default").opacity(bindings.isOverridden(action) ? 1 : 0)
                            }
                        }
                    }
                }
            }
            Section {
                HStack {
                    Text(message ?? "Click a shortcut, then type the new one. ⌫ clears it, ⎋ cancels. Chords bound in your Ghostty config still win inside the terminal.")
                        .font(.caption).foregroundStyle(message == nil ? Color.secondary : Color.red)
                    Spacer()
                    Button("Reset All") { bindings.resetAll(); message = nil }
                }
            }
        }
        .formStyle(.grouped)
    }
}
