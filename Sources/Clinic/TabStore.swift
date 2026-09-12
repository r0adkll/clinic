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
    /// The window showing this tab (ADR-072).
    var windowId: UUID
    let surface: GhosttySurfaceView
    /// Replay tabs carry a model instead of a live process (ADR-059).
    var replay: ReplayModel?
    /// Persistent AppKit host for the tab's surfaces and right page (never re-parented by SwiftUI).
    @ObservationIgnored let contentView: TabContentView
    var state: SessionState?
    var unread = false
    var errorBadge = false
    /// The name a tab opened with: the whole story for shells, and the stand-in for a session
    /// with nothing on disk yet (a new session, a fork awaiting its id). See `title`.
    var openedTitle: String
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
    /// Right-hand panel: a strip of panes — terminal, git, PRs, files, images — with one on screen (ADR-079).
    let panel = SidePanel()
    /// The panel's shell pane surface, when one is open (ADR-079 replaces the below-terminal panel of ADR-046).
    var panelSurface: GhosttySurfaceView? { panel.pane(.terminal)?.terminal }

    /// The store the tab's title comes from (ADR-031). Held strongly: `SessionStore` never refers back.
    @ObservationIgnored private let sessions: SessionStore

    init(kind: Kind, projectPath: String, surface: GhosttySurfaceView, title: String, windowId: UUID, sessions: SessionStore) {
        self.kind = kind; self.projectPath = projectPath; self.surface = surface; self.openedTitle = title; self.windowId = windowId
        self.sessions = sessions
        self.contentView = TabContentView(surface: surface)
        self.state = { if case .session = kind { return .launching } else { return nil } }()
    }

    /// ADR-031: names update live. Session tabs read the store on every access, so a rename, an
    /// `ai-title` record the tail scan picks up, or `set_session_title` reaches the tab bar at the
    /// same moment as the sidebar. Setting one (an OSC title from a shell) writes `openedTitle`.
    var title: String {
        get {
            switch kind {
            case .session(let id): if let s = sessions.sessions[id] { return sessions.displayName(for: s) }
            case .replay(let id): if let s = sessions.sessions[id] { return "Replay: " + sessions.displayName(for: s) }
            case .shell: break
            }
            return openedTitle
        }
        set { openedTitle = newValue }
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
    private var drafts: [String: NewSessionDraft] = [:]

    // MARK: Windows (ADR-072)

    /// The window the system opens at launch; others are opened by value.
    static let primaryWindowId = UUID()
    private(set) var windows: [WindowState] = []
    /// The last key window; commands and new tabs go here.
    var activeWindowId: UUID?

    var activeWindow: WindowState {
        if let id = activeWindowId, let w = windows.first(where: { $0.id == id }) { return w }
        return windows.first ?? windowState(id: Self.primaryWindowId)
    }

    /// The state for a window id, created on first sight.
    func windowState(id: UUID) -> WindowState {
        if let w = windows.first(where: { $0.id == id }) { return w }
        let w = WindowState(id: id, isPrimary: id == Self.primaryWindowId)
        w.store = self
        windows.append(w)
        return w
    }

    func window(of tab: Tab) -> WindowState { windowState(id: tab.windowId) }
    func tabs(in window: WindowState) -> [Tab] { tabs.filter { $0.windowId == window.id } }
    func selectedTab(in window: WindowState) -> Tab? { tabs.first { $0.id == window.selectedTabId } }

    /// Selection and draft of the active window; existing call sites keep working.
    var selectedTabId: UUID? {
        get { activeWindow.selectedTabId }
        set { activeWindow.selectedTabId = newValue }
    }
    var editingDraft: NewSessionDraft? {
        get { activeWindow.editingDraft }
        set { activeWindow.editingDraft = newValue }
    }

    /// Called once the SwiftUI hierarchy of a window has an NSWindow: close handling, key tracking, geometry.
    func bind(_ nsWindow: NSWindow, to window: WindowState) {
        guard window.nsWindow !== nsWindow else { return }
        window.nsWindow = nsWindow
        nsWindow.isRestorable = false
        let lifecycle = window.lifecycle ?? WindowLifecycle(tabs: self, window: window)
        window.lifecycle = lifecycle
        lifecycle.attach(to: nsWindow)
        if window.isPrimary {
            nsWindow.setFrameAutosaveName("ClinicMainWindow")
        } else if let key = windows.first(where: { $0.id != window.id && $0.nsWindow?.isKeyWindow == true })?.nsWindow
                    ?? windows.first(where: { $0.id != window.id && $0.nsWindow?.isVisible == true })?.nsWindow {
            let rect = NSRect(x: key.frame.minX + 28, y: key.frame.minY - 28, width: key.frame.width, height: key.frame.height)
            nsWindow.setFrame(nsWindow.constrainFrameRect(rect, to: key.screen), display: true)
        }
        if nsWindow.isKeyWindow { activeWindowId = window.id }
        for o in window.observers { NotificationCenter.default.removeObserver(o) }
        window.observers = [
            NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nsWindow, queue: .main) { [weak self, weak window] _ in
                MainActor.assumeIsolated { if let window { self?.activeWindowId = window.id } }
            },
        ]
    }

    /// Registers a window and asks the active RootView to open it (`openWindow` is a view-side action).
    @discardableResult
    func openNewWindow() -> WindowState {
        let w = windowState(id: UUID())
        NotificationCenter.default.post(name: .clinicOpenWindow, object: w.id)
        return w
    }

    func moveToNewWindow(_ tab: Tab) { move(tab, to: openNewWindow()) }

    func move(_ tab: Tab, to target: WindowState) {
        let from = window(of: tab)
        guard from.id != target.id else { return }
        tab.windowId = target.id
        if from.selectedTabId == tab.id { from.selectedTabId = tabs(in: from).last?.id }
        target.selectedTabId = tab.id
        selectionChanged(in: from)
        target.nsWindow?.makeKeyAndOrderFront(nil)
    }

    /// A window that is not the last one is closing: its tabs move to another window, nothing is stopped.
    func windowWillClose(_ window: WindowState) {
        guard windows.count > 1, let target = windows.first(where: { $0.id != window.id && $0.nsWindow?.isVisible == true }) ?? windows.first(where: { $0.id != window.id }) else { return }
        let moving = tabs(in: window)
        for tab in moving { tab.windowId = target.id }
        if target.selectedTabId == nil, let last = moving.last { target.selectedTabId = last.id }
        selectionChanged(in: target)
        for o in window.observers { NotificationCenter.default.removeObserver(o) }
        window.observers = []
        windows.removeAll { $0.id == window.id }
        if activeWindowId == window.id { activeWindowId = target.id }
    }

    /// "Looking at it" (ADR-066): app active, the tab's window is the active one, and the tab is selected there.
    func isFrontAndSelected(_ tab: Tab) -> Bool {
        NSApp.isActive && activeWindowId == tab.windowId && window(of: tab).selectedTabId == tab.id
    }

    let sessions: SessionStore
    let hooks: HookService
    let notifications: NotificationService
    let history: NotificationStore
    /// Which file a notification sounds with, and the rotation over them (ADR-097).
    let sounds = NotificationSoundPlayer()
    /// Turn snapshots for the diff panel (ADR-080).
    let snapshots = SnapshotService()
    /// Run configurations and their runs (ADR-122).
    let runs: RunStore
    /// Set by the app after construction (ADR-056, ADR-061).
    var mcp: MCPToolService?
    var backgroundAgents: BackgroundAgentsService?
    /// Set by the app so hook events can reach scheduled runs (ADR-095).
    weak var automations: AutomationsModel?
    /// Set by the app so the end of a turn re-reads that session's pull requests (ADR-127).
    weak var prs: PRStore?

    init(sessions: SessionStore, hooks: HookService, notifications: NotificationService, history: NotificationStore) {
        self.sessions = sessions; self.hooks = hooks; self.notifications = notifications; self.history = history
        self.runs = RunStore(sessions: sessions)
        let primary = WindowState(id: Self.primaryWindowId, isPrimary: true)
        primary.store = self
        windows = [primary]
        runs.tabs = self
    }

    /// Single router for attention (ADR-066): history always; then by focus — looking at it: nothing more;
    /// app active elsewhere: in-app card (+ sound pref); app inactive: system notification. Muted sessions get history only.
    func notify(_ tab: Tab?, sessionId: SessionID?, title: String, body: String, kind: NotificationStore.Entry.Kind,
                url: URL? = nil, pullRequest: PullRequestRef? = nil) {
        let entry = history.record(sessionId: sessionId, title: title, body: body, kind: kind, url: url,
                                   pullRequest: pullRequest)
        if let sessionId, sessions.state.mutedSessions.contains(sessionId) { return }
        if let tab, isFrontAndSelected(tab) { return }
        if NSApp.isActive {
            history.showCard(entry)
            sounds.playForCard()
        } else {
            let silent = sounds.playForSystemNotification()
            notifications.post(sessionId: sessionId ?? SessionID(UUID().uuidString), title: title, body: body,
                               silent: silent, pullRequest: pullRequest?.url)
        }
        tab?.unread = true
        updateBadge()
    }

    private func notify(_ tab: Tab, sessionId: SessionID, body: String, kind: NotificationStore.Entry.Kind) {
        notify(tab, sessionId: sessionId, title: tab.title, body: body, kind: kind)
    }

    var selectedTab: Tab? { selectedTab(in: activeWindow) }

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
        hooks.onEvent = { [weak self] event in
            self?.handle(hookEvent: event)
            // `--bg` refuses a pre-assigned id, so an automation run learns its session id here
            // (ADR-095). Kept out of `handle` because it is not part of tab state.
            self?.automations?.handle(hookEvent: event)
        }
        notifications.onActivate = { [weak self] id, ref in self?.reveal(sessionId: id, pullRequest: ref) }
        // ADR-080 retention: once the launch has settled, so restored sessions count as live.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            self?.snapshots.sweep()
        }
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
        if let existing = tab(for: summary.id) { select(existing); return }
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
    /// `inNewWindow` puts the screen in a fresh window (ADR-072).
    func startNewSession(projectPath: String? = nil, inNewWindow: Bool = false) {
        guard let path = projectPath ?? selectedTab?.projectPath ?? editingDraft?.projectPath else {
            NotificationCenter.default.post(name: .clinicNewSession, object: nil); return
        }
        let window = inNewWindow ? openNewWindow() : activeWindow
        if let d = drafts[path] { window.editingDraft = d; return }
        let d = NewSessionDraft(projectPath: path, model: sessions.state.lastModelByProject[path], worktree: sessions.state.lastWorktreeByProject[path] ?? false,
                                worktreeBase: worktreeBase(for: path))
        drafts[path] = d
        window.editingDraft = d
    }

    /// The composer pre-filled from a task (ADR-114). Replaces the project's unsent draft: this is an
    /// explicit request for a new one.
    func startNewSession(projectPath: String, prompt: String, worktreeName: String?, workItem: WorkItemRef?) {
        let d = NewSessionDraft(projectPath: projectPath, model: sessions.state.lastModelByProject[projectPath], worktree: worktreeName != nil,
                                worktreeBase: worktreeBase(for: projectPath))
        d.prompt = prompt
        d.worktreeName = worktreeName ?? ""
        d.workItem = workItem
        drafts[projectPath] = d
        activeWindow.editingDraft = d
    }

    private func window(showing d: NewSessionDraft) -> WindowState? { windows.first { $0.editingDraft?.id == d.id } }

    func discardDraft(_ d: NewSessionDraft) {
        drafts[d.projectPath] = nil
        if let w = window(showing: d) { w.editingDraft = nil; w.selectedTabId = tabs(in: w).last?.id }
    }

    func closeDraftScreen() {
        let w = activeWindow
        w.editingDraft = nil
        w.selectedTabId = tabs(in: w).last?.id
    }

    /// Sends the composer. A worktree from a named branch is created first, with the composer still on
    /// screen, so a git failure lands in the worktree row instead of in a tab (ADR-118).
    func sendDraft(_ d: NewSessionDraft, empty: Bool = false) {
        guard !d.isStarting else { return }
        let trimmed = empty ? nil : d.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = (trimmed?.isEmpty ?? true) ? nil : trimmed
        let worktree = d.worktree && !SessionStore.isChats(d.projectPath)
        guard worktree, case .branch(let ref) = d.worktreeBase else {
            closeDraft(d)
            launchNewSession(projectPath: d.projectPath, model: d.resolvedModel, worktree: worktree, worktreeName: worktree ? d.worktreeName : nil,
                             worktreeBaseRef: worktree ? d.worktreeBase.cliBaseRef : nil, effort: d.resolvedEffort, prompt: prompt, workItem: d.workItem)
            return
        }
        d.isStarting = true
        d.startError = nil
        Task {
            do {
                let plan = try await prepareWorktree(projectPath: d.projectPath, ref: ref, name: d.worktreeName)
                d.isStarting = false
                // Discarded while git ran: the worktree stays, reusable by name, and nothing launches.
                guard drafts[d.projectPath]?.id == d.id else { return }
                closeDraft(d)
                launchNewSession(projectPath: d.projectPath, model: d.resolvedModel, worktree: true, worktreeName: plan.name,
                                 worktreeBaseRef: d.worktreeBase.cliBaseRef, effort: d.resolvedEffort, prompt: prompt, workItem: d.workItem)
            } catch {
                d.isStarting = false
                d.startError = Self.describeWorktreeFailure(error)
            }
        }
    }

    private func closeDraft(_ d: NewSessionDraft) {
        drafts[d.projectPath] = nil
        let window = window(showing: d) ?? activeWindow
        window.editingDraft = nil
        if activeWindowId != window.id { activeWindowId = window.id }
    }

    // MARK: Worktree base (ADR-118)

    /// Where a project's new worktrees branch from: its own choice, else the Settings default.
    func worktreeBase(for projectPath: String) -> WorktreeBase {
        sessions.state.worktreeBaseByProject[projectPath] ?? Prefs.defaultWorktreeBase
    }

    /// Nil returns the project to the Settings default.
    func setWorktreeBase(_ base: WorktreeBase?, for projectPath: String) {
        sessions.update { $0.worktreeBaseByProject[projectPath] = base }
    }

    /// Creates `.claude/worktrees/<name>` from `ref` for `-w <name>` to adopt, unless it already exists.
    private func prepareWorktree(projectPath: String, ref: String, name: String) async throws -> WorktreePlan {
        guard let repo = await GitRepository.discover(from: projectPath) else {
            throw GitError(command: "worktree add", exitCode: 128, stderr: "", description: "\(TabFooter.abbreviate(projectPath)) is not a git repository.")
        }
        let plan = WorktreePlan.make(ref: ref, name: name, repoRoot: repo.root, suffix: WorktreePlan.randomSuffix())
        try await repo.createWorktree(plan)
        return plan
    }

    /// Git's own sentence ("a branch named 'worktree-x' already exists"), not the whole argv.
    static func describeWorktreeFailure(_ error: any Error) -> String {
        guard let e = error as? GitError else { return "\(error)" }
        let line = e.stderr.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
        guard let line else { return e.description }
        for prefix in ["fatal: ", "error: "] where line.hasPrefix(prefix) { return String(line.dropFirst(prefix.count)) }
        return line
    }

    /// New session with a pre-assigned id (ADR-017). `prompt` becomes the first turn (ADR-071).
    /// `workItem` records the task it was started from (ADR-114). `worktreeBase` defaults to the
    /// project's (ADR-118); a named branch creates the worktree before the tab opens.
    func newSession(projectPath: String, model: String?, worktree: Bool, worktreeName: String? = nil, worktreeBase: WorktreeBase? = nil,
                    effort: String? = nil, prompt: String? = nil, workItem: WorkItemRef? = nil) {
        let base = worktreeBase ?? self.worktreeBase(for: projectPath)
        guard worktree, case .branch(let ref) = base else {
            launchNewSession(projectPath: projectPath, model: model, worktree: worktree, worktreeName: worktreeName,
                             worktreeBaseRef: worktree ? base.cliBaseRef : nil, effort: effort, prompt: prompt, workItem: workItem)
            return
        }
        Task {
            do {
                let plan = try await prepareWorktree(projectPath: projectPath, ref: ref, name: worktreeName ?? "")
                launchNewSession(projectPath: projectPath, model: model, worktree: true, worktreeName: plan.name,
                                 worktreeBaseRef: base.cliBaseRef, effort: effort, prompt: prompt, workItem: workItem)
            } catch {
                let alert = NSAlert()
                alert.messageText = "Couldn't create a worktree from \(ref)"
                alert.informativeText = Self.describeWorktreeFailure(error)
                alert.alertStyle = .warning
                alert.runModal()
            }
        }
    }

    private func launchNewSession(projectPath: String, model: String?, worktree: Bool, worktreeName: String?, worktreeBaseRef: String?,
                                  effort: String?, prompt: String?, workItem: WorkItemRef?) {
        let id = SessionID.generate()
        var launch = ClaudeLaunch(mode: .new(id: id), model: model, effort: effort, worktree: worktree,
                                  settingsFilePath: hooks.settingsFileURL(worktreeBaseRef: worktree ? worktreeBaseRef : nil).path, prompt: prompt)
        launch.worktreeName = worktreeName
        launch.mcpConfigPath = mcp?.configPath(for: id)
        guard let tab = makeTab(kind: .session(id), cwd: projectPath, projectPath: projectPath, initialInput: launch.shellLine, title: "New session") else { return }
        var resume = ClaudeLaunch(mode: .resume(id: id, fork: false), settingsFilePath: hooks.settingsFileURL.path)
        resume.mcpConfigPath = launch.mcpConfigPath
        tab.lastResume = resume
        tab.model = model
        tab.effort = effort
        sessions.registerPending(id: id, cwd: projectPath)
        if let workItem { sessions.linkWorkItem(workItem, to: id) }
        sessions.update { s in
            if let model { s.lastModelByProject[projectPath] = model } else { s.lastModelByProject[projectPath] = nil }
            s.lastWorktreeByProject[projectPath] = worktree
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
        let tab = Tab(kind: .replay(summary.id), projectPath: ProjectGrouping.projectPath(forCwd: summary.cwd ?? ""), surface: surface, title: "Replay: " + sessions.displayName(for: summary), windowId: activeWindow.id, sessions: sessions)
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
            let tab = Tab(kind: kind, projectPath: projectPath, surface: surface, title: title, windowId: activeWindow.id, sessions: sessions)
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

    /// Occlusion follows each window's selection (ADR-019); called by `WindowState` when its selection changes.
    func selectionChanged(in window: WindowState) {
        for t in tabs(in: window) {
            let hidden = (t.id != window.selectedTabId)
            t.surface.isOccluded = hidden || t.panel.isZoomed
            t.panelSurface?.isOccluded = hidden || !t.panel.isFront(.terminal)
        }
        if let tab = selectedTab(in: window) { runs.claim(for: tab) }
        runs.syncOcclusion()
        if let tab = selectedTab(in: window) {
            tab.unread = false
            if let id = tab.sessionId { history.markRead(sessionId: id) }
            if let id = tab.sessionId { sessions.update { $0.selectedSessionId = id } }
            updateBadge()
        }
    }

    /// Selects a tab in its own window and brings that window forward (ADR-041 across windows).
    func select(_ tab: Tab) {
        let w = window(of: tab)
        w.selectedTabId = tab.id
        if activeWindowId != w.id || w.nsWindow?.isKeyWindow == false { w.nsWindow?.makeKeyAndOrderFront(nil) }
    }

    /// Brings a session to the front. `pullRequest` also opens that PR's pane, so clicking a checks
    /// notification lands on the checks rather than on whatever the tab was showing (ADR-128).
    func reveal(sessionId: SessionID, pullRequest: PullRequestRef? = nil) {
        if let tab = tab(for: sessionId) { select(tab) }
        else if let summary = sessions.sessions[sessionId] { open(session: summary) }
        guard let ref = pullRequest, let tab = tab(for: sessionId) else { return }
        showPane(.pr(ref), in: tab)
    }

    func selectNext(_ delta: Int) {
        let w = activeWindow, list = tabs(in: w)
        guard !list.isEmpty else { return }
        let idx = list.firstIndex { $0.id == w.selectedTabId } ?? 0
        w.selectedTabId = list[((idx + delta) % list.count + list.count) % list.count].id
    }

    func selectIndex(_ i: Int) { let list = tabs(in: activeWindow); if list.indices.contains(i) { activeWindow.selectedTabId = list[i].id } }

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
        let w = window(of: tab)
        runs.tabClosed(tab)
        tabs.removeAll { $0.id == tab.id }
        if w.selectedTabId == tab.id { w.selectedTabId = tabs(in: w).last?.id }
        tab.surface.free()
        tab.panel.tearDown()
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

    // MARK: Right-hand panel (ADR-079)

    /// Quick action / shortcut: show the panel with this pane in front — open it if it is not there,
    /// front it if it is, show the panel if it is hidden. Never a toggle: hiding is its own action.
    func showPane(_ kind: PanelPane.Kind, in tab: Tab? = nil) {
        guard let tab = tab ?? selectedTab else { return }
        if let existing = tab.panel.pane(kind) {
            tab.panel.select(existing)
        } else if let pane = makePane(kind, in: tab) {
            tab.panel.append(pane)
            tab.panel.isVisible = true
        } else {
            return
        }
        focusPanel(tab)
    }

    /// The one control that hides the panel: the tab bar button, the strip's chevron, ⌘⌥J.
    func togglePanelVisibility(_ tab: Tab? = nil) {
        guard let tab = tab ?? selectedTab else { return }
        tab.panel.isVisible.toggle()
        focusPanel(tab)
    }

    /// ⌘⌥⇧J: the panel fills the tab, with the agent surface hidden behind it (ADR-081). Zooming a
    /// hidden panel shows it, so the action always lands somewhere.
    func togglePanelZoom(_ tab: Tab? = nil) {
        guard let tab = tab ?? selectedTab else { return }
        if tab.panel.isZoomed {
            tab.panel.isZoomed = false
        } else {
            tab.panel.isVisible = true
            tab.panel.isZoomed = true
        }
        focusPanel(tab)
    }

    /// ⌘⌃E: the front browser's list column — the Files pane's tree or the Images pane's thumbnails.
    /// One key rather than one per pane, because ADR-102 made it one control; each pane keeps its own
    /// preference, for the reason ADR-091 gives (wanting one list open is not wanting them all open).
    func toggleBrowserList() {
        if isImagesPaneFront { ImagePrefs.shared.showList.toggle() } else { EditorPrefs.shared.showTree.toggle() }
    }

    /// ⌘W. Clinic's own auxiliary windows — a file window (ADR-081), an image window (ADR-107) — are
    /// not tabs, and while one of them is key it is what ⌘W should close. Without this the command
    /// fell straight through to the session tab behind it and asked whether to close a *running
    /// session*, from a keystroke the reader meant for the picture in front of them (found 2026-09-10).
    func closeFront() {
        if let key = NSApp.keyWindow, FileWindowController.owns(key) || ImageWindowController.owns(key) {
            key.performClose(nil)
            return
        }
        if editingDraft != nil { closeDraftScreen() } else { closeSelected() }
    }

    /// ⌘Y: Quick Look whatever the front Images pane has selected. The pane's own space bar needs
    /// the pane to have the keyboard; this is the path from the menu bar, which never does (ADR-107).
    func quickLookFrontImage() {
        guard let tab = selectedTab, let gallery = tab.panel.pane(.attachments)?.images,
              let id = tab.sessionId else { return }
        let rows = gallery.rows(Array((sessions.state.attachments[id] ?? []).reversed()))
        ImageQuickLook.shared.toggle(paths: rows.map(\.path), showing: gallery.selection(in: rows)?.path)
    }

    /// True when a Files pane is the one on screen, so the tree toggle knows whether it applies.
    var isFilesPaneFront: Bool { selectedTab?.panel.isFront(.files) ?? false }
    var isImagesPaneFront: Bool { selectedTab?.panel.isFront(.attachments) ?? false }
    var canToggleBrowserList: Bool { isFilesPaneFront || isImagesPaneFront }
    var browserListShown: Bool { isImagesPaneFront ? ImagePrefs.shared.showList : EditorPrefs.shared.showTree }

    func selectPane(_ pane: PanelPane, in tab: Tab) {
        tab.panel.select(pane)
        focusPanel(tab)
    }

    func closePane(_ pane: PanelPane, in tab: Tab) {
        tab.panel.close(pane)
        if case .run(let key) = pane.kind { runs.paneClosed(key, in: tab) }
        focusPanel(tab)
    }

    /// The strip's *Close Others*: through `closePane`, so a run pane gives its surface back (ADR-122).
    func closeOtherPanes(_ keep: PanelPane, in tab: Tab) {
        for pane in tab.panel.panes where pane.id != keep.id { closePane(pane, in: tab) }
    }

    /// Opens a run's pane in a tab — fronted, or added behind the pane on screen (a re-run after a turn
    /// never fronts anything, ADR-122).
    func openRunPane(_ key: RunKey, in tab: Tab, front: Bool) {
        if !front {
            // Never shows the panel or moves the keyboard: Claude started this, or a turn ended, and
            // the user may be typing into the session. The toolbar pill and the chip carry the news.
            if !tab.panel.isOpen(.run(key)) { tab.panel.append(PanelPane(kind: .run(key)), select: tab.panel.isEmpty) }
            return
        }
        if front { showPane(.run(key), in: tab) }
    }

    /// ⌘⌃] / ⌘⌃[: move through the panel's tabs.
    func cyclePanelTab(_ delta: Int, in tab: Tab? = nil) {
        guard let tab = tab ?? selectedTab, tab.panel.isVisible else { return }
        tab.panel.cycle(by: delta)
        focusPanel(tab)
    }

    /// ⌘⌃W: close the panel tab on screen.
    func closeFrontPane(in tab: Tab? = nil) {
        guard let tab = tab ?? selectedTab, let pane = tab.panel.selected else { return }
        closePane(pane, in: tab)
    }

    /// Pane kinds the panel's "+" menu can still add for this tab.
    func availablePanes(for tab: Tab) -> [PanelPane.Kind] {
        var kinds: [PanelPane.Kind] = [.terminal, .diff, .files]
        if tab.sessionId != nil { kinds.append(.attachments) }
        kinds += pullRequests(for: tab).map { PanelPane.Kind.pr($0) }
        if let checkout = runs.checkout(for: tab) {
            kinds += runs.runs(inCheckout: checkout).filter { $0.surface != nil }.map { PanelPane.Kind.run($0.key) }
        }
        return kinds.filter { !tab.panel.isOpen($0) }
    }

    /// Chip and menu label for a pane: live facts (branch, image count) win over the kind's default.
    func paneTitle(_ kind: PanelPane.Kind, in tab: Tab) -> String {
        switch kind {
        case .diff: return tab.gitBranch ?? "Diff"
        case .attachments:
            let count = tab.sessionId.flatMap { sessions.state.attachments[$0]?.count } ?? 0
            return count > 0 ? "Images (\(count))" : "Images"
        case .run(let key): return runs.run(forKey: key)?.name ?? key.configId
        default: return kind.defaultTitle
        }
    }

    /// Builds a pane's long-lived content; nil when it cannot exist (no runtime, no session).
    private func makePane(_ kind: PanelPane.Kind, in tab: Tab) -> PanelPane? {
        let pane = PanelPane(kind: kind)
        switch kind {
        case .terminal:
            guard let runtime else { return nil }
            var options = GhosttySurfaceOptions()
            options.workingDirectory = tab.pwd ?? tab.projectPath
            options.environment = ["CLINIC": "1", "CLINIC_PANEL": "1"]
            do {
                let surface = try GhosttySurfaceView(runtime: runtime, options: options)
                surface.delegate = self
                pane.terminal = surface
            } catch {
                Self.log.error("panel surface creation failed: \(error, privacy: .public)")
                lastSurfaceError = "\(error)"
                return nil
            }
        case .diff:
            pane.diff = DiffPanelModel()
        case .files:
            pane.editor = EditorModel(root: tab.pwd ?? tab.projectPath)
        case .attachments:
            guard tab.sessionId != nil else { return nil }
            pane.images = ImageGallery()
        case .pr, .run:
            break
        }
        return pane
    }

    /// Keeps both surfaces' occlusion and the first responder in step with what the panel is showing.
    /// A zoomed panel hides the agent surface, so it stops rendering and must not keep the keyboard.
    private func focusPanel(_ tab: Tab) {
        let unselected = window(of: tab).selectedTabId != tab.id
        tab.panelSurface?.isOccluded = unselected || !tab.panel.isFront(.terminal)
        tab.surface.isOccluded = unselected || tab.panel.isZoomed
        runs.claim(for: tab)
        runs.syncOcclusion()
        let frontRun: GhosttySurfaceView? = {
            guard tab.panel.isVisible, case .run(let key)? = tab.panel.selected?.kind, let run = runs.run(forKey: key),
                  run.hostTabId == tab.id else { return nil }
            return run.surface
        }()
        let target: GhosttySurfaceView? = if tab.panel.isFront(.terminal) { tab.panelSurface }
                                          else if let frontRun { frontRun }
                                          else if tab.panel.isZoomed { nil }
                                          else { tab.surface }
        let window = tab.surface.window
        DispatchQueue.main.async { window?.makeFirstResponder(target) }
    }

    /// ⌘J: the shell pane.
    func togglePanel(_ tab: Tab? = nil) { showPane(.terminal, in: tab) }

    /// ⌘⇧G: the git pane.
    func toggleDiffPanel(_ tab: Tab? = nil) { showPane(.diff, in: tab) }

    /// ⌘⇧E: the editor pane.
    func toggleEditor(_ tab: Tab? = nil) { showPane(.files, in: tab) }

    /// ⌘⇧I: the attachments pane.
    func toggleAttachments(_ tab: Tab? = nil) { showPane(.attachments, in: tab) }

    /// PR refs known for a tab's session (from the transcript).
    func pullRequests(for tab: Tab) -> [PullRequestRef] {
        guard let id = tab.sessionId, let s = sessions.sessions[id] else { return [] }
        return s.pullRequests
    }

    /// ⌘⇧P: the newest PR's pane; `ref` picks a specific PR (footer chip). Each PR gets its own pane.
    func togglePRPage(_ tab: Tab? = nil, ref: PullRequestRef? = nil) {
        guard let tab = tab ?? selectedTab, let target = ref ?? pullRequests(for: tab).last else { return }
        showPane(.pr(target), in: tab)
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
        // ADR-080: turn boundaries become snapshots. Before any early return below, and before the
        // SessionEnd close path so a closing session still gets its last turn sealed.
        snapshots.handle(event, cwd: tab.pwd ?? tab.projectPath)
        let endedTurn = event.hookEventName == "Stop"
        if endedTurn { runs.turnEnded(in: tab, snapshots: snapshots) }
        if event.hookEventName == "SessionEnd", tab.closingGracefully { tab.closingGracefully = false; close(tab, confirm: false); return }
        if let cwd = event.cwd, event.hookEventName == "SessionStart" || event.hookEventName == "CwdChanged" { tab.pwd = cwd }
        if event.hookEventName == "CwdChanged" { snapshots.forget(session: event.sessionId) }
        if let path = event.transcriptPath, event.hookEventName == "SessionStart" || event.hookEventName == "Stop" || event.hookEventName == "PostModelSwitch" {
            Task {
                await sessions.refresh(transcriptPath: path)
                self.refreshFooter(tab)
                // A turn that pushed, opened a pull request or answered a review has changed what the
                // panel shows, and this is the moment we know it ended (ADR-127). After the transcript
                // re-read, not before: the refs come from the transcript, so a turn that *opened* the
                // PR is bumped by the same signal that discovers it.
                if endedTurn { self.prs?.bump(self.pullRequests(for: tab)) }
            }
        } else if endedTurn {
            prs?.bump(pullRequests(for: tab))
        } else if event.hookEventName == "CwdChanged" {
            refreshFooter(tab)
        }
        guard let old = tab.state, let new = SessionStateMachine.reduce(old, event: event) else { return }
        tab.state = new
        tab.errorBadge = (event.hookEventName == "StopFailure")
        let isFrontAndSelected = isFrontAndSelected(tab)
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
            if let tab, !isFrontAndSelected(tab) {
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
        if let pane = tab.panel.pane(.terminal) { tab.panel.close(pane) }
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
