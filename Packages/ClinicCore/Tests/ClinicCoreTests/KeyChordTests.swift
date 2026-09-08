import Foundation
import Testing
@testable import ClinicCore

@Suite struct KeyChordTests {
    @Test func parsesAndFormats() {
        let c = KeyChord(parsing: "Cmd+Shift+N")
        #expect(c == KeyChord(key: "n", modifiers: [.command, .shift]))
        #expect(c?.stringValue == "shift+cmd+n")
        #expect(c?.display == "⇧⌘N")
        #expect(KeyChord(parsing: "⌃+⌥+return")?.display == "⌃⌥↩")
        #expect(KeyChord(parsing: "cmd++")?.display == "⌘+")
        #expect(KeyChord(parsing: "ctrl+opt+return")?.stringValue == "ctrl+opt+return")
        #expect(KeyChord(parsing: "f6")?.display == "F6")
        #expect(KeyChord(parsing: "cmd+shift+]")?.display == "⇧⌘]")
        #expect(KeyChord(parsing: "shift+cmd+n") == KeyChord(parsing: "cmd+shift+n"))
    }

    @Test func rejectsGarbage() {
        #expect(KeyChord(parsing: "") == nil)
        #expect(KeyChord(parsing: "cmd+") == nil)
        #expect(KeyChord(parsing: "cmd+ab") == nil)
        #expect(KeyChord(parsing: "cmd+n+m") == nil)
        #expect(KeyChord(parsing: "hyper+n") == nil)
    }

    @Test func reservedAndUsable() {
        #expect(KeyChord(parsing: "cmd+q")!.isReserved)
        #expect(KeyChord(parsing: "cmd+,")!.isReserved)
        #expect(!KeyChord(parsing: "cmd+shift+q")!.isReserved)
        #expect(!KeyChord(parsing: "n")!.isUsable)
        #expect(KeyChord(parsing: "f6")!.isUsable)
        #expect(KeyChord(parsing: "cmd+n")!.isUsable)
    }

    @Test func overridesResolveAndConflict() {
        let defaults: [(action: String, chord: KeyChord?)] = [
            ("newSession", KeyChord(parsing: "cmd+n")), ("newShell", KeyChord(parsing: "cmd+t")), ("fork", nil),
        ]
        var o = ShortcutOverrides()
        #expect(o.chord(for: "newSession", default: defaults[0].chord) == KeyChord(parsing: "cmd+n"))
        o.set(KeyChord(parsing: "cmd+shift+t"), for: "newShell", default: defaults[1].chord)
        #expect(o.raw["newShell"] == "shift+cmd+t")
        o.set(nil, for: "newSession", default: defaults[0].chord)
        #expect(o.raw["newSession"] == "")
        #expect(o.chord(for: "newSession", default: defaults[0].chord) == nil)
        o.set(KeyChord(parsing: "cmd+n"), for: "newSession", default: defaults[0].chord)
        #expect(o.raw["newSession"] == nil, "setting the default clears the override")
        #expect(o.owner(of: KeyChord(parsing: "cmd+shift+t")!, defaults: defaults, except: "fork") == "newShell")
        #expect(o.owner(of: KeyChord(parsing: "cmd+shift+t")!, defaults: defaults, except: "newShell") == nil)
        #expect(o.owner(of: KeyChord(parsing: "cmd+n")!, defaults: defaults, except: "fork") == "newSession")
    }
}
