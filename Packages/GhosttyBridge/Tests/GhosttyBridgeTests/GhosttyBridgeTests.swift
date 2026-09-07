import AppKit
import XCTest
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

    func testRuntimeInitializes() throws {
        let rt = try runtime()
        rt.tick()
        XCTAssertFalse(rt.needsConfirmQuit)
        rt.setFocus(true)
        rt.setColorScheme(dark: true)
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
