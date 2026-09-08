import AppKit
import Observation
import os
import ClinicCore
import GhosttyBridge

/// An open Session or shell inside the window (ADR-025). Owns its surface for its whole life (ADR-019).
@MainActor
@Observable
final class Tab: Identifiable {
    enum Kind: Hashable { case session(SessionID), shell, replay(SessionID) }

    let id = UUID()
    /// Mutable so a fork/continue tab can rebind to the id the CLI reports (ADR-063).
    var kind: Kind
    let projectPath: String
    let surface: GhosttySurfaceView
    /// Replay tabs carry a model instead of a live process (ADR-059).
    var replay: ReplayModel?
    /// Persistent AppKit host for the tab's surfaces and right page (never re-parented by SwiftUI).
    @ObservationIgnored let contentView: TabContentView
    var state: SessionState?
    var unread = false
    var errorBadge = false
    var title: String
    var pwd: String?
    var childExited = false
    var lastResume: ClaudeLaunch?
    /// Set when the user chose Background: the tab closes itself once `/bg` detaches the CLI (ADR-061).
    var detaching = false
    var isAttached = false
    /// Awaiting `SessionStart` to learn the real session id (fork / continue).
    var awaitingId = false
    /// Close the tab as soon as `SessionEnd` arrives (graceful close, ADR-063).
    var closingGracefully = false
    /// Text to type once the shell shows its first prompt (ADR-016). Sent on the first `pwd` report or after a short fallback delay.
    var pendingInput: String?
    var gitBranch: String?
    var model: String?
    var effort: String?
    /// Secondary plain shell below the main surface (ADR-046). Created lazily by ⌘J, freed with the tab.
    var panelSurface: GhosttySurfaceView?
    var panelVisible = false
    /// Right column: git page (ADR-052) or PR page (ADR-053). One at a time.
    enum RightPane: Equatable { case none, git, pr(PullRequestRef), attachments, editor }
    var rightPane: RightPane = .none
    var gitPage: GitPageModel?
    var gitPageVisible: Bool { rightPane == .git }
    /// Editor panel (ADR-057), created on first open.
    var editor: EditorModel?

    init(kind: Kind, projectPath: String, surface: GhosttySurfaceView, title: String) {
        self.kind = kind; self.projectPath = projectPath; self.surface = surface; self.title = title
        self.contentView = TabContentView(surface: surface)
        self.state = { if case .session = kind { return .launching } else { return nil } }()
    }

    var sessionId: SessionID? { if case .session(let id) = kind { return id } else { return nil } }
    var isReplay: Bool { if case .replay = kind { return true } else { return false } }
    var isRunningClaude: Bool { (state != nil && state != .exited && !childExited) || (isAttached && !childExited) }
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
    /// The new-session screen shown in the content area (ADR-071); selecting a tab dismisses it (text kept per project).
    var editingDraft: NewSessionDraft? { didSet { if editingDraft != nil, selectedTabId != nil { selectedTabId = nil } } }
    private var drafts: [String: NewSessionDraft] = [:]

    let sessions: SessionStore
    let hooks: HookService
    let notifications: NotificationService
    let history: NotificationStore
    /// Set by the app after construction (ADR-056, ADR-061).
    var mcp: MCPToolService?
    var backgroundAgents: BackgroundAgentsService?

    init(sessions: SessionStore, hooks: HookService, notifications: NotificationService, history: NotificationStore) {
        self.sessions = sessions; self.hooks = hooks; self.notifications = notifications; self.history = history
    }

    /// Single router for attention (ADR-066): history always; then by focus — looking at it: nothing more;
    /// app active elsewhere: in-app card (+ sound pref); app inactive: system notification. Muted sessions get history only.
    func notify(_ tab: Tab?, sessionId: SessionID?, title: String, body: String, kind: NotificationStore.Entry.Kind, url: URL? = nil) {
        let entry = history.record(sessionId: sessionId, title: title, body: body, kind: kind, url: url)
        if let sessionId, sessions.state.mutedSessions.contains(sessionId) { return }
        let lookingAtIt = NSApp.isActive && tab != nil && selectedTabId == tab?.id
        if lookingAtIt { return }
        if NSApp.isActive {
            history.showCard(entry)
            if UserDefaults.standard.bool(forKey: Prefs.notificationSound) { NSSound(named: "Ping")?.play() }
        } else if let sessionId {
            notifications.post(sessionId: sessionId, title: title, body: body)
        } else {
            notifications.post(sessionId: SessionID(UUID().uuidString), title: title, body: body)
        }
        tab?.unread = true
        updateBadge()
    }

    private func notify(_ tab: Tab, sessionId: SessionID, body: String, kind: NotificationStore.Entry.Kind) {
        notify(tab, sessionId: sessionId, title: tab.title, body: body, kind: kind)
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
        sessions.adopt(summary)
        let cwd = summary.lastCwd ?? summary.cwd ?? FileManager.default.homeDirectoryForCurrentUser.path
        let running = backgroundAgents?.runningAgent(for: summary.id)
        var launch = ClaudeLaunch(mode: running.map { .attach(agentId: $0.id) } ?? .resume(id: summary.id, fork: false), settingsFilePath: hooks.settingsFileURL.path)
        launch.mcpConfigPath = running == nil ? mcp?.configPath(for: summary.id) : nil
        guard let tab = makeTab(kind: .session(summary.id), cwd: cwd, projectPath: ProjectGrouping.projectPath(forCwd: cwd),
                                initialInput: launch.shellLine, title: sessions.displayName(for: summary)) else { return }
        tab.isAttached = running != nil
        if running != nil { tab.state = nil }   // `claude attach` accepts no --settings, so no hooks: state is unknown
        tab.lastResume = launch
        selectedTabId = tab.id
    }

    // MARK: New-session screen (ADR-071)

    /// Opens the screen for a project (reusing unsent text), or the folder picker when no project is known.
    func startNewSession(projectPath: String? = nil) {
        guard let path = projectPath ?? selectedTab?.projectPath ?? editingDraft?.projectPath else {
            NotificationCenter.default.post(name: .clinicNewSession, object: nil); return
        }
        if let d = drafts[path] { editingDraft = d; return }
        let d = NewSessionDraft(projectPath: path, model: sessions.state.lastModelByProject[path], worktree: sessions.state.lastWorktreeByProject[path] ?? false)
        drafts[path] = d
        editingDraft = d
    }

    func discardDraft(_ d: NewSessionDraft) {
        drafts[d.projectPath] = nil
        if editingDraft?.id == d.id { editingDraft = nil; selectedTabId = tabs.last?.id }
    }

    func closeDraftScreen() {
        editingDraft = nil
        selectedTabId = tabs.last?.id
    }

    func sendDraft(_ d: NewSessionDraft, empty: Bool = false) {
        let prompt = empty ? nil : d.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        drafts[d.projectPath] = nil
        editingDraft = nil
        newSession(projectPath: d.projectPath, model: d.resolvedModel, worktree: d.worktree, worktreeName: d.worktree ? d.worktreeName : nil,
                   effort: d.resolvedEffort, prompt: (prompt?.isEmpty ?? true) ? nil : prompt)
    }

    /// New session with a pre-assigned id (ADR-017). `prompt` becomes the first turn (ADR-071).
    func newSession(projectPath: String, model: String?, worktree: Bool, worktreeName: String? = nil, effort: String? = nil, prompt: String? = nil) {
        let id = SessionID.generate()
        var launch = ClaudeLaunch(mode: .new(id: id), model: model, effort: effort, worktree: worktree, settingsFilePath: hooks.settingsFileURL.path, prompt: prompt)
        launch.worktreeName = worktreeName
        launch.mcpConfigPath = mcp?.configPath(for: id)
        guard let tab = makeTab(kind: .session(id), cwd: projectPath, projectPath: projectPath, initialInput: launch.shellLine, title: "New session") else { return }
        var resume = ClaudeLaunch(mode: .resume(id: id, fork: false), settingsFilePath: hooks.settingsFileURL.path)
        resume.mcpConfigPath = launch.mcpConfigPath
        tab.lastResume = resume
        tab.model = model
        tab.effort = effort
        sessions.registerPending(id: id, cwd: projectPath)
        sessions.update { s in
            if let model { s.lastModelByProject[projectPath] = model } else { s.lastModelByProject[projectPath] = nil }
            s.lastWorktreeByProject[projectPath] = worktree
            if !s.addedProjects.contains(projectPath) && !worktree { /* project appears via its session */ }
        }
        selectedTabId = tab.id
    }

    /// `claude --resume <id> --fork-session` in a new tab; rebinds on SessionStart (ADR-063).
    func fork(_ summary: SessionSummary) {
        let cwd = summary.lastCwd ?? summary.cwd ?? FileManager.default.homeDirectoryForCurrentUser.path
        var launch = ClaudeLaunch(mode: .resume(id: summary.id, fork: true), settingsFilePath: hooks.settingsFileURL.path)
        launch.mcpConfigPath = nil   // the per-session config is written once the fork's id is known
        guard let tab = makeTab(kind: .session(SessionID.generate()), cwd: cwd, projectPath: ProjectGrouping.projectPath(forCwd: cwd),
                                initialInput: launch.shellLine, title: "Fork of " + sessions.displayName(for: summary)) else { return }
        tab.awaitingId = true
        selectedTabId = tab.id
    }

    /// A session in the shared Chats scratch directory (ADR-068).
    func newChat() {
        let dir = SessionStore.chatsDirectory
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        startNewSession(projectPath: dir)
    }

    /// `claude --continue` in a project directory (ADR-063).
    func continueLast(in projectPath: String) {
        let launch = ClaudeLaunch(mode: .continueLast, settingsFilePath: hooks.settingsFileURL.path)
        guard let tab = makeTab(kind: .session(SessionID.generate()), cwd: projectPath, projectPath: projectPath, initialInput: launch.shellLine, title: "Continue last session") else { return }
        tab.awaitingId = true
        selectedTabId = tab.id
    }

    /// Resume in a standalone Ghostty window (ADR-063).
    func openInGhostty(_ summary: SessionSummary) {
        guard let ghostty = Self.ghosttyBinary else { return }
        let cwd = summary.lastCwd ?? summary.cwd ?? FileManager.default.homeDirectoryForCurrentUser.path
        let launch = ClaudeLaunch(mode: .resume(id: summary.id, fork: false), settingsFilePath: hooks.settingsFileURL.path)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ghostty)
        p.arguments = ["--working-directory=\(cwd)", "-e"] + [launch.executable] + launch.arguments
        var env = ProcessInfo.processInfo.environment
        for k in env.keys where k == "CLAUDECODE" || k.hasPrefix("CLAUDE_CODE_") { env[k] = nil }
        p.environment = env
        try? p.run()
    }

    static var ghosttyBinary: String? {
        let candidates = ["/Applications/Ghostty.app/Contents/MacOS/ghostty", FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Ghostty.app/Contents/MacOS/ghostty").path]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Opens a transcript as a replay tab; focuses an existing one (ADR-059).
    func openReplay(_ summary: SessionSummary) {
        if let existing = tabs.first(where: { $0.kind == .replay(summary.id) }) { selectedTabId = existing.id; return }
        guard let runtime else { return }
        // A replay tab still needs a Tab; give it an idle surface it never shows (cheapest way to keep Tab uniform).
        var options = GhosttySurfaceOptions()
        options.command = "/usr/bin/true"
        options.workingDirectory = summary.lastCwd ?? summary.cwd
        guard let surface = try? GhosttySurfaceView(runtime: runtime, options: options) else { return }
        surface.isOccluded = true
        let tab = Tab(kind: .replay(summary.id), projectPath: ProjectGrouping.projectPath(forCwd: summary.cwd ?? ""), surface: surface, title: "Replay: " + sessions.displayName(for: summary))
        tab.replay = ReplayModel(sessionId: summary.id, transcriptPath: summary.transcriptPath)
        tab.state = nil
        tabs.append(tab)
        selectedTabId = tab.id
    }

    func newShell(in directory: String? = nil, initialInput: String? = nil) {
        let dir = directory ?? selectedTab?.pwd ?? selectedTab?.projectPath ?? FileManager.default.homeDirectoryForCurrentUser.path
        guard let tab = makeTab(kind: .shell, cwd: dir, projectPath: ProjectGrouping.projectPath(forCwd: dir), initialInput: initialInput, title: "Shell") else { return }
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
        if selectedTabId != nil, editingDraft != nil { editingDraft = nil }
        for t in tabs {
            let hidden = (t.id != selectedTabId)
            t.surface.isOccluded = hidden
            t.panelSurface?.isOccluded = hidden || !t.panelVisible
        }
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
        if confirm && tab.isRunningClaude {
            switch confirmCloseTab(tab) {
            case .cancel: return false
            case .background: background(tab); return false
            case .close:
                if tab.state != nil, !tab.isAttached { closeGracefully(tab); return false }
            }
        }
        tabs.removeAll { $0.id == tab.id }
        if selectedTabId == tab.id { selectedTabId = tabs.last?.id }
        tab.surface.free()
        tab.panelSurface?.free()
        tab.panelSurface = nil
        tab.gitPage?.stopWatching()
        tab.editor?.stop()
        if let id = tab.sessionId { sessions.removePending(id: id) }
        updateBadge()
        return true
    }

    func closeSelected() { if let t = selectedTab { close(t) } }

    /// Types a slash command into an idle session (ADR-064). Returns false when the session is not at its prompt.
    @discardableResult
    func sendSlashCommand(_ command: String, to tab: Tab) -> Bool {
        guard tab.sessionId != nil, tab.state == .idle else { return false }
        tab.surface.sendLine(command)
        return true
    }

    func switchModel(_ tab: Tab, to model: String) {
        if sendSlashCommand("/model " + model, to: tab) { tab.model = model }
    }

    func switchEffort(_ tab: Tab, to level: String) {
        if sendSlashCommand("/effort " + level, to: tab) { tab.effort = level }
    }

    /// Ctrl‑C twice: Claude Code's clean exit (ADR-063). The shell stays in the tab.
    func stop(_ tab: Tab) {
        guard tab.isRunningClaude else { return }
        tab.surface.sendInterrupt()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { tab.surface.sendInterrupt() }
    }

    var canStopSelected: Bool { selectedTab?.isRunningClaude ?? false }

    /// Stop, then close once the CLI reports `SessionEnd` (5 s fallback).
    func closeGracefully(_ tab: Tab) {
        tab.closingGracefully = true
        stop(tab)
        Task { [weak self, weak tab] in
            try? await Task.sleep(for: .seconds(5))
            if let tab, tab.closingGracefully, self?.tabs.contains(where: { $0.id == tab.id }) == true { self?.close(tab, confirm: false) }
        }
    }

    /// Detach the session with `/bg`; the tab closes when the CLI hands the shell back (ADR-061).
    func background(_ tab: Tab) {
        guard tab.sessionId != nil, tab.state == .idle else { return }
        tab.detaching = true
        tab.surface.sendLine("/bg")
        Task { try? await Task.sleep(for: .seconds(2)); await backgroundAgents?.refresh() }
    }

    var canBackgroundSelected: Bool { selectedTab.map { $0.sessionId != nil && $0.state == .idle } ?? false }

    /// ⌘J: show/hide the tab's shell panel, creating the surface on first use in the tab's current directory.
    func togglePanel(_ tab: Tab? = nil) {
        guard let tab = tab ?? selectedTab, let runtime else { return }
        if tab.panelSurface == nil {
            var options = GhosttySurfaceOptions()
            options.workingDirectory = tab.pwd ?? tab.projectPath
            options.environment = ["CLINIC": "1", "CLINIC_PANEL": "1"]
            do {
                let surface = try GhosttySurfaceView(runtime: runtime, options: options)
                surface.delegate = self
                tab.panelSurface = surface
            } catch {
                Self.log.error("panel surface creation failed: \(error, privacy: .public)")
                lastSurfaceError = "\(error)"
                return
            }
            tab.panelVisible = true
        } else {
            tab.panelVisible.toggle()
        }
        tab.panelSurface?.isOccluded = !tab.panelVisible
        let target = tab.panelVisible ? tab.panelSurface : tab.surface
        DispatchQueue.main.async { target?.window?.makeFirstResponder(target) }
    }

    /// ⌘⇧G: show/hide the tab's git page.
    func toggleGitPage(_ tab: Tab? = nil) {
        guard let tab = tab ?? selectedTab else { return }
        if tab.gitPage == nil { tab.gitPage = GitPageModel() }
        tab.rightPane = tab.rightPane == .git ? .none : .git
        if !tab.gitPageVisible { tab.gitPage?.stopWatching() }
    }

    /// ⌘⇧E: editor panel.
    func toggleEditor(_ tab: Tab? = nil) {
        guard let tab = tab ?? selectedTab else { return }
        if tab.rightPane == .editor { tab.rightPane = .none; return }
        if tab.editor == nil { tab.editor = EditorModel(root: tab.pwd ?? tab.projectPath) }
        tab.gitPage?.stopWatching()
        tab.rightPane = .editor
    }

    /// ⌘⇧I: attachments panel.
    func toggleAttachments(_ tab: Tab? = nil) {
        guard let tab = tab ?? selectedTab, tab.sessionId != nil else { return }
        if tab.rightPane == .attachments { tab.rightPane = .none } else { tab.gitPage?.stopWatching(); tab.rightPane = .attachments }
    }

    /// PR refs known for a tab's session (from the transcript).
    func pullRequests(for tab: Tab) -> [PullRequestRef] {
        guard let id = tab.sessionId, let s = sessions.sessions[id] else { return [] }
        return s.pullRequests
    }

    /// ⌘⇧P: show the newest PR page, or hide it; `ref` picks a specific PR (footer chip).
    func togglePRPage(_ tab: Tab? = nil, ref: PullRequestRef? = nil) {
        guard let tab = tab ?? selectedTab else { return }
        let target = ref ?? pullRequests(for: tab).last
        guard let target else { return }
        if case .pr(let current) = tab.rightPane, current == target { tab.rightPane = .none; return }
        tab.gitPage?.stopWatching()
        tab.rightPane = .pr(target)
    }

    func tab(forSurface surface: GhosttySurfaceView) -> Tab? {
        tabs.first { $0.surface === surface || $0.panelSurface === surface }
    }

    var runningCount: Int { tabs.filter(\.isRunningClaude).count }

    enum CloseChoice { case close, background, cancel }

    /// Close sheet for one tab; offers Background when the session is idle at its prompt.
    func confirmCloseTab(_ tab: Tab) -> CloseChoice {
        let alert = NSAlert()
        alert.messageText = "Close this session?"
        let canBackground = tab.sessionId != nil && tab.state == .idle
        alert.informativeText = canBackground
            ? "Claude Code is still running. Close asks it to exit cleanly (you can resume later); Background keeps it running detached so you can attach again."
            : "Claude Code is still running in this tab. Close asks it to exit cleanly; you can resume the session later."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Close")
        if canBackground { alert.addButton(withTitle: "Background") }
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .close
        case .alertSecondButtonReturn: return canBackground ? .background : .cancel
        default: return .cancel
        }
    }

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
        var found = tab(for: event.sessionId)
        if found == nil, event.hookEventName == "SessionStart", let waiting = tabs.first(where: { $0.awaitingId && $0.sessionId != nil }) {
            // Fork / continue: adopt the id the CLI reports (ADR-063).
            waiting.kind = .session(event.sessionId)
            waiting.awaitingId = false
            let cwd = event.cwd ?? waiting.pwd ?? waiting.projectPath
            sessions.registerPending(id: event.sessionId, cwd: cwd, title: waiting.title)
            var resume = ClaudeLaunch(mode: .resume(id: event.sessionId, fork: false), settingsFilePath: hooks.settingsFileURL.path)
            resume.mcpConfigPath = mcp?.configPath(for: event.sessionId)
            waiting.lastResume = resume
            found = waiting
        }
        guard let tab = found else {
            Self.log.debug("hook for unknown session \(event.sessionId.rawValue, privacy: .public): \(event.hookEventName, privacy: .public)")
            return
        }
        if event.hookEventName == "SessionEnd", tab.closingGracefully { tab.closingGracefully = false; close(tab, confirm: false); return }
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
        notifications.setBadge(tabs.filter { $0.unread || ($0.state?.isWaiting ?? false) }.count + history.entries.filter { !$0.read && $0.sessionId == nil }.count)
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
        let tab = tab(forSurface: surface)
        let isPanel = tab?.panelSurface === surface
        switch action {
        case .newTab, .newWindow, .newSplit: newShell(in: tab?.pwd); return true
        case .openURL(let url, _): NSWorkspace.shared.open(url); return true
        case .ringBell:
            if let tab, tab.id != selectedTabId || !NSApp.isActive {
                notify(tab, sessionId: tab.sessionId, title: tab.title, body: "Rang the bell", kind: .bell)
            } else { NSSound.beep() }
            return true
        case .setTitle(let t): if let tab, tab.kind == .shell, !isPanel { tab.title = t.isEmpty ? "Shell" : t }; return true
        case .pwd(let p):
            if let tab, !isPanel {
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
        guard let tab = tab(forSurface: surface) else { return }
        if tab.panelSurface === surface { closePanel(tab) } else { close(tab, confirm: processAlive) }
    }

    private func closePanel(_ tab: Tab) {
        tab.panelSurface?.free()
        tab.panelSurface = nil
        tab.panelVisible = false
        DispatchQueue.main.async { tab.surface.window?.makeFirstResponder(tab.surface) }
    }

    func surfaceChildExited(_ surface: GhosttySurfaceView, exitCode: Int32?) {
        guard let tab = tab(forSurface: surface) else { return }
        if tab.panelSurface === surface { closePanel(tab); return }
        if tab.detaching { close(tab, confirm: false); Task { await backgroundAgents?.refresh() }; return }
        tab.childExited = true
        if tab.state != nil { tab.state = .exited }
        updateBadge()
    }
}
