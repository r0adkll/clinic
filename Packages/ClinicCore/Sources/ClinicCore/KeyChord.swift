import Foundation

/// A keyboard chord in Clinic's preferences grammar (ADR-073): `cmd+shift+n`, `ctrl+opt+return`, `f6`.
/// Keys are a single printable character (lower-cased) or a named key from ``KeyChord/namedKeys``.
public struct KeyChord: Hashable, Sendable, Codable {
    public struct Modifiers: OptionSet, Hashable, Sendable, Codable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let command = Modifiers(rawValue: 1 << 0)
        public static let shift = Modifiers(rawValue: 1 << 1)
        public static let option = Modifiers(rawValue: 1 << 2)
        public static let control = Modifiers(rawValue: 1 << 3)
    }

    public var key: String
    public var modifiers: Modifiers

    public init(key: String, modifiers: Modifiers) {
        self.key = key.lowercased()
        self.modifiers = modifiers
    }

    public static let namedKeys: [String] = [
        "return", "escape", "tab", "space", "delete", "up", "down", "left", "right", "home", "end", "pageup", "pagedown",
        "f1", "f2", "f3", "f4", "f5", "f6", "f7", "f8", "f9", "f10", "f11", "f12",
    ]

    /// Parses `cmd+shift+n`; accepts `command/⌘`, `shift/⇧`, `opt/option/alt/⌥`, `ctrl/control/⌃`, any order, any case.
    public init?(parsing text: String) {
        var mods: Modifiers = []
        var key: String?
        var body = text.trimmingCharacters(in: .whitespaces)
        if body.hasSuffix("++") { key = "+"; body = String(body.dropLast(2)) }   // `cmd++` binds the plus key
        else if body == "+" { key = "+"; body = "" }
        let parts = body.isEmpty ? [] : body.split(separator: "+", omittingEmptySubsequences: false)
        for raw in parts {
            let part = raw.trimmingCharacters(in: .whitespaces).lowercased()
            switch part {
            case "cmd", "command", "⌘": mods.insert(.command)
            case "shift", "⇧": mods.insert(.shift)
            case "opt", "option", "alt", "⌥": mods.insert(.option)
            case "ctrl", "control", "⌃": mods.insert(.control)
            default:
                guard key == nil, part.count == 1 || Self.namedKeys.contains(part) else { return nil }
                key = part
            }
        }
        guard let key else { return nil }
        self.init(key: key, modifiers: mods)
    }

    /// Canonical storage form, e.g. `cmd+shift+n`.
    public var stringValue: String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("ctrl") }
        if modifiers.contains(.option) { parts.append("opt") }
        if modifiers.contains(.shift) { parts.append("shift") }
        if modifiers.contains(.command) { parts.append("cmd") }
        parts.append(key)
        return parts.joined(separator: "+")
    }

    /// Menu-style display, e.g. `⌃⌥⇧⌘N`, `⌘↩`.
    public var display: String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        return s + Self.keyDisplay(key)
    }

    public static func keyDisplay(_ key: String) -> String {
        switch key {
        case "return": return "↩"
        case "escape": return "⎋"
        case "tab": return "⇥"
        case "space": return "␣"
        case "delete": return "⌫"
        case "up": return "↑"
        case "down": return "↓"
        case "left": return "←"
        case "right": return "→"
        case "home": return "↖"
        case "end": return "↘"
        case "pageup": return "⇞"
        case "pagedown": return "⇟"
        default: return key.uppercased()
        }
    }

    /// A chord Clinic refuses to assign because macOS or the app menu already owns it.
    public var isReserved: Bool {
        modifiers == [.command] && (key == "q" || key == ",") || modifiers == [.command, .option] && key == "q"
    }

    /// Chords with no modifier are only accepted for function keys.
    public var isUsable: Bool { !modifiers.isEmpty || key.hasPrefix("f") && key.count >= 2 }
}

/// Override table: action id → chord string ("" = unbound). Pure so it can be tested without AppKit.
public struct ShortcutOverrides: Equatable, Sendable {
    public var raw: [String: String]
    public init(raw: [String: String] = [:]) { self.raw = raw }

    /// Resolves an action's chord: an override wins, an empty override means unbound, otherwise the default.
    public func chord(for action: String, default defaultChord: KeyChord?) -> KeyChord? {
        guard let v = raw[action] else { return defaultChord }
        return v.isEmpty ? nil : KeyChord(parsing: v)
    }

    public mutating func set(_ chord: KeyChord?, for action: String, default defaultChord: KeyChord?) {
        if chord == defaultChord { raw[action] = nil } else { raw[action] = chord?.stringValue ?? "" }
    }

    /// The action (other than `except`) that currently owns `chord`, if any.
    public func owner(of chord: KeyChord, defaults: [(action: String, chord: KeyChord?)], except: String) -> String? {
        defaults.first { $0.action != except && self.chord(for: $0.action, default: $0.chord) == chord }?.action
    }
}
