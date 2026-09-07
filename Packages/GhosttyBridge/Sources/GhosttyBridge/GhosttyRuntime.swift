import AppKit
import Foundation
import GhosttyKit

/// The single libghostty application (`ghostty_app_t`) for the process.
///
/// libghostty's global state (`ghostty_init`) is process-wide, so create exactly one
/// runtime. All calls happen on the main actor. The runtime callbacks registered with
/// libghostty are invoked on the main thread by the embedded apprt, except `wakeup`,
/// which may be called from any thread and is re-dispatched to the main queue.
@MainActor
public final class GhosttyRuntime {
    // MARK: - Global init

    private static let initStatus: Int32 = ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv)

    /// Runs `ghostty_init(argc, argv)` lazily and exactly once; throws if it failed.
    static func ensureInitialized() throws {
        if initStatus != GHOSTTY_SUCCESS { throw GhosttyError.initFailed(initStatus) }
    }

    // MARK: - State

    /// The `ghostty_app_t`. Non-nil for the runtime's lifetime (set right after creation).
    /// (`nonisolated(unsafe)` only so the nonisolated deinit may read it.)
    nonisolated(unsafe) private(set) var app: ghostty_app_t?

    /// The configuration the app was created with / last reloaded to.
    public private(set) var config: GhosttyConfig

    /// Receives actions targeted at the app (no surface) and actions a surface's
    /// delegate declined. Return true if handled.
    public var appActionHandler: ((GhosttyAction) -> Bool)?

    /// Decides clipboard confirmations libghostty asks for. Return true to allow.
    /// Default policy (when nil): allow user pastes and OSC 52 writes, deny OSC 52 reads.
    public var clipboardConfirmationHandler: ((GhosttySurfaceView, String, GhosttyClipboardRequest) -> Bool)?

    /// Child PIDs claimed by live surfaces (see ``GhosttySurfaceView/childPID``).
    private var claimedChildPIDs: [pid_t: UUID] = [:]

    func isChildPIDClaimed(_ pid: pid_t) -> Bool { claimedChildPIDs[pid] != nil }
    func claimChildPID(_ pid: pid_t, for surface: UUID) { claimedChildPIDs[pid] = surface }
    func releaseChildPID(_ pid: pid_t) { claimedChildPIDs[pid] = nil }

    // MARK: - Lifecycle

    public init(config: GhosttyConfig) throws {
        try Self.ensureInitialized()
        self.config = config

        var runtimeConfig = Self.makeRuntimeConfig(userdata: Unmanaged.passUnretained(self).toOpaque())
        guard let app = ghostty_app_new(&runtimeConfig, config.handle) else {
            throw GhosttyError.appCreateFailed
        }
        self.app = app

        ghostty_app_set_focus(app, NSApp?.isActive ?? false)

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(keyboardSelectionDidChange(_:)),
                           name: NSTextInputContext.keyboardSelectionDidChangeNotification, object: nil)
        center.addObserver(self, selector: #selector(applicationDidBecomeActive(_:)),
                           name: NSApplication.didBecomeActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(applicationDidResignActive(_:)),
                           name: NSApplication.didResignActiveNotification, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        // libghostty must be driven from the main thread. The runtime normally lives for
        // the whole process; if it is torn down, only free on main.
        if let app {
            if Thread.isMainThread {
                ghostty_app_free(app)
            } else {
                ghosttyLog.fault("GhosttyRuntime deallocated off the main thread; leaking ghostty_app_t")
            }
        }
    }

    // MARK: - Public API

    /// Drives libghostty's event loop once (`ghostty_app_tick`).
    public func tick() {
        guard let app else { return }
        ghostty_app_tick(app)
    }

    /// App-level focus (`ghostty_app_set_focus`). Tracked automatically from
    /// `NSApplication` activation notifications; call directly to override.
    public func setFocus(_ focused: Bool) {
        guard let app else { return }
        ghostty_app_set_focus(app, focused)
    }

    /// Tell libghostty whether the app is in dark or light appearance
    /// (`ghostty_app_set_color_scheme`).
    public func setColorScheme(dark: Bool) {
        guard let app else { return }
        ghostty_app_set_color_scheme(app, dark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT)
    }

    /// Offer a key event to app-level (global/no-surface) keybinds, the way Ghostty's
    /// AppDelegate does when no terminal window is focused. Returns true if libghostty
    /// consumed it. Only events that are bindings are sent, so unbound keys are never
    /// encoded anywhere.
    public func handleAppKeyEvent(_ event: NSEvent) -> Bool {
        guard let app, event.type == .keyDown else { return false }
        var keyEvent = event.ghosttyKeyEvent(GHOSTTY_ACTION_PRESS)
        return (event.characters ?? "").withCString { ptr in
            keyEvent.text = ptr
            guard ghostty_app_key_is_binding(app, keyEvent) else { return false }
            return ghostty_app_key(app, keyEvent)
        }
    }

    /// Replace the app configuration (`ghostty_app_update_config`). libghostty copies
    /// what it needs; existing surfaces receive a `config_change` action.
    public func reloadConfig(_ config: GhosttyConfig) {
        guard let app else { return }
        ghostty_app_update_config(app, config.handle)
        self.config = config
    }

    /// True if any surface would need confirmation before quitting.
    public var needsConfirmQuit: Bool {
        guard let app else { return false }
        return ghostty_app_needs_confirm_quit(app)
    }

    // MARK: - Notifications

    @objc private func keyboardSelectionDidChange(_ note: Notification) {
        guard let app else { return }
        ghostty_app_keyboard_changed(app)
    }

    @objc private func applicationDidBecomeActive(_ note: Notification) {
        setFocus(true)
    }

    @objc private func applicationDidResignActive(_ note: Notification) {
        setFocus(false)
    }

    // MARK: - Callback plumbing

    /// Builds the C callback table. Deliberately `nonisolated`: the closures become
    /// `@convention(c)` function pointers that libghostty invokes directly, and forming
    /// them inside main-actor code would make Swift insert a main-queue assertion at
    /// entry, which `wakeup` (called from libghostty's renderer/IO threads) would trip.
    nonisolated private static func makeRuntimeConfig(userdata: UnsafeMutableRawPointer) -> ghostty_runtime_config_s {
        ghostty_runtime_config_s(
            userdata: userdata,
            supports_selection_clipboard: false,
            wakeup_cb: { userdata in GhosttyRuntime.wakeup(userdata) },
            action_cb: { app, target, action in GhosttyRuntime.action(app, target: target, action: action) },
            read_clipboard_cb: { userdata, loc, state in GhosttyRuntime.readClipboard(userdata, location: loc, state: state) },
            confirm_read_clipboard_cb: { userdata, str, state, request in
                GhosttyRuntime.confirmReadClipboard(userdata, string: str, state: state, request: request)
            },
            write_clipboard_cb: { userdata, loc, content, len, confirm in
                GhosttyRuntime.writeClipboard(userdata, location: loc, content: content, len: len, confirm: confirm)
            },
            close_surface_cb: { userdata, processAlive in GhosttyRuntime.closeSurface(userdata, processAlive: processAlive) }
        )
    }

    /// Executes `body` on the main actor if we are on the main thread (the normal case
    /// for every libghostty callback except wakeup). Otherwise logs and returns `fallback`.
    nonisolated private static func onMain<T: Sendable>(_ fallback: T, _ body: @MainActor () -> T) -> T {
        if Thread.isMainThread {
            return MainActor.assumeIsolated(body)
        }
        ghosttyLog.error("libghostty callback invoked off the main thread; ignored")
        return fallback
    }

    nonisolated private static func runtime(from app: ghostty_app_t?) -> GhosttyRuntime? {
        guard let app, let ud = ghostty_app_userdata(app) else { return nil }
        return Unmanaged<GhosttyRuntime>.fromOpaque(ud).takeUnretainedValue()
    }

    nonisolated private static func surfaceView(fromUserdata userdata: UnsafeMutableRawPointer?) -> GhosttySurfaceView? {
        guard let userdata else { return nil }
        return Unmanaged<GhosttySurfaceView>.fromOpaque(userdata).takeUnretainedValue()
    }

    // MARK: - libghostty callbacks

    nonisolated private static func wakeup(_ userdata: UnsafeMutableRawPointer?) {
        guard let userdata else { return }
        // Wakeup can be called from any thread; schedule a tick on the main queue.
        let unmanaged = Unmanaged<GhosttyRuntime>.fromOpaque(userdata)
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                unmanaged.takeUnretainedValue().tick()
            }
        }
    }

    nonisolated private static func action(_ app: ghostty_app_t?, target: ghostty_target_s, action: ghostty_action_s) -> Bool {
        // Raw C pointers only live for this call; rebind so the main-actor closure may use them.
        nonisolated(unsafe) let app = app
        return onMain(false) {
            guard let runtime = runtime(from: app) else { return false }
            switch target.tag {
            case GHOSTTY_TARGET_APP:
                return runtime.handleAppAction(action)
            case GHOSTTY_TARGET_SURFACE:
                guard let surface = target.target.surface,
                      let view = GhosttySurfaceView.view(from: surface) else { return false }
                return view.handleAction(action)
            default:
                ghosttyLog.warning("unknown action target \(target.tag.rawValue)")
                return false
            }
        }
    }

    nonisolated private static func closeSurface(_ userdata: UnsafeMutableRawPointer?, processAlive: Bool) {
        // Raw C pointers only live for this call; rebind so the main-actor closure may use them.
        nonisolated(unsafe) let userdata = userdata
        onMain(()) {
            guard let view = surfaceView(fromUserdata: userdata) else { return }
            view.handleCloseRequest(processAlive: processAlive)
        }
    }

    nonisolated private static func readClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        location: ghostty_clipboard_e,
        state: UnsafeMutableRawPointer?
    ) -> Bool {
        // Raw C pointers only live for this call; rebind so the main-actor closure may use them.
        nonisolated(unsafe) let userdata = userdata
        nonisolated(unsafe) let state = state
        return onMain(false) {
            guard let view = surfaceView(fromUserdata: userdata), let surface = view.surface else { return false }
            guard let pasteboard = NSPasteboard.ghostty(location) else { return false }
            // No text-like content: return false so performable paste bindings fall through.
            guard let str = pasteboard.ghosttyStringContents() else { return false }
            str.withCString { ghostty_surface_complete_clipboard_request(surface, $0, state, false) }
            return true
        }
    }

    nonisolated private static func confirmReadClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        string: UnsafePointer<CChar>?,
        state: UnsafeMutableRawPointer?,
        request: ghostty_clipboard_request_e
    ) {
        // Raw C pointers only live for this call; rebind so the main-actor closure may use them.
        nonisolated(unsafe) let userdata = userdata
        nonisolated(unsafe) let string = string
        nonisolated(unsafe) let state = state
        onMain(()) {
            guard let view = surfaceView(fromUserdata: userdata), let surface = view.surface else { return }
            guard let string, let request = GhosttyClipboardRequest(request) else { return }
            let text = String(cString: string)
            let allowed: Bool
            if let handler = view.runtime.clipboardConfirmationHandler {
                allowed = handler(view, text, request)
            } else {
                allowed = request != .osc52Read
            }
            // Denying = completing with empty data (what Ghostty's dialog does on cancel),
            // which also lets libghostty free the request state.
            let data = allowed ? text : ""
            data.withCString { ghostty_surface_complete_clipboard_request(surface, $0, state, true) }
        }
    }

    nonisolated private static func writeClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        location: ghostty_clipboard_e,
        content: UnsafePointer<ghostty_clipboard_content_s>?,
        len: Int,
        confirm: Bool
    ) {
        guard let content, len > 0 else { return }
        // Copy out of the C buffers first; they're only valid for this call.
        let items: [(mime: String, data: String)] = (0..<len).compactMap { i in
            guard let mime = content[i].mime, let data = content[i].data else { return nil }
            return (String(cString: mime), String(cString: data))
        }
        guard !items.isEmpty else { return }
        onMain(()) {
            guard let pasteboard = NSPasteboard.ghostty(location) else { return }
            // `confirm` asks the host to confirm an OSC 52 write (clipboard-write = ask).
            // Clinic trusts its own terminal sessions, so writes are applied directly.
            let types = items.compactMap { NSPasteboard.pasteboardType(forMIME: $0.mime) }
            pasteboard.declareTypes(types, owner: nil)
            for item in items {
                guard let type = NSPasteboard.pasteboardType(forMIME: item.mime) else { continue }
                pasteboard.setString(item.data, forType: type)
            }
            _ = confirm
        }
    }

    // MARK: - App-target actions

    private func handleAppAction(_ c: ghostty_action_s) -> Bool {
        let action: GhosttyAction
        switch c.tag {
        case GHOSTTY_ACTION_QUIT: action = .quit
        case GHOSTTY_ACTION_NEW_WINDOW: action = .newWindow
        case GHOSTTY_ACTION_NEW_TAB: action = .newTab
        case GHOSTTY_ACTION_NEW_SPLIT: action = .newSplit
        case GHOSTTY_ACTION_OPEN_URL:
            guard let url = GhosttyAction.url(from: c.action.open_url) else { return false }
            action = .openURL(url, kind: GhosttyAction.urlKind(c.action.open_url.kind))
        default:
            action = .unhandled(kind: GhosttyAction.kindName(c.tag))
        }
        return dispatchToApp(action)
    }

    /// Sends an action to `appActionHandler`, applying the runtime's default behaviour
    /// for actions nobody handled.
    func dispatchToApp(_ action: GhosttyAction) -> Bool {
        if let handler = appActionHandler, handler(action) { return true }
        if case .openURL(let url, _) = action {
            NSWorkspace.shared.open(url)
            return true
        }
        return false
    }
}
