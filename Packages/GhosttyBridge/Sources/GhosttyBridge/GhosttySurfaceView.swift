import AppKit
import Foundation
import GhosttyKit

/// Receives surface events. All methods are called on the main actor.
@MainActor
public protocol GhosttySurfaceDelegate: AnyObject {
    /// An action targeted at this surface. Return true if handled. Unhandled actions
    /// fall through to ``GhosttyRuntime/appActionHandler``.
    func surface(_ surface: GhosttySurfaceView, didReceive action: GhosttyAction) -> Bool
    /// libghostty asked to close the surface (`close_surface_cb`). `processAlive` is
    /// true when the child is still running (the host may want to confirm).
    func surfaceRequestedClose(_ surface: GhosttySurfaceView, processAlive: Bool)
    /// The child process exited (`show_child_exited`). Sent for normal and abnormal
    /// exits regardless of `wait-after-command`; `exitCode` is nil if unknown.
    ///
    /// The bridge reports this action as handled, which suppresses libghostty's own
    /// "process exited" text in the terminal. What follows depends on the core:
    /// - normal exit and `wait-after-command = false`: `surfaceRequestedClose` follows
    ///   immediately with `processAlive == false`;
    /// - `wait-after-command = true` (always the case when ``GhosttySurfaceOptions/command``
    ///   is set, see its docs): nothing else happens until the host closes the surface
    ///   or the user presses a key (which makes the core request a close);
    /// - exit within `abnormal-command-exit-runtime` (250 ms default; on macOS the exit
    ///   code is *not* consulted): libghostty treats it as a failed launch and does not
    ///   request a close, so the host should surface the failure and close/free itself.
    func surfaceChildExited(_ surface: GhosttySurfaceView, exitCode: Int32?)
}

/// Options for creating a surface (`ghostty_surface_config_s`).
public struct GhosttySurfaceOptions: Sendable {
    /// Initial working directory. nil = libghostty default (config `working-directory`).
    public var workingDirectory: String?
    /// Command to run. nil = the user's shell (libghostty default).
    ///
    /// Note (libghostty 1.3.1, `apprt/embedded.zig`): giving an explicit command forces
    /// `wait-after-command = true` for the surface, so when the command exits the core
    /// reports `surfaceChildExited` but does **not** request a close; the host closes
    /// the surface itself (``GhosttySurfaceView/requestClose()`` or ``GhosttySurfaceView/free()``).
    public var command: String?
    /// Extra environment variables for the child.
    public var environment: [String: String]
    /// Text written to the pty once the process starts, as if typed (ADR-016).
    public var initialInput: String?
    /// Keep the surface open after the command exits (`wait-after-command`).
    public var waitAfterCommand: Bool
    /// Explicit font size in points; nil inherits the config's `font-size`.
    public var fontSize: Float?

    public init(
        workingDirectory: String? = nil,
        command: String? = nil,
        environment: [String: String] = [:],
        initialInput: String? = nil,
        waitAfterCommand: Bool = false,
        fontSize: Float? = nil
    ) {
        self.workingDirectory = workingDirectory
        self.command = command
        self.environment = environment
        self.initialInput = initialInput
        self.waitAfterCommand = waitAfterCommand
        self.fontSize = fontSize
    }

    /// Builds the C config with all string pointers valid only inside `body`.
    /// (Technique from Ghostty's `SurfaceConfiguration.withCValue`.)
    @MainActor
    func withCValue<T>(view: GhosttySurfaceView, _ body: (inout ghostty_surface_config_s) throws -> T) rethrows -> T {
        var config = ghostty_surface_config_new()
        config.userdata = Unmanaged.passUnretained(view).toOpaque()
        config.platform_tag = GHOSTTY_PLATFORM_MACOS
        config.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(
            nsview: Unmanaged.passUnretained(view).toOpaque()))
        config.scale_factor = Double((view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor) ?? 2.0)
        config.font_size = fontSize ?? 0   // 0 = inherit
        config.wait_after_command = waitAfterCommand
        config.context = GHOSTTY_SURFACE_CONTEXT_WINDOW

        var env = environment
        env[GhosttySurfaceView.surfaceEnvironmentKey] = view.surfaceID.uuidString
        let keys = Array(env.keys)
        let values = keys.map { env[$0]! }

        return try withOptionalCString(workingDirectory) { cwd in
            config.working_directory = cwd
            return try withOptionalCString(command) { cmd in
                config.command = cmd
                return try withOptionalCString(initialInput) { input in
                    config.initial_input = input
                    return try withCStrings(keys) { cKeys in
                        try withCStrings(values) { cValues in
                            var envVars = (0..<keys.count).map { ghostty_env_var_s(key: cKeys[$0], value: cValues[$0]) }
                            return try envVars.withUnsafeMutableBufferPointer { buf in
                                config.env_vars = buf.baseAddress
                                config.env_var_count = buf.count
                                return try body(&config)
                            }
                        }
                    }
                }
            }
        }
    }

    private func withOptionalCString<T>(_ s: String?, _ body: (UnsafePointer<CChar>?) throws -> T) rethrows -> T {
        guard let s else { return try body(nil) }
        return try s.withCString { try body($0) }
    }
}

/// An AppKit view hosting one libghostty terminal surface.
///
/// The view is *layer-hosting*: libghostty's Metal renderer assigns its own
/// `IOSurfaceLayer` to `layer` and sets `wantsLayer` (src/renderer/Metal.zig), so we
/// never touch `wantsLayer`/`makeBackingLayer` ourselves; we only keep
/// `layer.contentsScale` in sync with the window's backing scale.
///
/// Lifetime: call ``free()`` (idempotent, main actor) before the view is released.
/// `deinit` only logs if that was forgotten because libghostty must not be called
/// from an arbitrary thread.
@MainActor
public final class GhosttySurfaceView: NSView, @preconcurrency NSTextInputClient {
    /// Environment variable injected into every surface's child, valued with
    /// ``surfaceID``. Processes running inside the terminal (e.g. hook helpers) can read
    /// it to identify their surface. (It cannot be used from *outside* the process to
    /// find the child: see ``GhosttyProcessProbe``.)
    public static let surfaceEnvironmentKey = "GHOSTTY_BRIDGE_SURFACE_ID"

    /// When the surface was created; used to match the spawned child process.
    private let createdAt = Date()

    public let surfaceID = UUID()
    public weak var delegate: GhosttySurfaceDelegate?
    let runtime: GhosttyRuntime

    /// The underlying `ghostty_surface_t`; nil after ``free()``.
    private(set) var surface: ghostty_surface_t?

    /// Title reported by the terminal (OSC 0/2). Empty until set.
    public private(set) var title: String = ""
    /// Working directory reported by the terminal (OSC 7).
    public private(set) var pwd: String?
    /// Cell size in points (from the `cell_size` action).
    public private(set) var cellSize: NSSize = .zero
    /// Background color if the terminal changed it dynamically.
    public private(set) var backgroundColor: NSColor?
    /// True while this view is the focused terminal (first responder in the key window).
    public private(set) var focused: Bool = false

    /// Occlusion (ADR-019): set true when the surface is not visible (hidden tab,
    /// minimized window) so libghostty stops rendering. Not tracked automatically from
    /// window occlusion so the host stays in control.
    public var isOccluded: Bool = false {
        didSet {
            guard isOccluded != oldValue, let surface else { return }
            ghostty_surface_set_occlusion(surface, !isOccluded)
        }
    }

    // Input state
    private var markedText = NSMutableAttributedString()
    private var keyTextAccumulator: [String]?
    private var lastPerformKeyEvent: TimeInterval?
    private var suppressNextLeftMouseUp = false
    private var prevPressureStage = 0
    private var eventMonitor: Any?
    private var cursor: NSCursor = .iBeam
    private var didFree = false

    // Process probing cache
    private var cachedChildPID: pid_t?

    // MARK: - Lifecycle

    public init(runtime: GhosttyRuntime, options: GhosttySurfaceOptions) throws {
        self.runtime = runtime
        // Non-zero initial frame so the renderer's layer bounds are non-zero.
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))

        guard let app = runtime.app else { throw GhosttyError.appCreateFailed }
        let created = options.withCValue(view: self) { cfg in ghostty_surface_new(app, &cfg) }
        guard let created else { throw GhosttyError.surfaceCreateFailed }
        self.surface = created

        updateTrackingAreas()
        registerForDraggedTypes([.string, .fileURL, .URL])

        // Local monitor: command+key never produces keyUp through the responder chain,
        // and leftMouseDown is used to move focus without forwarding the click.
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyUp, .leftMouseDown]) { [weak self] event in
            // Local monitors are always invoked on the main thread.
            nonisolated(unsafe) let event = event
            nonisolated(unsafe) var result: NSEvent? = event
            MainActor.assumeIsolated { result = self?.localEvent(event) }
            return result
        }

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(windowDidBecomeKey(_:)), name: NSWindow.didBecomeKeyNotification, object: nil)
        center.addObserver(self, selector: #selector(windowDidResignKey(_:)), name: NSWindow.didResignKeyNotification, object: nil)
        center.addObserver(self, selector: #selector(windowDidChangeScreen(_:)), name: NSWindow.didChangeScreenNotification, object: nil)

        sizeDidChange(frame.size)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        if !didFree {
            ghosttyLog.fault("GhosttySurfaceView deallocated without free(); ghostty_surface_t leaked. Call free() on the main actor before releasing the view.")
        }
    }

    /// Frees the libghostty surface. Idempotent. Must be called before the view is
    /// released; the view is inert afterwards.
    public func free() {
        guard !didFree else { return }
        didFree = true
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        NotificationCenter.default.removeObserver(self)
        trackingAreas.forEach { removeTrackingArea($0) }
        if let pid = cachedChildPID {
            runtime.releaseChildPID(pid)
            cachedChildPID = nil
        }
        if let surface {
            self.surface = nil
            ghostty_surface_free(surface)
        }
    }

    /// Resolves the view registered as a surface's userdata.
    static func view(from surface: ghostty_surface_t) -> GhosttySurfaceView? {
        guard let ud = ghostty_surface_userdata(surface) else { return nil }
        return Unmanaged<GhosttySurfaceView>.fromOpaque(ud).takeUnretainedValue()
    }

    // MARK: - Public API

    /// Send text as if typed (no key encoding/bindings): `ghostty_surface_text`.
    public func sendText(_ text: String) {
        guard let surface else { return }
        let len = text.utf8.count
        guard len > 0 else { return }
        text.withCString { ghostty_surface_text(surface, $0, UInt(len)) }
    }

    /// Presses and releases Return as a synthesized key event. `ghostty_surface_text` is the IME text path and
    /// does not submit a newline, so callers that want to "type a command" use `sendLine`.
    public func pressEnter() {
        guard let surface else { return }
        var ev = ghostty_input_key_s()
        ev.keycode = 36 // kVK_Return
        ev.unshifted_codepoint = 0x0D
        ev.action = GHOSTTY_ACTION_PRESS
        _ = ghostty_surface_key(surface, ev)
        ev.action = GHOSTTY_ACTION_RELEASE
        _ = ghostty_surface_key(surface, ev)
    }

    /// Delivers `text` to the pty as a bracketed paste (ESC[200~ … ESC[201~) via the `text:` binding action, which
    /// writes raw bytes with Ghostty's string-escape parsing. Multi-line prompts arrive intact in Claude Code's input box.
    public func sendPaste(_ text: String) {
        var escaped = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\\": escaped += "\\\\"
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            case "\t": escaped += "\\t"
            case "\"": escaped += "\\\""
            default: escaped.unicodeScalars.append(scalar)
            }
        }
        _ = perform(action: "text:\\x1b[200~" + escaped + "\\x1b[201~")
    }

    /// Pastes `text` and presses Return.
    public func sendPastedLine(_ text: String) {
        sendPaste(text)
        pressEnter()
    }

    /// Types `line` (any trailing newline stripped) and presses Return.
    public func sendLine(_ line: String) {
        var text = line
        while text.hasSuffix("\n") || text.hasSuffix("\r") { text.removeLast() }
        sendText(text)
        pressEnter()
    }

    /// Perform a keybind action by name (e.g. `"copy_to_clipboard"`, `"scroll_to_bottom"`).
    @discardableResult
    public func perform(action: String) -> Bool {
        guard let surface else { return false }
        return action.withCString { ghostty_surface_binding_action(surface, $0, UInt(action.utf8.count)) }
    }

    /// Ask libghostty to close the surface; results in `surfaceRequestedClose`.
    public func requestClose() {
        guard let surface else { return }
        ghostty_surface_request_close(surface)
    }

    public var hasSelection: Bool {
        guard let surface else { return false }
        return ghostty_surface_has_selection(surface)
    }

    /// The selected text, if any.
    public var selectedText: String? {
        guard let surface else { return nil }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        return String(cString: text.text)
    }

    /// True if the child process has exited.
    public var processExited: Bool {
        guard let surface else { return true }
        return ghostty_surface_process_exited(surface)
    }

    /// True if closing this surface should be confirmed (running child, per config).
    public var needsConfirmQuit: Bool {
        guard let surface else { return false }
        return ghostty_surface_needs_confirm_quit(surface)
    }

    /// Terminal size in cells/pixels as libghostty sees it.
    public var surfaceSize: (columns: Int, rows: Int, cellWidth: Int, cellHeight: Int)? {
        guard let surface else { return nil }
        let s = ghostty_surface_size(surface)
        return (Int(s.columns), Int(s.rows), Int(s.cell_width_px), Int(s.cell_height_px))
    }

    /// PID of the process libghostty spawned for this surface (on macOS this is the
    /// `login` wrapper whose child is the shell/command).
    ///
    /// libghostty does not expose it, so it is inferred: the oldest direct child of this
    /// process that started after the surface was created and is not claimed by another
    /// live surface (see ``GhosttyProcessProbe``). Surfaces created back-to-back before
    /// either child is claimed could in theory be matched in the wrong order; the claim
    /// is cached once made and released on ``free()``.
    public var childPID: pid_t? {
        if let pid = cachedChildPID {
            if GhosttyProcessProbe.isAlive(pid) { return pid }
            runtime.releaseChildPID(pid)
            cachedChildPID = nil
        }
        let slack: TimeInterval = 0.05
        let candidate = GhosttyProcessProbe.children(of: getpid()).first {
            $0.startTime >= createdAt.addingTimeInterval(-slack) && !runtime.isChildPIDClaimed($0.pid)
        }
        guard let candidate else { return nil }
        runtime.claimChildPID(candidate.pid, for: surfaceID)
        cachedChildPID = candidate.pid
        return candidate.pid
    }

    /// Path of the surface's pty (e.g. `/dev/ttys003`).
    public var ttyName: String? {
        guard let pid = childPID else { return nil }
        return GhosttyProcessProbe.ttyPath(of: pid)
    }

    /// Process group id (== pid of the group leader) of the foreground job on the
    /// surface's pty, e.g. the running `claude` process, or the shell when idle.
    public var foregroundPID: pid_t? {
        guard let pid = childPID else { return nil }
        return GhosttyProcessProbe.foregroundProcessGroup(of: pid)
    }

    // MARK: - Action dispatch (from GhosttyRuntime)

    func handleAction(_ c: ghostty_action_s) -> Bool {
        var action: GhosttyAction
        var handledInternally = false

        switch c.tag {
        case GHOSTTY_ACTION_SET_TITLE:
            guard let ptr = c.action.set_title.title else { return false }
            let t = String(cString: ptr)
            title = t
            action = .setTitle(t)
            handledInternally = true

        case GHOSTTY_ACTION_PWD:
            guard let ptr = c.action.pwd.pwd else { return false }
            let p = String(cString: ptr)
            pwd = p
            action = .pwd(p)
            handledInternally = true

        case GHOSTTY_ACTION_RING_BELL:
            action = .ringBell

        case GHOSTTY_ACTION_PROGRESS_REPORT:
            let r = c.action.progress_report
            action = .progressReport(state: GhosttyProgressState(r.state), percent: r.progress >= 0 ? Int(r.progress) : nil)

        case GHOSTTY_ACTION_COMMAND_FINISHED:
            let f = c.action.command_finished
            action = .commandFinished(
                exitCode: f.exit_code >= 0 ? Int32(f.exit_code) : nil,
                duration: TimeInterval(f.duration) / 1_000_000_000)

        case GHOSTTY_ACTION_MOUSE_SHAPE:
            let cursor = GhosttyAction.cursor(for: c.action.mouse_shape)
            if let cursor { setCursor(cursor) }
            action = .mouseShape(cursor)
            handledInternally = true

        case GHOSTTY_ACTION_MOUSE_VISIBILITY:
            NSCursor.setHiddenUntilMouseMoves(c.action.mouse_visibility == GHOSTTY_MOUSE_HIDDEN)
            action = .unhandled(kind: "mouse_visibility")
            handledInternally = true

        case GHOSTTY_ACTION_CELL_SIZE:
            cellSize = NSSize(width: Int(c.action.cell_size.width), height: Int(c.action.cell_size.height))
            action = .unhandled(kind: "cell_size")
            handledInternally = true

        case GHOSTTY_ACTION_COLOR_CHANGE:
            let ch = c.action.color_change
            guard ch.kind == GHOSTTY_ACTION_COLOR_KIND_BACKGROUND else {
                return notify(.unhandled(kind: "color_change"))
            }
            let color = NSColor(red: CGFloat(ch.r) / 255, green: CGFloat(ch.g) / 255, blue: CGFloat(ch.b) / 255, alpha: 1)
            backgroundColor = color
            let luminance = 0.2126 * Double(ch.r) / 255 + 0.7152 * Double(ch.g) / 255 + 0.0722 * Double(ch.b) / 255
            action = .colorScheme(dark: luminance < 0.5)
            handledInternally = true

        case GHOSTTY_ACTION_OPEN_URL:
            guard let url = GhosttyAction.url(from: c.action.open_url) else { return false }
            action = .openURL(url, kind: GhosttyAction.urlKind(c.action.open_url.kind))

        case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
            let info = c.action.child_exited
            delegate?.surfaceChildExited(self, exitCode: Int32(clamping: info.exit_code))
            return true

        case GHOSTTY_ACTION_QUIT: action = .quit
        case GHOSTTY_ACTION_NEW_TAB: action = .newTab
        case GHOSTTY_ACTION_NEW_WINDOW: action = .newWindow
        case GHOSTTY_ACTION_NEW_SPLIT: action = .newSplit

        default:
            action = .unhandled(kind: GhosttyAction.kindName(c.tag))
        }

        let handled = notify(action)
        return handled || handledInternally
    }

    /// Delegate first, then the app handler.
    private func notify(_ action: GhosttyAction) -> Bool {
        if let delegate, delegate.surface(self, didReceive: action) { return true }
        return runtime.dispatchToApp(action)
    }

    func handleCloseRequest(processAlive: Bool) {
        delegate?.surfaceRequestedClose(self, processAlive: processAlive)
    }

    // MARK: - Geometry / scale / focus

    public override var acceptsFirstResponder: Bool { true }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        sizeDidChange(newSize)
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        updateDisplayID()
        viewDidChangeBackingProperties()
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()

        // Keep the renderer's layer from being rescaled by the compositor when the
        // window moves between displays with different scale factors.
        if let window {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.contentsScale = window.backingScaleFactor
            CATransaction.commit()
        }

        guard let surface, frame.width > 0, frame.height > 0 else { return }
        let fb = convertToBacking(frame)
        ghostty_surface_set_content_scale(surface, fb.width / frame.width, fb.height / frame.height)
        sizeDidChange(frame.size)
    }

    private func sizeDidChange(_ size: NSSize) {
        guard let surface else { return }
        let scaled = convertToBacking(size)
        guard scaled.width > 0, scaled.height > 0 else { return }
        ghostty_surface_set_size(surface, UInt32(scaled.width), UInt32(scaled.height))
    }

    private func updateDisplayID() {
        guard let surface, let screen = window?.screen else { return }
        let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 ?? 0
        ghostty_surface_set_display_id(surface, id)
    }

    public override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { focusDidChange(window?.isKeyWindow ?? false) }
        return result
    }

    public override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { focusDidChange(false) }
        return result
    }

    private func focusDidChange(_ focused: Bool) {
        guard let surface, self.focused != focused else { return }
        self.focused = focused
        if !focused { suppressNextLeftMouseUp = false }
        ghostty_surface_set_focus(surface, focused)
    }

    @objc private func windowDidBecomeKey(_ note: Notification) {
        guard let window, (note.object as? NSWindow) === window else { return }
        if window.firstResponder === self { focusDidChange(true) }
    }

    @objc private func windowDidResignKey(_ note: Notification) {
        guard let window, (note.object as? NSWindow) === window else { return }
        focusDidChange(false)
    }

    @objc private func windowDidChangeScreen(_ note: Notification) {
        guard let window, (note.object as? NSWindow) === window else { return }
        updateDisplayID()
        // The new screen may have a different scale factor.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.viewDidChangeBackingProperties() }
        }
    }

    public override func updateTrackingAreas() {
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: frame,
            options: [.mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .inVisibleRect, .activeAlways],
            owner: self,
            userInfo: nil))
    }

    // MARK: - Cursor

    private func setCursor(_ cursor: NSCursor) {
        self.cursor = cursor
        window?.invalidateCursorRects(for: self)
        if let window, let event = NSApp?.currentEvent {
            let location = convert(event.locationInWindow, from: nil)
            if bounds.contains(location), window.isKeyWindow { cursor.set() }
        }
    }

    public override func resetCursorRects() {
        addCursorRect(bounds, cursor: cursor)
    }

    public override func cursorUpdate(with event: NSEvent) {
        cursor.set()
    }

    // MARK: - Local event monitor

    private func localEvent(_ event: NSEvent) -> NSEvent? {
        switch event.type {
        case .keyUp:
            // Command keyUp events never reach the responder chain; feed them here.
            guard event.modifierFlags.contains(.command), focused else { return event }
            keyUp(with: event)
            return nil

        case .leftMouseDown:
            guard let window, event.window === window else { return event }
            let location = convert(event.locationInWindow, from: nil)
            guard hitTest(location) === self else { return event }
            suppressNextLeftMouseUp = false
            guard window.firstResponder !== self else { return event }
            if NSApp.isActive && window.isKeyWindow {
                // Click only transfers focus; don't forward it to the terminal.
                window.makeFirstResponder(self)
                suppressNextLeftMouseUp = true
                return nil
            }
            window.makeFirstResponder(self)
            return event   // let AppKit activate/key the window

        default:
            return event
        }
    }

    // MARK: - Mouse

    public override func mouseDown(with event: NSEvent) {
        guard let surface else { return }
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, GhosttyMods.from(event.modifierFlags))
    }

    public override func mouseUp(with event: NSEvent) {
        if suppressNextLeftMouseUp {
            suppressNextLeftMouseUp = false
            return
        }
        prevPressureStage = 0
        guard let surface else { return }
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, GhosttyMods.from(event.modifierFlags))
        ghostty_surface_mouse_pressure(surface, 0, 0)
    }

    public override func otherMouseDown(with event: NSEvent) {
        guard let surface else { return }
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS,
                                         GhosttyMouseButton.from(buttonNumber: event.buttonNumber),
                                         GhosttyMods.from(event.modifierFlags))
    }

    public override func otherMouseUp(with event: NSEvent) {
        guard let surface else { return }
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE,
                                         GhosttyMouseButton.from(buttonNumber: event.buttonNumber),
                                         GhosttyMods.from(event.modifierFlags))
    }

    public override func rightMouseDown(with event: NSEvent) {
        guard let surface else { return super.rightMouseDown(with: event) }
        if ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, GhosttyMods.from(event.modifierFlags)) {
            return
        }
        super.rightMouseDown(with: event)
    }

    public override func rightMouseUp(with event: NSEvent) {
        guard let surface else { return super.rightMouseUp(with: event) }
        if ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, GhosttyMods.from(event.modifierFlags)) {
            return
        }
        super.rightMouseUp(with: event)
    }

    public override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        // Reset the position on enter: libghostty uses -1/-1 (set on exit) to decide
        // whether the pointer is in the viewport.
        sendMousePosition(event)
    }

    public override func mouseExited(with event: NSEvent) {
        guard let surface else { return }
        // Dragging continues to deliver mouseDragged even outside the view.
        if NSEvent.pressedMouseButtons != 0 { return }
        ghostty_surface_mouse_pos(surface, -1, -1, GhosttyMods.from(event.modifierFlags))
    }

    public override func mouseMoved(with event: NSEvent) {
        sendMousePosition(event)
    }

    public override func mouseDragged(with event: NSEvent) { sendMousePosition(event) }
    public override func rightMouseDragged(with event: NSEvent) { sendMousePosition(event) }
    public override func otherMouseDragged(with event: NSEvent) { sendMousePosition(event) }

    private func sendMousePosition(_ event: NSEvent) {
        guard let surface else { return }
        let pos = convert(event.locationInWindow, from: nil)
        // libghostty uses a top-left origin.
        ghostty_surface_mouse_pos(surface, pos.x, frame.height - pos.y, GhosttyMods.from(event.modifierFlags))
    }

    public override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        var x = event.scrollingDeltaX
        var y = event.scrollingDeltaY
        let precision = event.hasPreciseScrollingDeltas
        if precision {
            // Ghostty applies a 2x multiplier to precise (trackpad) deltas.
            x *= 2
            y *= 2
        }
        ghostty_surface_mouse_scroll(surface, x, y, GhosttyScrollMods.pack(precision: precision, momentum: event.momentumPhase))
    }

    public override func pressureChange(with event: NSEvent) {
        guard let surface else { return }
        ghostty_surface_mouse_pressure(surface, UInt32(event.stage), Double(event.pressure))
        prevPressureStage = event.stage
    }

    public override func menu(for event: NSEvent) -> NSMenu? {
        switch event.type {
        case .rightMouseDown:
            break
        case .leftMouseDown:
            guard event.modifierFlags.contains(.control), let surface else { return nil }
            // With mouse capture the terminal app gets ctrl+click instead of a menu.
            if ghostty_surface_mouse_captured(surface) { return nil }
            // Returning a menu swallows the mouse events, so report the press manually.
            _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, GhosttyMods.from(event.modifierFlags))
        default:
            return nil
        }

        let menu = NSMenu()
        if hasSelection {
            menu.addItem(withTitle: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
        }
        menu.addItem(withTitle: "Paste", action: #selector(paste(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Select All", action: #selector(selectAll(_:)), keyEquivalent: "")
        return menu
    }

    // MARK: - Standard edit actions (responder chain)

    @IBAction public func copy(_ sender: Any?) { perform(action: "copy_to_clipboard") }
    @IBAction public func paste(_ sender: Any?) { perform(action: "paste_from_clipboard") }
    @IBAction public override func selectAll(_ sender: Any?) { perform(action: "select_all") }

    // MARK: - Keyboard
    //
    // This mirrors Ghostty's SurfaceView_AppKit key handling closely: keyDown runs the
    // event through interpretKeyEvents (IME/dead keys/marked text), collects any text
    // inserted, then sends ghostty_surface_key with the proper mods/consumed mods.

    public override func keyDown(with event: NSEvent) {
        guard let surface else {
            interpretKeyEvents([event])
            return
        }

        // Translate mods for option-as-alt etc.
        let translationModsGhostty = GhosttyMods.flags(
            from: ghostty_surface_key_translation_mods(surface, GhosttyMods.from(event.modifierFlags)))

        // Only touch the four primary flags; hidden bits matter for dead keys.
        var translationMods = event.modifierFlags
        for flag in [NSEvent.ModifierFlags.shift, .control, .option, .command] {
            if translationModsGhostty.contains(flag) { translationMods.insert(flag) } else { translationMods.remove(flag) }
        }

        // Reuse the original event when mods are unchanged: AppKit relies on object
        // identity somewhere and Korean input breaks otherwise.
        let translationEvent: NSEvent
        if translationMods == event.modifierFlags {
            translationEvent = event
        } else {
            translationEvent = NSEvent.keyEvent(
                with: event.type,
                location: event.locationInWindow,
                modifierFlags: translationMods,
                timestamp: event.timestamp,
                windowNumber: event.windowNumber,
                context: nil,
                characters: event.characters(byApplyingModifiers: translationMods) ?? "",
                charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
                isARepeat: event.isARepeat,
                keyCode: event.keyCode) ?? event
        }

        let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS

        // Non-nil accumulator marks that we're inside keyDown; insertText appends to it.
        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }

        let markedTextBefore = markedText.length > 0

        // Some key events switch the keyboard layout; those must not reach the terminal.
        let keyboardIdBefore: String? = markedTextBefore ? nil : KeyboardLayout.id

        // Inside keyDown a command-modded key never needs redispatching (see doCommand).
        lastPerformKeyEvent = nil

        interpretKeyEvents([translationEvent])

        if !markedTextBefore && keyboardIdBefore != KeyboardLayout.id {
            return
        }

        syncPreedit(clearIfNeeded: markedTextBefore)

        if let list = keyTextAccumulator, !list.isEmpty {
            // Composed text: never "composing".
            for text in list {
                _ = keyAction(action, event: event, translationEvent: translationEvent, text: text)
            }
        } else {
            _ = keyAction(
                action,
                event: event,
                translationEvent: translationEvent,
                text: translationEvent.ghosttyCharacters,
                // Composing if we have preedit, or if this event just cleared preedit
                // (e.g. backspace cancelling a Japanese composition must not be encoded).
                composing: markedText.length > 0 || markedTextBefore)
        }
    }

    public override func keyUp(with event: NSEvent) {
        _ = keyAction(GHOSTTY_ACTION_RELEASE, event: event)
    }

    /// See Ghostty's `lastPerformKeyEvent` docs: command/control key equivalents that
    /// AppKit converts into `doCommand(by:)` selectors before keyDown are sent back
    /// through the event system, identified by timestamp, so they get encoded.
    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        guard focused else { return false }

        // Bindings are handled by us directly.
        if let surface {
            var keyEvent = event.ghosttyKeyEvent(GHOSTTY_ACTION_PRESS)
            var flags = ghostty_binding_flags_e(0)
            let isBinding = (event.characters ?? "").withCString { ptr in
                keyEvent.text = ptr
                return ghostty_surface_key_is_binding(surface, keyEvent, &flags)
            }
            if isBinding {
                keyDown(with: event)
                return true
            }
        }

        let equivalent: String
        switch event.charactersIgnoringModifiers {
        case "\r":
            // Pass ctrl+return through verbatim (avoid the default context-menu equivalent).
            if !event.modifierFlags.contains(.control) { return false }
            equivalent = "\r"

        case "/":
            // Treat ctrl+/ as ctrl+_ to avoid the system beep.
            if !event.modifierFlags.contains(.control) ||
                !event.modifierFlags.isDisjoint(with: [.shift, .command, .option]) {
                return false
            }
            equivalent = "_"

        default:
            // AppKit sometimes synthesizes events with a zero timestamp (cmd+period →
            // synthetic escape); never process those here.
            if event.timestamp == 0 { return false }

            if !event.modifierFlags.contains(.command) && !event.modifierFlags.contains(.control) {
                lastPerformKeyEvent = nil
                return false
            }

            if let last = lastPerformKeyEvent {
                lastPerformKeyEvent = nil
                if last == event.timestamp {
                    equivalent = event.characters ?? ""
                    break
                }
            }

            lastPerformKeyEvent = event.timestamp
            return false
        }

        guard let finalEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: event.locationInWindow,
            modifierFlags: event.modifierFlags,
            timestamp: event.timestamp,
            windowNumber: event.windowNumber,
            context: nil,
            characters: equivalent,
            charactersIgnoringModifiers: equivalent,
            isARepeat: event.isARepeat,
            keyCode: event.keyCode) else { return false }

        keyDown(with: finalEvent)
        return true
    }

    public override func flagsChanged(with event: NSEvent) {
        let mod: UInt32
        switch event.keyCode {
        case 0x39: mod = GHOSTTY_MODS_CAPS.rawValue
        case 0x38, 0x3C: mod = GHOSTTY_MODS_SHIFT.rawValue
        case 0x3B, 0x3E: mod = GHOSTTY_MODS_CTRL.rawValue
        case 0x3A, 0x3D: mod = GHOSTTY_MODS_ALT.rawValue
        case 0x37, 0x36: mod = GHOSTTY_MODS_SUPER.rawValue
        default: return
        }

        if hasMarkedText() { return }

        let mods = GhosttyMods.from(event.modifierFlags)
        var action = GHOSTTY_ACTION_RELEASE
        if mods.rawValue & mod != 0 {
            // Pressed: verify the correct side is down, otherwise it's a release with
            // the opposite side still held.
            let sidePressed: Bool
            switch event.keyCode {
            case 0x3C: sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERSHIFTKEYMASK) != 0
            case 0x3E: sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERCTLKEYMASK) != 0
            case 0x3D: sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERALTKEYMASK) != 0
            case 0x36: sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERCMDKEYMASK) != 0
            default: sidePressed = true
            }
            if sidePressed { action = GHOSTTY_ACTION_PRESS }
        }
        _ = keyAction(action, event: event)
    }

    private func keyAction(
        _ action: ghostty_input_action_e,
        event: NSEvent,
        translationEvent: NSEvent? = nil,
        text: String? = nil,
        composing: Bool = false
    ) -> Bool {
        guard let surface else { return false }
        var keyEvent = event.ghosttyKeyEvent(action, translationMods: translationEvent?.modifierFlags)
        keyEvent.composing = composing

        // Only pass UTF-8 text that isn't a lone control character; Ghostty encodes
        // control characters itself (otherwise ctrl+enter misbehaves).
        if let text, !text.isEmpty, let first = text.utf8.first, first >= 0x20 {
            return text.withCString { ptr in
                keyEvent.text = ptr
                return ghostty_surface_key(surface, keyEvent)
            }
        }
        return ghostty_surface_key(surface, keyEvent)
    }

    /// Push the marked (preedit) text to libghostty.
    private func syncPreedit(clearIfNeeded: Bool = true) {
        guard let surface else { return }
        if markedText.length > 0 {
            let str = markedText.string
            let len = str.utf8.count
            if len > 0 {
                str.withCString { ghostty_surface_preedit(surface, $0, UInt(len)) }
            }
        } else if clearIfNeeded {
            ghostty_surface_preedit(surface, nil, 0)
        }
    }

    // MARK: - NSTextInputClient

    public func hasMarkedText() -> Bool {
        markedText.length > 0
    }

    public func markedRange() -> NSRange {
        guard markedText.length > 0 else { return NSRange() }
        return NSRange(location: 0, length: markedText.length)
    }

    public func selectedRange() -> NSRange {
        guard let surface else { return NSRange() }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return NSRange() }
        defer { ghostty_surface_free_text(surface, &text) }
        return NSRange(location: Int(text.offset_start), length: Int(text.offset_len))
    }

    public func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        switch string {
        case let v as NSAttributedString: markedText = NSMutableAttributedString(attributedString: v)
        case let v as String: markedText = NSMutableAttributedString(string: v)
        default: return
        }
        // Outside keyDown (e.g. layout switch while composing) update preedit immediately.
        if keyTextAccumulator == nil { syncPreedit() }
    }

    public func unmarkText() {
        if markedText.length > 0 {
            markedText.mutableString.setString("")
            syncPreedit()
        }
    }

    public func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    public func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        guard let surface, range.length > 0 else { return nil }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        var attributes: [NSAttributedString.Key: Any] = [:]
        if let fontRaw = ghostty_surface_quicklook_font(surface) {
            // quicklook_font returns a +1 CTFont copy; the dictionary retains it, so release ours.
            let font = Unmanaged<CTFont>.fromOpaque(fontRaw)
            attributes[.font] = font.takeUnretainedValue()
            font.release()
        }
        return NSAttributedString(string: String(cString: text.text), attributes: attributes)
    }

    public func characterIndex(for point: NSPoint) -> Int { 0 }

    public func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let surface else { return NSRect(x: frame.origin.x, y: frame.origin.y, width: 0, height: 0) }
        var x: Double = 0, y: Double = 0
        var width: Double = cellSize.width, height: Double = cellSize.height
        ghostty_surface_ime_point(surface, &x, &y, &width, &height)
        if range.length == 0, width > 0 {
            // Dictation indicator placement (Ghostty #8493).
            width = 0
            x += cellSize.width * Double(range.location + range.length)
        }
        let viewRect = NSRect(x: x, y: frame.size.height - y, width: width, height: max(height, cellSize.height))
        let winRect = convert(viewRect, to: nil)
        guard let window else { return winRect }
        return window.convertToScreen(winRect)
    }

    public func insertText(_ string: Any, replacementRange: NSRange) {
        guard NSApp.currentEvent != nil else { return }
        let chars: String
        switch string {
        case let v as NSAttributedString: chars = v.string
        case let v as String: chars = v
        default: return
        }
        // insertText ends any preedit.
        unmarkText()
        // Inside keyDown: accumulate so keyDown can send it with full key info.
        if var acc = keyTextAccumulator {
            acc.append(chars)
            keyTextAccumulator = acc
            return
        }
        sendText(chars)
    }

    /// Exists to (1) silence the NSBeep for unimplemented selectors and (2) send
    /// command-modded key equivalents back through the event system (see performKeyEquivalent).
    public override func doCommand(by selector: Selector) {
        if let last = lastPerformKeyEvent, let current = NSApp.currentEvent, last == current.timestamp {
            NSApp.sendEvent(current)
            return
        }
        switch selector {
        case #selector(moveToBeginningOfDocument(_:)): perform(action: "scroll_to_top")
        case #selector(moveToEndOfDocument(_:)): perform(action: "scroll_to_bottom")
        default: break
        }
    }

    // MARK: - Drag and drop

    public override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard let types = sender.draggingPasteboard.types else { return [] }
        let accepted: Set<NSPasteboard.PasteboardType> = [.string, .fileURL, .URL]
        return Set(types).isDisjoint(with: accepted) ? [] : .copy
    }

    public override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        let content: String?
        if let url = pb.string(forType: .URL) {
            content = ShellEscape.escape(url)
        } else if let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty {
            content = urls.map { ShellEscape.escape($0.path) }.joined(separator: " ")
        } else if let str = pb.string(forType: .string) {
            content = str
        } else {
            content = nil
        }
        guard let content else { return false }
        sendText(content)
        return true
    }

    // MARK: - Accessibility

    public override func isAccessibilityElement() -> Bool { true }
    public override func accessibilityRole() -> NSAccessibility.Role? { .textArea }
    public override func accessibilityHelp() -> String? { "Terminal content area" }
    public override func accessibilitySelectedText() -> String? { selectedText }
}
