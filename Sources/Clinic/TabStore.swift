import AppKit
import Observation
import os
import ClinicCore
import GhosttyBridge

/// An open Session or shell inside the window (ADR-025). Owns its surface for its whole life (ADR-019).
@MainActor
@Observable
final class Tab: Identifiable {
    enum Kind: Hashable { case session(SessionID), shell }

    let id = UUID()
    let kind: Kind
    let projectPath: String
    let surface: GhosttySurfaceView
    var state: SessionState?
    var unread = false
    var errorBadge = false
    var title: String
    var pwd: String?
    var childExited = false
    var lastResume: ClaudeLaunch?
    /// Text to type once the shell shows its first prompt (ADR-016). Sent on the first `pwd` report or after a short fallback delay.
    var pendingInput: String?
    var gitBranch: String?
    var model: String?

    init(kind: Kind, projectPath: String, surface: GhosttySurfaceView, title: String) {
        self.kind = kind; self.projectPath = projectPath; self.surface = surface; self.title = title
        self.state = { if case .session = kind { return .launching } else { return nil } }()
    }

    var sessionId: SessionID? { if case .session(let id) = kind { return id } else { return nil } }
    var isRunningClaude: Bool { state != nil && state != .exited && !childExited }
}

/// Owns the libghostty runtime and every open tab (ADR-019, ADR-041, ADR-043).
@MainActor
@Observable
final class TabStore {
    private static let log = Logger(subsystem: "com.r0adkll.clinic", category: "tabs")

    private(set) var runtime: GhosttyRuntime?
    private(set) var startupError: String?
    var lastSurfaceError: String?
    private(set) var tabs: [Tab] = []
    var selectedTabId: UUID? { didSet { applySelection() } }

    let sessions: SessionStore
    let hooks: HookService
    let notifications: NotificationService
    let history: NotificationStore

    init(sessions: SessionStore, hooks: HookService, notifications: NotificationService, history: NotificationStore) {
        self.sessions = sessions; self.hooks = hooks; self.notifications = notifications; self.history = history
    }

    /// Records to history and posts a system notification unless the session is muted (ADR-033, milestone 2).
    private func notify(_ tab: Tab, sessionId: SessionID, body: String, kind: NotificationStore.Entry.Kind) {
        history.record(sessionId: sessionId, title: tab.title, body: body, kind: kind)
        guard !sessions.state.mutedSessions.contains(sessionId) else { return }
        notifications.post(sessionId: sessionId, title: tab.title, body: body)
    }

    var selectedTab: Tab? { tabs.first { $0.id == selectedTabId } }

    func start() {
        Self.adoptInstalledGhosttyResources()
        do {
            let config = try GhosttyConfig()
            for d in config.diagnostics { Self.log.warning("ghostty config: \(d, privacy: .public)") }
            let runtime = try GhosttyRuntime(config: config)
            runtime.appActionHandler = { [weak self] action in self?.handleAppAction(action) ?? false }
            self.runtime = runtime
        } catch {
            startupError = "\(error)"
            Self.log.error("libghostty failed to start: \(error, privacy: .public)")
        }
        hooks.onEvent = { [weak self] event in self?.handle(hookEvent: event) }
        notifications.onActivate = { [weak self] id in self?.reveal(sessionId: id) }
    }

    /// ADR-034: shell integration scripts are GPLv3 and not bundled. If Ghostty.app is installed, let libghostty
    /// use its resources (shell-integration, themes, terminfo). Must run before the runtime is created.
    static func adoptInstalledGhosttyResources() {
        guard ProcessInfo.processInfo.environment["GHOSTTY_RESOURCES_DIR"] == nil else { return }
        let candidates = ["/Applications/Ghostty.app", FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Ghostty.app").path]
        for app in candidates {
            let dir = app + "/Contents/Resources/ghostty"
            if FileManager.default.fileExists(atPath: dir + "/shell-integration") {
                setenv("GHOSTTY_RESOURCES_DIR", dir, 1)
                Self.log.info("using Ghostty resources at \(dir, privacy: .public)")
                return
            }
        }
    }

    // MARK: Opening

    func tab(for sessionId: SessionID) -> Tab? { tabs.first { $0.sessionId == sessionId } }

    /// Opens (or focuses, ADR-041) a session known from disk.
    func open(session summary: SessionSummary) {
        if let existing = tab(for: summary.id) { selectedTabId = existing.id; return }
        let cwd = summary.lastCwd ?? summary.cwd ?? FileManager.default.homeDirectoryForCurrentUser.path
        let launch = ClaudeLaunch(mode: .resume(id: summary.id, fork: false), settingsFilePath: hooks.settingsFileURL.path)
        guard let tab = makeTab(kind: .session(summary.id), cwd: cwd, projectPath: ProjectGrouping.projectPath(forCwd: cwd),
                                initialInput: launch.shellLine, title: sessions.displayName(for: summary)) else { return }
        tab.lastResume = launch
        selectedTabId = tab.id
    }

    /// New session with a pre-assigned id (ADR-017, ADR-032).
    func newSession(projectPath: String, model: String?, worktree: Bool) {
        let id = SessionID.generate()
        let launch = ClaudeLaunch(mode: .new(id: id), model: model, worktree: worktree, settingsFilePath: hooks.settingsFileURL.path)
        guard let tab = makeTab(kind: .session(id), cwd: projectPath, projectPath: projectPath, initialInput: launch.shellLine, title: "New session") else { return }
        tab.lastResume = ClaudeLaunch(mode: .resume(id: id, fork: false), settingsFilePath: hooks.settingsFileURL.path)
        tab.model = model
        sessions.registerPending(id: id, cwd: projectPath)
        sessions.update { s in
            if let model { s.lastModelByProject[projectPath] = model } else { s.lastModelByProject[projectPath] = nil }
            s.lastWorktreeByProject[projectPath] = worktree
            if !s.addedProjects.contains(projectPath) && !worktree { /* project appears via its session */ }
        }
        selectedTabId = tab.id
    }

    func newShell(in directory: String? = nil) {
        let dir = directory ?? selectedTab?.pwd ?? selectedTab?.projectPath ?? FileManager.default.homeDirectoryForCurrentUser.path
        guard let tab = makeTab(kind: .shell, cwd: dir, projectPath: ProjectGrouping.projectPath(forCwd: dir), initialInput: nil, title: "Shell") else { return }
        selectedTabId = tab.id
    }

    private func makeTab(kind: Tab.Kind, cwd: String, projectPath: String, initialInput: String?, title: String) -> Tab? {
        guard let runtime else { return nil }
        var options = GhosttySurfaceOptions()
        options.workingDirectory = cwd
        options.environment = ["CLINIC": "1"]
        do {
            let surface: GhosttySurfaceView
            do {
                surface = try GhosttySurfaceView(runtime: runtime, options: options)
            } catch {
                // ghostty_surface_new has been observed to fail intermittently right after launch; one retry after a tick.
                Self.log.warning("surface creation failed once, retrying: \(error, privacy: .public)")
                runtime.tick()
                RunLoop.main.run(until: Date().addingTimeInterval(0.15))
                surface = try GhosttySurfaceView(runtime: runtime, options: options)
            }
            let tab = Tab(kind: kind, projectPath: projectPath, surface: surface, title: title)
            tab.pwd = cwd
            tab.pendingInput = initialInput
            surface.delegate = self
            tabs.append(tab)
            refreshFooter(tab)
            if initialInput != nil {
                Task { [weak self, weak tab] in
                    try? await Task.sleep(for: .milliseconds(Self.initialInputFallbackMs))
                    if let tab { self?.flushPendingInput(tab) }
                }
            }
            return tab
        } catch {
            Self.log.error("surface creation failed: \(error, privacy: .public)")
            lastSurfaceError = "\(error)"
            return nil
        }
    }

    /// Fallback if the shell never reports a prompt (no shell integration).
    static let initialInputFallbackMs = 700

    /// Refresh footer facts for a tab (ADR-013 H, milestone 2): branch from git, model from the transcript.
    func refreshFooter(_ tab: Tab) {
        let dir = tab.pwd ?? tab.projectPath
        Task { [weak tab] in
            let branch = await GitInfo.branch(at: dir)
            await MainActor.run { tab?.gitBranch = branch }
        }
        if let id = tab.sessionId, let s = sessions.sessions[id], let m = s.model { tab.model = m }
    }

    private func flushPendingInput(_ tab: Tab) {
        guard let text = tab.pendingInput else { return }
        tab.pendingInput = nil
        tab.surface.sendLine(text)
    }

    // MARK: Selection / close (ADR-019, ADR-037)

    private func applySelection() {
        for t in tabs { t.surface.isOccluded = (t.id != selectedTabId) }
        if let tab = selectedTab {
            tab.unread = false
            if let id = tab.sessionId { history.markRead(sessionId: id) }
            if let id = tab.sessionId { sessions.update { $0.selectedSessionId = id } }
            updateBadge()
        }
    }

    func select(_ tab: Tab) { selectedTabId = tab.id }

    func reveal(sessionId: SessionID) {
        if let tab = tab(for: sessionId) { selectedTabId = tab.id }
        else if let summary = sessions.sessions[sessionId] { open(session: summary) }
    }

    func selectNext(_ delta: Int) {
        guard !tabs.isEmpty else { return }
        let idx = tabs.firstIndex { $0.id == selectedTabId } ?? 0
        selectedTabId = tabs[((idx + delta) % tabs.count + tabs.count) % tabs.count].id
    }

    func selectIndex(_ i: Int) { if tabs.indices.contains(i) { selectedTabId = tabs[i].id } }

    /// Returns false if the user cancelled.
    @discardableResult
    func close(_ tab: Tab, confirm: Bool = true) -> Bool {
        if confirm && tab.isRunningClaude && !confirmClose(count: 1) { return false }
        tabs.removeAll { $0.id == tab.id }
        if selectedTabId == tab.id { selectedTabId = tabs.last?.id }
        tab.surface.free()
        if let id = tab.sessionId { sessions.removePending(id: id) }
        updateBadge()
        return true
    }

    func closeSelected() { if let t = selectedTab { close(t) } }

    var runningCount: Int { tabs.filter(\.isRunningClaude).count }

    func confirmClose(count: Int) -> Bool {
        let alert = NSAlert()
        alert.messageText = count == 1 ? "Close this session?" : "Quit with \(count) running sessions?"
        alert.informativeText = count == 1 ? "Claude Code is still running in this tab. Closing it will end the process; you can resume the session later."
                                           : "Their processes will be ended. You can resume each session later."
        alert.alertStyle = .warning
        alert.addButton(withTitle: count == 1 ? "Close" : "Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func resume(_ tab: Tab) {
        guard tab.childExited, let launch = tab.lastResume else { return }
        tab.childExited = false
        tab.state = .launching
        tab.surface.sendLine(launch.shellLine)
    }

    // MARK: Hooks → state (ADR-026, ADR-033)

    private func handle(hookEvent event: HookEvent) {
        guard let tab = tab(for: event.sessionId) else {
            Self.log.debug("hook for unknown session \(event.sessionId.rawValue, privacy: .public): \(event.hookEventName, privacy: .public)")
            return
        }
        if let cwd = event.cwd, event.hookEventName == "SessionStart" || event.hookEventName == "CwdChanged" { tab.pwd = cwd }
        if let path = event.transcriptPath, event.hookEventName == "SessionStart" || event.hookEventName == "Stop" || event.hookEventName == "PostModelSwitch" {
            Task { await sessions.refresh(transcriptPath: path); self.refreshTitle(tab); self.refreshFooter(tab) }
        } else if event.hookEventName == "CwdChanged" || event.hookEventName == "WorktreeCreate" {
            refreshFooter(tab)
        }
        guard let old = tab.state, let new = SessionStateMachine.reduce(old, event: event) else { return }
        tab.state = new
        tab.errorBadge = (event.hookEventName == "StopFailure")
        let isFrontAndSelected = NSApp.isActive && selectedTabId == tab.id
        if event.hookEventName == "StopFailure" {
            notify(tab, sessionId: event.sessionId, body: event.message ?? "The turn ended with an API error", kind: .error)
        } else if SessionStateMachine.isFinishedEdge(from: old, to: new) {
            if !isFrontAndSelected { tab.unread = true; notify(tab, sessionId: event.sessionId, body: "Finished", kind: .finished) }
        } else if new.isWaiting && !old.isWaiting {
            if !isFrontAndSelected {
                let permission = new == .waitingForPermission
                notify(tab, sessionId: event.sessionId, body: permission ? "Needs permission" : (event.message ?? "Waiting for input"), kind: permission ? .needsPermission : .needsInput)
            }
        }
        updateBadge()
    }

    private func refreshTitle(_ tab: Tab) {
        if let id = tab.sessionId, let s = sessions.sessions[id] { tab.title = sessions.displayName(for: s) }
    }

    func updateBadge() {
        notifications.setBadge(tabs.filter { $0.unread || ($0.state?.isWaiting ?? false) }.count)
    }

    // MARK: libghostty actions (ADR-035)

    private func handleAppAction(_ action: GhosttyAction) -> Bool {
        switch action {
        case .newTab, .newWindow, .newSplit: newShell(); return true
        case .quit: NSApp.terminate(nil); return true
        case .unhandled(let kind): Self.log.debug("unhandled app action \(kind, privacy: .public)"); return false
        default: return false
        }
    }
}

extension TabStore: GhosttySurfaceDelegate {
    func surface(_ surface: GhosttySurfaceView, didReceive action: GhosttyAction) -> Bool {
        let tab = tabs.first { $0.surface === surface }
        switch action {
        case .newTab, .newWindow, .newSplit: newShell(in: tab?.pwd); return true
        case .openURL(let url, _): NSWorkspace.shared.open(url); return true
        case .ringBell: NSSound.beep(); return true
        case .setTitle(let t): if let tab, tab.kind == .shell { tab.title = t.isEmpty ? "Shell" : t }; return true
        case .pwd(let p):
            if let tab {
                let changed = tab.pwd != p
                tab.pwd = p
                flushPendingInput(tab)
                if changed { refreshFooter(tab) }
            }
            return true
        case .progressReport, .commandFinished, .mouseShape, .colorScheme: return true
        case .quit: NSApp.terminate(nil); return true
        case .unhandled(let kind): Self.log.debug("unhandled surface action \(kind, privacy: .public)"); return false
        }
    }

    func surfaceRequestedClose(_ surface: GhosttySurfaceView, processAlive: Bool) {
        if let tab = tabs.first(where: { $0.surface === surface }) { close(tab, confirm: processAlive) }
    }

    func surfaceChildExited(_ surface: GhosttySurfaceView, exitCode: Int32?) {
        guard let tab = tabs.first(where: { $0.surface === surface }) else { return }
        tab.childExited = true
        if tab.state != nil { tab.state = .exited }
        updateBadge()
    }
}
