import AppKit
import XCTest
import GhosttyKit
@testable import GhosttyBridge

@MainActor
final class GhosttyBridgeTests: XCTestCase {
    /// libghostty allows one runtime per process; share it across tests.
    private static var sharedRuntime: GhosttyRuntime?

    private func runtime() throws -> GhosttyRuntime {
        if let rt = Self.sharedRuntime { return rt }
        _ = NSApplication.shared
        let rt = try GhosttyRuntime(config: GhosttyConfig(loadUserDefaults: false))
        Self.sharedRuntime = rt
        return rt
    }

    private func spin(_ rt: GhosttyRuntime, seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            rt.tick()
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }

    func testConfigWithoutUserDefaults() throws {
        let config = try GhosttyConfig(loadUserDefaults: false)
        XCTAssertEqual(config.diagnostics, [])

        // Clinic override applied.
        XCTAssertEqual(config.bool(forKey: "confirm-close-surface"), false)

        // Typed getters.
        XCTAssertEqual(config.fontSize, 13, accuracy: 0.001)
        XCTAssertNotNil(config.string(forKey: "window-theme"))
        XCTAssertNil(config.string(forKey: "definitely-not-a-key"))

        // Default keybinds were resolved and unbound (multi-trigger actions too).
        let unbound = Dictionary(config.unboundTriggers.map { ($0.action, [$0.trigger]) }, uniquingKeysWith: +)
        XCTAssertEqual(unbound["new_window"], ["super+n"])
        XCTAssertEqual(unbound["quit"], ["super+q"])
        XCTAssertEqual(unbound["new_split:right"], ["super+d"])
        XCTAssertEqual(Set(unbound["toggle_fullscreen"] ?? []), ["super+enter", "ctrl+super+f"])
        for action in GhosttyConfig.clinicUnboundActions {
            XCTAssertNil(config.trigger(forAction: action), "\(action) still bound")
        }

        // Untouched bindings still present.
        XCTAssertNotNil(config.trigger(forAction: "copy_to_clipboard"))
        XCTAssertNotNil(config.trigger(forAction: "paste_from_clipboard"))
    }

    func testConfigWithoutUnbinding() throws {
        let config = try GhosttyConfig(loadUserDefaults: false, overrides: [], unbindActions: [])
        XCTAssertEqual(config.diagnostics, [])
        XCTAssertEqual(config.bool(forKey: "confirm-close-surface"), true)
        XCTAssertEqual(config.trigger(forAction: "new_window"), "super+n")
    }

    /// Clinic's default chords that Ghostty also binds by default (ADR-173): the trigger as
    /// `KeyChord.ghosttyTrigger` spells it, and the key a surface would be handed.
    private static let collisions: [(trigger: String, key: String, mods: NSEvent.ModifierFlags)] = [
        ("alt+shift+super+j", "j", [.command, .option, .shift]),   // Zoom Panel / write_screen_file:open
        ("shift+super+p", "p", [.command, .shift]),                // PR Panel Tab / toggle_command_palette
        ("super+k", "k", [.command]),                              // Jump to Session / clear_screen
        ("super+j", "j", [.command]),                              // Terminal Panel Tab / scroll_to_selection
        ("shift+super+g", "g", [.command, .shift]),                // Diff Panel Tab / navigate_search:previous
        ("shift+super+z", "z", [.command, .shift]),                // Undo Archive / redo
    ]

    /// Asked of a real surface, because that is what `performKeyEquivalent` asks before it takes a key
    /// from the menu — and because `ghostty_config_trigger` does not report `performable` bindings
    /// (⌘K, ⌘J, ⇧⌘G and ⇧⌘Z all are), so the config alone cannot show them.
    func testYieldedTriggersNoLongerReachTheSurface() throws {
        let rt = try runtime()
        let original = rt.config
        defer { rt.reloadConfig(original) }
        let view = try GhosttySurfaceView(runtime: rt, options: GhosttySurfaceOptions(command: "/bin/sh"))
        defer { view.free() }
        spin(rt, seconds: 0.3)

        func isBinding(_ key: String, _ mods: NSEvent.ModifierFlags) -> Bool {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 1,
                                         windowNumber: 0, context: nil, characters: key,
                                         charactersIgnoringModifiers: key, isARepeat: false,
                                         keyCode: Self.keyCodes[key] ?? 0)!
            var keyEvent = event.ghosttyKeyEvent(GHOSTTY_ACTION_PRESS)
            var flags = ghostty_binding_flags_e(0)
            return key.withCString { ptr in
                keyEvent.text = ptr
                return ghostty_surface_key_is_binding(view.surface, keyEvent, &flags)
            }
        }

        for c in Self.collisions { XCTAssertTrue(isBinding(c.key, c.mods), "\(c.trigger) is not a Ghostty default any more") }

        rt.reloadConfig(try GhosttyConfig(loadUserDefaults: false, yieldTriggers: Self.collisions.map(\.trigger)))
        spin(rt, seconds: 0.3)
        for c in Self.collisions { XCTAssertFalse(isBinding(c.key, c.mods), "\(c.trigger) still goes to the terminal") }
        // Only the named triggers go: ⌘C still copies.
        XCTAssertTrue(isBinding("c", [.command]))
    }

    private static let keyCodes: [String: UInt16] = ["j": 38, "p": 35, "k": 40, "g": 5, "z": 6, "c": 8]

    func testUserBindingOutranksAYieldedTrigger() throws {
        // Overrides load after the yields, where the user's Ghostty files load; a binding there wins.
        let config = try GhosttyConfig(loadUserDefaults: false,
                                       overrides: [.init(key: "keybind", value: "super+k=clear_screen")],
                                       yieldTriggers: ["super+k"])
        XCTAssertEqual(config.trigger(forAction: "clear_screen"), "super+k")
    }

    func testRuntimeInitializes() throws {
        let rt = try runtime()
        rt.tick()
        XCTAssertFalse(rt.needsConfirmQuit)
        rt.setFocus(true)
        rt.setColorScheme(dark: true)
    }

    /// `sendPaste` must deliver multi-line text to the pty as a bracketed paste (ADR-054).
    func testSendPasteWritesBracketedTextToPty() throws {
        let rt = try runtime()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("ghostty-paste-\(UUID().uuidString).txt")
        // `cat` copies everything it reads to the file; the shell keeps the surface alive past the 250 ms launch window.
        let view = try GhosttySurfaceView(runtime: rt, options: GhosttySurfaceOptions(command: "/bin/sh", initialInput: "stty -echo; cat > '\(out.path)'\n"))
        window.contentView = view
        spin(rt, seconds: 0.8)
        view.sendPaste("first line\nsecond \"quoted\" \\ back")
        view.pressEnter()
        // Canonical mode delivers each line to `cat` on newline / Return, so no EOF is needed.
        spin(rt, seconds: 1.0)
        let data = (try? Data(contentsOf: out)) ?? Data()
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\u{1b}[200~first line\nsecond \"quoted\" \\ back\u{1b}[201~"), "pty received: \(text.debugDescription)")
        view.free()
    }

    func testSurfaceLifecycle() throws {
        let rt = try runtime()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false

        final class Delegate: GhosttySurfaceDelegate {
            var actions: [GhosttyAction] = []
            var closeRequests: [Bool] = []
            var exitCodes: [Int32?] = []
            func surface(_ surface: GhosttySurfaceView, didReceive action: GhosttyAction) -> Bool {
                actions.append(action)
                return false
            }
            func surfaceRequestedClose(_ surface: GhosttySurfaceView, processAlive: Bool) {
                closeRequests.append(processAlive)
            }
            func surfaceChildExited(_ surface: GhosttySurfaceView, exitCode: Int32?) {
                exitCodes.append(exitCode)
            }
        }
        let delegate = Delegate()

        // The shell must outlive `abnormal-command-exit-runtime` (250 ms) or libghostty
        // treats the exit as a failed launch.
        let view = try GhosttySurfaceView(
            runtime: rt,
            options: GhosttySurfaceOptions(
                command: "/bin/sh",
                environment: ["CLINIC_TEST": "1"],
                initialInput: "sleep 1; exit\n"))
        view.delegate = delegate
        window.contentView = view
        window.makeFirstResponder(view)

        // Let the renderer come up and the shell start.
        spin(rt, seconds: 0.6)

        XCTAssertNotNil(view.surfaceSize)
        view.sendText("")
        view.isOccluded = true
        view.isOccluded = false
        _ = view.hasSelection
        XCTAssertFalse(view.processExited)

        // Process probing while the shell is alive.
        XCTAssertNotNil(view.childPID, "expected to locate the spawned process")
        let tty = view.ttyName
        XCTAssertTrue(tty?.hasPrefix("/dev/tty") ?? false, "unexpected tty \(tty ?? "nil")")
        XCTAssertNotNil(view.foregroundPID)

        // Wait for the shell to exit. libghostty reports the exit; because an explicit
        // `command` forces wait-after-command, it does not request a close by itself.
        spin(rt, seconds: 2.0)
        XCTAssertEqual(delegate.exitCodes, [0], "expected surfaceChildExited")
        XCTAssertTrue(view.processExited)
        XCTAssertEqual(delegate.closeRequests, [])

        // The host closes it: the close callback reports the process as dead.
        view.requestClose()
        XCTAssertEqual(delegate.closeRequests, [false])

        view.free()
        view.free()   // idempotent
        window.contentView = nil
        spin(rt, seconds: 0.2)
    }
}
