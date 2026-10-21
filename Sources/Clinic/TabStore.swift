import AppKit
import Observation
import os
import ClinicCore
import GhosttyBridge

/// An open Session or shell inside the window (ADR-025). Owns its surface for its whole life (ADR-019).
@MainActor
@Observable
final class Tab: Identifiable {
    /// A session, or a session's transcript replayed while it is not running (ADR-221). Terminals live only
    /// inside sessions, as tabs of their workspace.
    enum Kind: Hashable { case session(SessionID), replay(SessionID) }

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
    var state: SessionState? {
        didSet {
            if state != .waitingForInput { waitingOn = nil }
            if state != oldValue { stateSince = Date() }
        }
    }
    /// When `state` last changed. A transcript record only ends a state that began before it (ADR-166).
    @ObservationIgnored private(set) var stateSince = Date()
    /// The terminal's OSC 9;4 report, and whether it has ever said busy: a CLI that never does sends one
    /// `remove` at startup, which is then no evidence of anything (ADR-166).
    @ObservationIgnored var progressBusy = false
    @ObservationIgnored var sawProgressBusy = false
    /// The terminal's verdict waiting out its grace period.
    @ObservationIgnored var pendingVerdict: DispatchWorkItem?
    /// Ids this tab's process has had: `/clear` starts a new one, but the MCP shim was launched with the
    /// first and keeps sending it (ADR-166).
    @ObservationIgnored var formerSessionIds: Set<SessionID> = []
    /// `SessionEnd(reason: clear)` arrived; the `SessionStart` that follows carries the tab's next id.
    @ObservationIgnored var clearedAt: Date?
    /// The notification type behind `waitingForInput`: `idle_prompt` still means Claude is at its prompt.
    var waitingOn: String?
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
    /// The parent to record once a fork learns its id (ADR-181), and whether it reports back (ADR-182).
    @ObservationIgnored var pendingParent: SessionParent?
    @ObservationIgnored var pendingReporting = false
    /// A fork's sound pack, picked in the composer, held until the CLI reports the fork's id (ADR-202).
    @ObservationIgnored var pendingSoundPack: String?
    /// When the turn now running began, for the long-turn line (ADR-203).
    @ObservationIgnored var turnStartedAt: Date?
    /// Close the tab as soon as `SessionEnd` arrives (graceful close, ADR-063).
    var closingGracefully = false
    /// The answer to press into the CLI's worktree exit dialog once it shows, the task watching the
    /// screen for it, and when it was pressed, which restarts the graceful close's clock (ADR-190).
    @ObservationIgnored var worktreeExitAnswer: WorktreeExitAnswer?
    @ObservationIgnored var worktreeExitWatcher: Task<Void, Never>?
    @ObservationIgnored var worktreeAnsweredAt: Date?
    /// Text to type once the shell shows its first prompt (ADR-016). Sent on the first `pwd` report or after a short fallback delay.
    var pendingInput: String?
    var gitBranch: String?
    var model: String?
    var effort: String?
    /// The CLI's latest status line input: context percentage, live model and effort (ADR-157). Nil for
    /// an attached session, which `claude attach` launches without Clinic's settings.
    var statusLine: StatusLineReport?
    /// The session's two tab areas (ADR-212). `main` holds the tabs added beside Claude, who is pinned
    /// first and in front whenever no pane is selected there; `panel` is the right panel (ADR-079).
    let main = SidePanel(isMain: true)
    let panel = SidePanel()
    enum Area { case main, right }
    /// The area the reader last acted in: it takes the keyboard when the tab is focused (ADR-212).
    var focusedArea: Area = .main
    func group(_ area: Area) -> SidePanel { area == .main ? main : panel }
    func area(of pane: PanelPane) -> Area? { main.contains(pane) ? .main : panel.contains(pane) ? .right : nil }
    /// Every pane in the workspace, main area first.
    var allPanes: [PanelPane] { main.panes + panel.panes }
    func panes(_ kind: PanelPane.Kind) -> [PanelPane] { allPanes.filter { $0.kind == kind } }
    /// The pane of this kind a quick action means, in either area: the one fronted last (ADR-198).
    func pane(_ kind: PanelPane.Kind) -> PanelPane? { SidePanel.mostRecent(of: panes(kind)) }
    func isOpen(_ kind: PanelPane.Kind) -> Bool { pane(kind) != nil }
    /// Claude's surface is what the main area shows.
    var isClaudeInFront: Bool { main.selectedId == nil }
    /// On screen in either area: the right panel's front while it shows, or the main area's.
    func isFront(_ kind: PanelPane.Kind) -> Bool { panel.isFront(kind) || main.isFront(kind) }
    /// The panes on screen, the focused area's first: what the menu's pane verbs act on.
    var frontPanes: [PanelPane] {
        let right = panel.isVisible ? panel.selected : nil
        let left = main.selected
        return (focusedArea == .right ? [right, left] : [left, right]).compactMap { $0 }
    }
    var frontPane: PanelPane? { frontPanes.first }
    /// The lowest number no open pane of this kind holds, in either area (ADR-198).
    func nextOrdinal(for kind: PanelPane.Kind) -> Int {
        let taken = Set(panes(kind).map(\.ordinal))
        return (1...).first { !taken.contains($0) }!
    }
    /// The workspace's shell panes' surfaces — one per Terminal pane, of which there may be several (ADR-198).
    var panelSurfaces: [GhosttySurfaceView] { panes(.terminal).compactMap(\.terminal) }
    /// The Terminal pane hosting this surface, if it is one of the workspace's shells.
    func shellPane(for surface: GhosttySurfaceView) -> PanelPane? { panes(.terminal).first { $0.terminal === surface } }
    /// Only what is on screen renders (ADR-019): Claude while the main area shows it, and each area's
    /// front shell.
    func syncOcclusion(hidden: Bool) {
        surface.isOccluded = hidden || !isClaudeInFront || isReplay
        main.occludeShells(tabHidden: hidden)
        panel.occludeShells(tabHidden: hidden)
    }

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
            case .replay(let id): if let s = sessions.sessions[id] { return sessions.displayName(for: s) }
            }
            return openedTitle
        }
        set { openedTitle = newValue }
    }

    var sessionId: SessionID? { if case .session(let id) = kind { return id } else { return nil } }
    var isReplay: Bool { if case .replay = kind { return true } else { return false } }
    /// A typed line becomes Claude's next prompt: idle, including idle long enough for `idle_prompt`.
    var isAtPrompt: Bool { SessionStateMachine.acceptsPrompt(state, waitingOn: waitingOn) }
    var isRunningClaude: Bool { (state != nil && state != .exited && !childExited) || (isAttached && !childExited) }
    /// The level the CLI is using: the status line's, which names the default too and follows a typed
    /// `/effort`, else the one Clinic launched with or sent (ADR-195).
    var liveEffort: String? { statusLine?.effort ?? effort }
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

    /// Whether a tab is what its window is showing: selected, with no screen (a draft, Tasks…) over it.
    /// A tab's content view stays mounted while hidden (ADR-019), so its panes keep working — but only
    /// the tab on screen may move the window's keyboard or answer a window-wide shortcut (ADR-197).
    func isOnScreen(_ tab: Tab) -> Bool {
        let w = window(of: tab)
        return w.selectedTabId == tab.id && !w.isShowingScreen
    }

    let sessions: SessionStore
    let hooks: HookService
    let notifications: NotificationService
    let history: NotificationStore
    /// Which file a notification sounds with, and the rotation over them (ADR-097).
    let sounds = NotificationSoundPlayer()
    /// Turn snapshots for the diff panel (ADR-080).
    let snapshots = SnapshotService()
    /// Unsent composers kept across launches, and saved prompts (ADR-160).
    let composer = ComposerLibraryModel()
    /// Run configurations and their runs (ADR-122).
    let runs: RunStore
    /// Set by the app after construction (ADR-056, ADR-061).
    var mcp: MCPToolService?
    var backgroundAgents: BackgroundAgentsService?
    /// Child reports and their delivery (ADR-182).
    var reports: SessionReportService?
    /// Set by the app so hook events can reach scheduled runs (ADR-095).
    weak var automations: AutomationsModel?
    /// Set by the app so the end of a turn re-reads that session's pull requests (ADR-127).
    weak var prs: PRStore?
    /// Set by the app so a hook reads the session's transcript straight away (ADR-156).
    weak var activities: SessionActivityStore? {
        didSet { activities?.onChange = { [weak self] id, activity in self?.transcriptChanged(id, activity) } }
    }
    /// Set by the app so the status line's plan windows reach the usage panel (ADR-162).
    weak var usage: UsageService?
    /// Set by the app: OpenPeon packs voice the moments below, before any notification sound (ADR-199).
    weak var soundPacks: SoundPackStore?

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
    ///
    /// `witness` is what caused it, for the session's sound pack (ADR-199): a pack line, when there is
    /// one, plays even for the tab on screen, and takes the place of the notification's own sound.
    /// A moment with no session says which `project` it belongs to, and may carry a `pack` of its own,
    /// so it speaks with that project's voice rather than the default (ADR-206).
    func notify(_ tab: Tab?, sessionId: SessionID?, title: String, body: String, kind: NotificationStore.Entry.Kind,
                url: URL? = nil, pullRequest: PullRequestRef? = nil, witness: SoundWitness? = nil,
                project: String? = nil, pack: String? = nil) {
        let entry = history.record(sessionId: sessionId, title: title, body: body, kind: kind, url: url,
                                   pullRequest: pullRequest)
        // What Clinic said and about which session: the history is in memory only, so this is the record.
        Self.log.info("attention for \(sessionId?.rawValue ?? "-", privacy: .public): \(body, privacy: .public)")
        if let sessionId, sessions.state.mutedSessions.contains(sessionId) { return }
        let spoken = witness.map { voice($0, tab: tab, sessionId: sessionId, project: project, pack: pack) } ?? .none
        // A Focus that asked for quiet silences the notification sound too; the card still shows (ADR-207).
        let quiet = FocusQuiet.shared.isQuiet
        let shown = spoken.caption.flatMap { history.setCaption($0, on: entry.id) } ?? entry
        if let tab, isFrontAndSelected(tab) { return }
        if NSApp.isActive {
            history.showCard(shown)
            if !spoken.covered && !quiet { sounds.playForCard() }
        } else {
            let silent = quiet || spoken.covered || sounds.playForSystemNotification()
            notifications.post(sessionId: sessionId ?? SessionID(UUID().uuidString), title: title, body: body,
                               silent: silent, pullRequest: pullRequest?.url, answerable: kind == .needsPermission)
        }
        tab?.unread = true
        updateBadge()
    }

    private func notify(_ tab: Tab, sessionId: SessionID, body: String, kind: NotificationStore.Entry.Kind, witness: SoundWitness) {
        notify(tab, sessionId: sessionId, title: tab.title, body: body, kind: kind, witness: witness)
    }

    /// Plays the line a pack has for this moment (ADR-199). True when a pack voice covers it, so no
    /// other sound should. A muted session is never voiced, as it is never notified (ADR-066), and
    /// nothing is voiced while a Focus has asked Clinic for quiet (ADR-207).
    @discardableResult
    func voice(_ witness: SoundWitness, tab: Tab?, sessionId: SessionID?, project: String? = nil, pack: String? = nil,
               onScreen: Bool? = nil) -> SoundPackStore.Spoken {
        guard let soundPacks, !FocusQuiet.shared.isQuiet else { return .none }
        if let sessionId, sessions.state.mutedSessions.contains(sessionId) { return .none }
        return soundPacks.voice(witness, session: sessionId, project: project, pack: pack,
                                onScreen: onScreen ?? tab.map(isFrontAndSelected) ?? false)
    }

    var selectedTab: Tab? { selectedTab(in: activeWindow) }

    /// Clinic's shortcuts, set before `start`: the terminals give their chords up (ADR-173).
    var bindings: KeyBindings?

    private func makeGhosttyConfig() throws -> GhosttyConfig {
        try GhosttyConfig(yieldTriggers: bindings?.ghosttyTriggers ?? [])
    }

    /// A rebinding moves which trigger the terminals must give up. The user's Ghostty files are read
    /// again with it, as Ghostty's own *Reload Configuration* would, and every open surface follows.
    func reloadGhosttyKeybinds() {
        guard let runtime else { return }
        do {
            let config = try makeGhosttyConfig()
            for d in config.diagnostics { Self.log.warning("ghostty config: \(d, privacy: .public)") }
            runtime.reloadConfig(config)
        } catch {
            Self.log.error("ghostty config reload failed: \(error, privacy: .public)")
        }
    }

    func start() {
        Self.adoptInstalledGhosttyResources()
        do {
            let config = try makeGhosttyConfig()
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
        notifications.onPermissionAnswer = { [weak self] id, allow in self?.answerPermission(sessionId: id, allow: allow) }
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

    /// The tab a message from the CLI belongs to: also one that has since moved on to a new id (ADR-166).
    func tab(routing sessionId: SessionID) -> Tab? {
        tab(for: sessionId) ?? tabs.first { $0.formerSessionIds.contains(sessionId) }
    }

    /// Opens (or focuses, ADR-041) a session known from disk.
    func open(session summary: SessionSummary) {
        if let existing = tab(for: summary.id) { select(existing); return }
        // Resuming a session that is being replayed: the replay gives way to it (ADR-221).
        if let replay = tabs.first(where: { $0.kind == .replay(summary.id) }) { close(replay, confirm: false) }
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

    /// Opens the screen for a project (reusing unsent text, from this run or a saved draft — ADR-160), or
    /// the folder picker when no project is known. `inNewWindow` puts the screen in a fresh window (ADR-072).
    func startNewSession(projectPath: String? = nil, inNewWindow: Bool = false) {
        guard let path = projectPath ?? selectedTab?.projectPath ?? editingDraft?.projectPath else {
            NotificationCenter.default.post(name: .clinicNewSession, object: nil); return
        }
        let window = inNewWindow ? openNewWindow() : activeWindow
        if let d = drafts[path] { window.editingDraft = d; return }
        let d = composer.drafts[path].map { NewSessionDraft(projectPath: path, restoring: $0, defaultBase: worktreeBase(for: path)) }
            ?? NewSessionDraft(projectPath: path, model: sessions.state.lastModelByProject[path], worktree: sessions.state.lastWorktreeByProject[path] ?? false,
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

    /// The composer for a child of `summary` (ADR-182): the parent's project, model and effort, fresh or
    /// a fork, reporting back by default. Replaces the project's unsent draft like a task's composer does.
    func startChildSession(of summary: SessionSummary) {
        let cwd = summary.lastCwd ?? summary.cwd ?? ""
        let path = ProjectGrouping.project(for: summary)?.path ?? ProjectGrouping.projectPath(forCwd: cwd)
        let parentTab = tab(for: summary.id)
        let d = NewSessionDraft(projectPath: path, model: parentTab?.model ?? sessions.state.lastModelByProject[path], worktree: false,
                                worktreeBase: worktreeBase(for: path))
        if let effort = parentTab?.effort { d.effort = effort }
        d.parentId = summary.id
        drafts[path] = d
        activeWindow.editingDraft = d
    }

    private func window(showing d: NewSessionDraft) -> WindowState? { windows.first { $0.editingDraft?.id == d.id } }

    /// Throws the project's draft away, on disk too (ADR-160). Closing the screen keeps it.
    func discardDraft(_ d: NewSessionDraft) {
        drafts[d.projectPath] = nil
        composer.setDraft(nil, for: d.projectPath)
        if let w = window(showing: d) { w.editingDraft = nil; w.selectedTabId = tabs(in: w).last?.id }
    }

    /// Discard Draft from the sidebar (ADR-161): the project's composer need not be open, or even exist
    /// in this run — the draft may only be on disk.
    func discardDraft(projectPath: String) {
        if let d = drafts[projectPath] { discardDraft(d) } else { composer.setDraft(nil, for: projectPath) }
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
        // A child (ADR-182): briefed about its parent, a fork of it or fresh, reporting back or not.
        if let parentId = d.parentId, let parentSummary = sessions.sessions[parentId] {
            let parentTab = tab(for: parentId)
            let directory = d.startAsFork ? (parentSummary.lastCwd ?? parentSummary.cwd ?? d.projectPath) : d.projectPath
            let brief = reports?.brief(parent: parentId, parentTitle: parentTab?.title ?? sessions.displayName(for: parentSummary),
                                       directory: directory, reporting: d.reportBack)
            closeDraft(d)
            if d.startAsFork {
                fork(parentSummary, prompt: prompt ?? "", model: d.resolvedModel, effort: d.resolvedEffort, appendSystemPrompt: brief, reporting: d.reportBack)
                if let t = tabs.last(where: { $0.pendingParent?.id == parentId }) {
                    t.pendingSoundPack = d.soundPack
                    select(t)
                }
            } else {
                let id = launchNewSession(projectPath: d.projectPath, model: d.resolvedModel, worktree: false, worktreeName: nil, worktreeBaseRef: nil,
                                          effort: d.resolvedEffort, prompt: prompt, workItem: d.workItem,
                                          parent: SessionParent(id: parentId, kind: .spawn), appendSystemPrompt: brief, reporting: d.reportBack)
                assignSoundPack(d.soundPack, to: id)
            }
            return
        }
        let worktree = d.worktree && !SessionStore.isChats(d.projectPath)
        guard worktree, case .branch(let ref) = d.worktreeBase else {
            closeDraft(d)
            let id = launchNewSession(projectPath: d.projectPath, model: d.resolvedModel, worktree: worktree, worktreeName: worktree ? d.worktreeName : nil,
                                      worktreeBaseRef: worktree ? d.worktreeBase.cliBaseRef : nil, effort: d.resolvedEffort, prompt: prompt, workItem: d.workItem)
            assignSoundPack(d.soundPack, to: id)
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
                let id = launchNewSession(projectPath: d.projectPath, model: d.resolvedModel, worktree: true, worktreeName: plan.name,
                                          worktreeBaseRef: d.worktreeBase.cliBaseRef, effort: d.resolvedEffort, prompt: prompt, workItem: d.workItem)
                assignSoundPack(d.soundPack, to: id)
            } catch {
                d.isStarting = false
                d.startError = Self.describeWorktreeFailure(error)
            }
        }
    }

    /// The composer's pick becomes the session's own pack before its first sound (ADR-202): the id is
    /// Clinic's from the start (ADR-017), so the SessionStart line is already in its voice.
    private func assignSoundPack(_ pack: String?, to id: SessionID?) {
        guard let pack, let id else { return }
        soundPacks?.setPack(pack, forSession: id)
    }

    private func closeDraft(_ d: NewSessionDraft) {
        drafts[d.projectPath] = nil
        composer.setDraft(nil, for: d.projectPath)
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
    /// Returns the new session's id when the launch is immediate; nil while a named worktree is prepared first.
    @discardableResult
    func newSession(projectPath: String, model: String?, worktree: Bool, worktreeName: String? = nil, worktreeBase: WorktreeBase? = nil,
                    effort: String? = nil, prompt: String? = nil, workItem: WorkItemRef? = nil, parent: SessionParent? = nil,
                    appendSystemPrompt: String? = nil, reporting: Bool = false) -> SessionID? {
        let base = worktreeBase ?? self.worktreeBase(for: projectPath)
        guard worktree, case .branch(let ref) = base else {
            return launchNewSession(projectPath: projectPath, model: model, worktree: worktree, worktreeName: worktreeName,
                                    worktreeBaseRef: worktree ? base.cliBaseRef : nil, effort: effort, prompt: prompt, workItem: workItem, parent: parent,
                                    appendSystemPrompt: appendSystemPrompt, reporting: reporting)
        }
        Task {
            do {
                let plan = try await prepareWorktree(projectPath: projectPath, ref: ref, name: worktreeName ?? "")
                launchNewSession(projectPath: projectPath, model: model, worktree: true, worktreeName: plan.name,
                                 worktreeBaseRef: base.cliBaseRef, effort: effort, prompt: prompt, workItem: workItem, parent: parent,
                                 appendSystemPrompt: appendSystemPrompt, reporting: reporting)
            } catch {
                let alert = NSAlert()
                alert.messageText = "Couldn't create a worktree from \(ref)"
                alert.informativeText = Self.describeWorktreeFailure(error)
                alert.alertStyle = .warning
                alert.runModal()
            }
        }
        return nil
    }

    /// `appendSystemPrompt` is a child's brief and `reporting` arms its report (ADR-182).
    @discardableResult
    func launchNewSession(projectPath: String, model: String?, worktree: Bool, worktreeName: String?, worktreeBaseRef: String?,
                          effort: String?, prompt: String?, workItem: WorkItemRef?, parent: SessionParent? = nil,
                          appendSystemPrompt: String? = nil, reporting: Bool = false) -> SessionID? {
        let id = SessionID.generate()
        var launch = ClaudeLaunch(mode: .new(id: id), model: model, effort: effort, worktree: worktree,
                                  settingsFilePath: hooks.settingsFileURL(worktreeBaseRef: worktree ? worktreeBaseRef : nil).path, prompt: prompt)
        launch.worktreeName = worktreeName
        launch.mcpConfigPath = mcp?.configPath(for: id)
        launch.appendSystemPrompt = appendSystemPrompt
        guard let tab = makeTab(kind: .session(id), cwd: projectPath, projectPath: projectPath, initialInput: launch.shellLine, title: "New session") else { return nil }
        var resume = ClaudeLaunch(mode: .resume(id: id, fork: false), settingsFilePath: hooks.settingsFileURL.path)
        resume.mcpConfigPath = launch.mcpConfigPath
        tab.lastResume = resume
        tab.model = model
        tab.effort = effort
        sessions.registerPending(id: id, cwd: projectPath)
        if let workItem { sessions.linkWorkItem(workItem, to: id) }
        if let parent { sessions.setParent(parent, of: id) }
        if parent != nil, reporting { reports?.arm(child: id) }
        sessions.update { s in
            if let model { s.lastModelByProject[projectPath] = model } else { s.lastModelByProject[projectPath] = nil }
            s.lastWorktreeByProject[projectPath] = worktree
        }
        selectedTabId = tab.id
        return id
    }

    /// `claude --resume <id> --fork-session` in a new tab; rebinds on SessionStart (ADR-063). With a
    /// `prompt` it is a child started as a fork (ADR-182): briefed, optionally reporting, and left in
    /// the background like a spawned one.
    func fork(_ summary: SessionSummary, prompt: String? = nil, model: String? = nil, effort: String? = nil,
              appendSystemPrompt: String? = nil, reporting: Bool = false) {
        let cwd = summary.lastCwd ?? summary.cwd ?? FileManager.default.homeDirectoryForCurrentUser.path
        var launch = ClaudeLaunch(mode: .resume(id: summary.id, fork: true), model: model, effort: effort,
                                  settingsFilePath: hooks.settingsFileURL.path, prompt: prompt)
        // The fork's real id arrives with SessionStart; until then the tab wears a placeholder, and the
        // MCP config carries that placeholder so the fork's process has Clinic's tools from the start
        // (ADR-182): the shim keeps sending it, and the tab answers to it as a former id (ADR-166).
        let placeholder = SessionID.generate()
        launch.mcpConfigPath = mcp?.configPath(for: placeholder)
        launch.appendSystemPrompt = appendSystemPrompt
        guard let tab = makeTab(kind: .session(placeholder), cwd: cwd, projectPath: ProjectGrouping.projectPath(forCwd: cwd),
                                initialInput: launch.shellLine, title: "Fork of " + sessions.displayName(for: summary)) else { return }
        tab.awaitingId = true
        tab.pendingParent = SessionParent(id: summary.id, kind: .fork)
        tab.pendingReporting = reporting
        tab.model = model
        tab.effort = effort
        if prompt == nil { selectedTabId = tab.id }
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

    /// *Resume* in a replay's header: the session runs again in place of its replay (ADR-221).
    func resume(replay tab: Tab) {
        guard case .replay(let id) = tab.kind, let summary = sessions.sessions[id] else { return }
        open(session: summary)
    }

    /// *Replay…*: a session that is not running, its transcript in the Claude tab (ADR-059, ADR-221). Focuses
    /// an existing replay; for a session that is running, shows that instead.
    func openReplay(_ summary: SessionSummary) {
        if let existing = tabs.first(where: { $0.kind == .replay(summary.id) }) { select(existing); return }
        if let running = tab(for: summary.id) { select(running); return }
        guard let runtime else { return }
        // A replay tab still needs a Tab; give it an idle surface it never shows (cheapest way to keep Tab uniform).
        var options = GhosttySurfaceOptions()
        options.command = "/usr/bin/true"
        options.workingDirectory = summary.lastCwd ?? summary.cwd
        guard let surface = try? GhosttySurfaceView(runtime: runtime, options: options) else { return }
        surface.isOccluded = true
        let tab = Tab(kind: .replay(summary.id), projectPath: ProjectGrouping.projectPath(forCwd: summary.cwd ?? ""), surface: surface, title: sessions.displayName(for: summary), windowId: activeWindow.id, sessions: sessions)
        wirePaneDrops(tab)
        tab.replay = ReplayModel(sessionId: summary.id, transcriptPath: summary.transcriptPath)
        tab.state = nil
        tabs.append(tab)
        selectedTabId = tab.id
    }

    /// ⌘T, *New Terminal Tab*: another shell beside Claude in the selected session (ADR-221). There are no
    /// standalone shells; with no session in view it does nothing, and the menu item is disabled.
    func newTerminalTab() {
        guard let tab = selectedTab, tab.sessionId != nil else { return }
        addPane(.terminal, in: tab, area: .main)
    }

    /// A shell in `directory`, typing `initialInput` (ADR-221): a terminal tab beside Claude in the open
    /// session working there — the selected one first — or, with none, the user's own terminal app.
    func openTerminal(in directory: String, initialInput: String? = nil) {
        guard let host = terminalHost(for: directory),
              let pane = makePane(.terminal, in: host, cwd: directory, initialInput: initialInput) else {
            openExternalTerminal(in: directory, initialInput: initialInput)
            return
        }
        host.main.append(pane)
        host.focusedArea = .main
        select(host)
        focusPanel(host)
    }

    /// The open session working in `directory`: the selected one if it is, else one there, else one in the
    /// same project.
    private func terminalHost(for directory: String) -> Tab? {
        let project: String = ProjectGrouping.projectPath(forCwd: directory)
        let sessionTabs: [Tab] = tabs.filter { $0.sessionId != nil }
        if let selected = selectedTab, selected.sessionId != nil, selected.pwd == directory || selected.projectPath == project {
            return selected
        }
        if let here = sessionTabs.first(where: { $0.pwd == directory }) { return here }
        return sessionTabs.first(where: { $0.projectPath == project })
    }

    /// Ghostty if it is installed, else Terminal, in `directory`. A command is run with Ghostty, in a login
    /// shell that stays open afterwards; Terminal is only opened there, with the command on the pasteboard.
    func openExternalTerminal(in directory: String, initialInput: String? = nil) {
        let command = initialInput?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let ghostty = Self.ghosttyBinary {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: ghostty)
            var args = ["--working-directory=\(directory)"]
            if let command, !command.isEmpty {
                let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
                args += ["-e", shell, "-lc", "\(command); exec \(shell) -l"]
            }
            p.arguments = args
            var env = ProcessInfo.processInfo.environment
            for k in env.keys where k == "CLAUDECODE" || k.hasPrefix("CLAUDE_CODE_") { env[k] = nil }
            p.environment = env
            try? p.run()
            return
        }
        if let command, !command.isEmpty {
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(command, forType: .string)
        }
        NSWorkspace.shared.open([URL(fileURLWithPath: directory)], withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
                                configuration: NSWorkspace.OpenConfiguration())
    }

    private func makeTab(kind: Tab.Kind, cwd: String, projectPath: String, initialInput: String?, title: String) -> Tab? {
        guard let runtime else { return nil }
        var options = GhosttySurfaceOptions()
        options.workingDirectory = cwd
        options.environment = ["CLINIC": "1"]
        // A session's terminal can carry a paused peon-ping, so it does not play over Clinic (ADR-203).
        if case .session = kind, let extra = soundPacks?.sessionEnvironment { options.environment.merge(extra) { _, new in new } }
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
            wirePaneDrops(tab)
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

    /// A tab dropped on an area's content goes there, opening a hidden right panel (ADR-218). Only this
    /// session's tabs: one dragged from another window's session is refused.
    private func wirePaneDrops(_ tab: Tab) {
        tab.contentView.paneArea = { [weak tab] id in
            guard let tab, let pane = tab.allPanes.first(where: { $0.id == id }) else { return nil }
            return tab.area(of: pane) == .main ? .main : .right
        }
        tab.contentView.onPaneDrop = { [weak self, weak tab] id, area in
            guard let self, let tab, let pane = tab.allPanes.first(where: { $0.id == id }) else { return false }
            self.movePane(pane, in: tab, to: area == .main ? .main : .right)
            return true
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
            t.syncOcclusion(hidden: t.id != window.selectedTabId)
        }
        if let tab = selectedTab(in: window) { runs.claim(for: tab) }
        runs.syncOcclusion()
        if let tab = selectedTab(in: window) {
            noteSelected(tab, in: window)
            tab.unread = false
            if let id = tab.sessionId { history.markRead(sessionId: id) }
            if let id = tab.sessionId { sessions.update { $0.selectedSessionId = id } }
            revealInScope(tab, in: window)
            updateBadge()
        }
    }

    /// A tab selected from outside the window's group (a notification, ⌘K, another window) takes the
    /// sidebar to the group its row is in, or to All for an ungrouped project, so the selection is
    /// always on screen (ADR-210). Chats is in every scope.
    private func revealInScope(_ tab: Tab, in window: WindowState) {
        guard let scope = window.groupScope, sessions.groups.contains(where: { $0.id == scope }) else { return }
        let path = tab.sessionId.flatMap(sessions.sidebarProjectPath(of:)) ?? tab.projectPath
        guard !SessionStore.isChats(path), sessions.group(of: path)?.id != scope else { return }
        window.groupScope = sessions.group(of: path)?.id
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
            // A worktree session is looked at first and asked about once, before the CLI is asked to
            // exit, so its exit dialog is never left waiting (ADR-190).
            if tab.state != nil, !tab.isAttached, let root = worktreeRoot(of: tab) {
                Task { await closeWorktreeSession(tab, root: root) }
                return false
            }
            switch confirmCloseTab(tab) {
            case .cancel: return false
            case .background: background(tab); return false
            case .close:
                if tab.state != nil, !tab.isAttached { closeGracefully(tab); return false }
            }
        }
        let w = window(of: tab)
        runs.tabClosed(tab)
        tab.worktreeExitWatcher?.cancel()
        tabs.removeAll { $0.id == tab.id }
        if w.selectedTabId == tab.id { w.selectedTabId = tabs(in: w).last?.id }
        tab.surface.free()
        tab.panel.tearDown()
        tab.main.tearDown()
        if let id = tab.sessionId {
            sessions.removePending(id: id)
            reports?.childEnded(id, reason: "its tab was closed")
        }
        updateBadge()
        return true
    }

    func closeSelected() { if let t = selectedTab { close(t) } }

    /// Types a slash command into an idle session (ADR-064). Returns false when the session is not at its prompt.
    @discardableResult
    func sendSlashCommand(_ command: String, to tab: Tab) -> Bool {
        guard tab.sessionId != nil, tab.isAtPrompt else { return false }
        tab.surface.sendLine(command)
        return true
    }

    func switchModel(_ tab: Tab, to model: String) {
        if sendSlashCommand("/model " + model, to: tab) { tab.model = model }
    }

    func switchEffort(_ tab: Tab, to level: String) {
        if sendSlashCommand("/effort " + level, to: tab) { tab.effort = level }
    }

    /// Ctrl‑C twice: Claude Code's clean exit (ADR-063). The shell stays in the tab. A worktree
    /// session's exit dialog is answered by the watcher this starts (ADR-190).
    func stop(_ tab: Tab) {
        guard tab.isRunningClaude else { return }
        if let root = worktreeRoot(of: tab) { watchWorktreeExit(tab, root: root) }
        tab.surface.sendInterrupt()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { tab.surface.sendInterrupt() }
    }

    /// Stop from a menu or a row: a worktree session is asked about first when the setting says to
    /// ask (ADR-190), unless it is clean and so takes the default answer at once (ADR-229). Quit and
    /// the smoke keys use `stop`, which takes the setting, or Keep.
    func stopSession(_ tab: Tab) {
        guard tab.isRunningClaude else { return }
        guard let root = worktreeRoot(of: tab), worktreeExitSetting == .ask, tab.worktreeExitAnswer == nil else { stop(tab); return }
        Task {
            let facts = await GitRepository.worktreeExitFacts(at: root)
            guard tab.isRunningClaude else { return }
            let offered = facts.answersToOffer(setting: .ask, askDefault: worktreeExitAskDefault)
            if offered.count == 1 { tab.worktreeExitAnswer = offered[0] }
            else {
                guard case .close(let answer) = confirmCloseWorktreeTab(tab, facts: facts, stopping: true) else { return }
                tab.worktreeExitAnswer = answer
            }
            stop(tab)
        }
    }

    var canStopSelected: Bool { selectedTab?.isRunningClaude ?? false }

    /// Stop, then close once the CLI reports `SessionEnd`. The fallback closes after five quiet
    /// seconds: the clock restarts when the worktree dialog was just answered, because a removal is
    /// still running, and never runs out while that dialog is on screen unanswered, because closing
    /// would kill it with the question unasked (ADR-190).
    func closeGracefully(_ tab: Tab) {
        tab.closingGracefully = true
        stop(tab)
        Task { [weak self, weak tab] in
            while true {
                try? await Task.sleep(for: .seconds(5))
                guard let self, let tab, tab.closingGracefully, self.tabs.contains(where: { $0.id == tab.id }) else { return }
                if let at = tab.worktreeAnsweredAt, Date().timeIntervalSince(at) < 5 { continue }
                if let text = tab.surface.visibleText, WorktreeExitDialog.isShowing(in: text) { continue }
                self.close(tab, confirm: false)
                return
            }
        }
    }

    // MARK: Worktree sessions at exit (ADR-190)

    /// The `.claude/worktrees/<name>` root a session tab runs in, or nil.
    func worktreeRoot(of tab: Tab) -> String? {
        guard tab.sessionId != nil else { return nil }
        return WorktreeExitFacts.worktreeRoot(forCwd: tab.pwd ?? tab.projectPath)
    }

    /// The Settings answer. *Ask* is resolved by a sheet before the stop; where no sheet can be shown it means Keep.
    var worktreeExitSetting: WorktreeExitAnswer {
        WorktreeExitAnswer(rawValue: UserDefaults.standard.string(forKey: WorktreeExitAnswer.preferenceKey) ?? "") ?? .keep
    }

    /// The answer the *Ask* sheet puts first (ADR-229).
    var worktreeExitAskDefault: WorktreeExitAnswer {
        WorktreeExitAnswer.askDefault(UserDefaults.standard.string(forKey: WorktreeExitAnswer.askDefaultKey))
    }

    /// Close a worktree session: read what the worktree holds, ask once, then stop with the answer
    /// ready. Returns once the tab is gone, or false when the user cancelled or chose Background.
    func closeWorktreeSession(_ tab: Tab, root: String) async -> Bool {
        let facts = await GitRepository.worktreeExitFacts(at: root)
        guard tabs.contains(where: { $0.id == tab.id }) else { return true }
        guard tab.isRunningClaude else { return close(tab, confirm: false) }
        switch confirmCloseWorktreeTab(tab, facts: facts, stopping: false) {
        case .cancel: return false
        case .background: background(tab); return false
        case .close(let answer):
            tab.worktreeExitAnswer = answer
            closeGracefully(tab)
            return await waitUntilClosed(tab)
        }
    }

    /// `close`, awaited: true once the tab is gone, false when the user kept it (ADR-190 for archive).
    func closeAndWait(_ tab: Tab) async -> Bool {
        if tab.isRunningClaude, tab.state != nil, !tab.isAttached, let root = worktreeRoot(of: tab) { return await closeWorktreeSession(tab, root: root) }
        if close(tab) { return true }
        return await waitUntilClosed(tab)
    }

    private func waitUntilClosed(_ tab: Tab) async -> Bool {
        while tabs.contains(where: { $0.id == tab.id }) {
            guard tab.closingGracefully else { return false }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return true
    }

    /// Watches the screen for the CLI's *Exiting worktree session* dialog and presses the answer once
    /// it shows: `1` keeps, `2` removes, and a bare digit both selects and confirms. The dialog follows
    /// the second Ctrl‑C within a second or two; the watch gives up after fifteen.
    private func watchWorktreeExit(_ tab: Tab, root: String) {
        tab.worktreeExitWatcher?.cancel()
        let setting = worktreeExitSetting
        let answer = tab.worktreeExitAnswer ?? (setting == .ask ? .keep : setting)
        guard let digit = answer.digit else { return }
        tab.worktreeExitWatcher = Task { [weak self, weak tab] in
            for _ in 0..<100 {
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled, let self, let tab, self.tabs.contains(where: { $0.id == tab.id }) else { return }
                if tab.state == .exited || tab.childExited { return }
                guard let text = tab.surface.visibleText, WorktreeExitDialog.isShowing(in: text) else { continue }
                Self.log.notice("worktree exit dialog: pressing \(answer.rawValue, privacy: .public) for \(tab.sessionId?.rawValue ?? "?", privacy: .public)")
                tab.surface.pressKey(keycode: digit == "1" ? 18 : 19, character: digit)   // kVK_ANSI_1, kVK_ANSI_2
                tab.worktreeAnsweredAt = Date()
                return
            }
        }
    }

    enum WorktreeCloseChoice { case close(WorktreeExitAnswer), background, cancel }

    /// The close (or stop) sheet for a worktree session: names the worktree, says what it holds and
    /// what will happen to it. Under *Ask*, a worktree with something to lose takes the answer from the
    /// sheet's own buttons, the default answer first so Return takes it; a clean one takes the default
    /// (ADR-229).
    func confirmCloseWorktreeTab(_ tab: Tab, facts: WorktreeExitFacts, stopping: Bool) -> WorktreeCloseChoice {
        let answers = facts.answersToOffer(setting: worktreeExitSetting, askDefault: worktreeExitAskDefault)
        let asking = answers.count > 1
        let alert = NSAlert()
        alert.messageText = stopping ? "Stop this session?" : "Close this session?"
        let canBackground = !stopping && tab.sessionId != nil && tab.isAtPrompt
        let verb = stopping ? "Stop" : "Close"
        if asking {
            // Brief, or NSAlert lays the four buttons out in a row instead of stacking them (ADR-229).
            alert.informativeText = facts.askingText
        } else {
            var text = "Claude Code is still running in the worktree \(facts.name). \(facts.summary)"
            if answers[0] == .keep { text += " \(verb) asks it to exit cleanly and keeps the worktree." }
            else { text += facts.isClean ? " \(verb) asks it to exit cleanly and removes the worktree." : " \(verb) asks it to exit cleanly and removes the worktree, its branch and that work." }
            if facts.isClean { text += " Claude Code removes a clean worktree itself unless the session was named." }
            if canBackground { text += " Background keeps it running detached so you can attach again." }
            alert.informativeText = text
        }
        alert.alertStyle = .warning
        for (index, answer) in answers.enumerated() {
            let button = alert.addButton(withTitle: asking ? "\(verb) and \(answer == .remove ? "Remove" : "Keep") Worktree" : verb)
            // Every answer ends the session, so each is red. NSAlert takes Return off a destructive button and
            // resets a default button's title colour, so the default is red by its bezel instead (ADR-229).
            if index == 0 { button.bezelColor = .systemRed } else { button.hasDestructiveAction = true }
        }
        if canBackground { alert.addButton(withTitle: "Background") }
        alert.addButton(withTitle: "Cancel")
        let index = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        if answers.indices.contains(index) { return .close(answers[index]) }
        return canBackground && index == answers.count ? .background : .cancel
    }

    /// Detach the session with `/bg`; the tab closes when the CLI hands the shell back (ADR-061).
    func background(_ tab: Tab) {
        guard tab.sessionId != nil, tab.isAtPrompt else { return }
        tab.detaching = true
        tab.surface.sendLine("/bg")
        Task { try? await Task.sleep(for: .seconds(2)); await backgroundAgents?.refresh() }
    }

    var canBackgroundSelected: Bool { selectedTab.map { $0.sessionId != nil && $0.isAtPrompt } ?? false }

    // MARK: The workspace's two areas (ADR-079, ADR-212)

    /// Quick action, chord or agent tool: front the pane of this kind wherever it is open, showing the
    /// panel if it is there and hidden. Otherwise open it in `area` — the right panel unless the caller
    /// asked for the main area, so nothing but the reader adds a tab beside Claude (ADR-212). Never a
    /// toggle: hiding is its own action.
    func showPane(_ kind: PanelPane.Kind, in tab: Tab? = nil, area: Tab.Area = .right, bringHere: Bool = false) {
        guard let tab = tab ?? selectedTab else { return }
        if bringHere, let existing = tab.pane(kind), let found = tab.area(of: existing), found != area {
            // ⌥ with an opener (ADR-220): the view comes to this area, rather than being fronted where it is.
            movePane(existing, in: tab, to: area)
            return
        }
        if let existing = tab.pane(kind), let found = tab.area(of: existing) {
            tab.group(found).select(existing)
            tab.focusedArea = found
        } else if let pane = makePane(kind, in: tab) {
            tab.group(area).append(pane)
            tab.group(area).isVisible = true
            tab.focusedArea = area
        } else {
            return
        }
        focusPanel(tab)
    }

    /// The one control that hides the panel: the header's button, ⌘⌥J.
    func togglePanelVisibility(_ tab: Tab? = nil) {
        guard let tab = tab ?? selectedTab else { return }
        tab.panel.isVisible.toggle()
        tab.focusedArea = tab.panel.isVisible ? .right : .main
        focusPanel(tab)
    }

    /// ⇧-click on the panel's own tab strip (ADR-130). The strip only exists while the panel shows,
    /// so this is hide rather than toggle — a ⇧-click there can never bring the panel back.
    func hidePanel(_ tab: Tab) {
        guard tab.panel.isVisible else { return }
        tab.panel.isVisible = false
        tab.focusedArea = .main
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
            if editingDraft != nil { closeDraftScreen(); return }
        // The tab the keyboard is in (ADR-220): a pane closes outright; Claude's tab closes the session,
        // through the close sheet (ADR-037).
        guard let tab = selectedTab else { return }
        if let pane = keyboardPane(in: tab) { closePane(pane, in: tab) } else { close(tab) }
    }

    // MARK: The keyboard over the workspace (ADR-220)

    /// The area the keyboard is in: where the first responder is, else the area the reader last acted in.
    func keyboardArea(in tab: Tab) -> Tab.Area {
        if tab.contentView.panelHoldsKeyboard, tab.panel.isVisible { return .right }
        if tab.contentView.mainPaneHoldsKeyboard || tab.surface.window?.firstResponder === tab.surface { return .main }
        return tab.focusedArea == .right && tab.panel.isVisible ? .right : .main
    }

    /// The pane in front of the keyboard's area; nil for Claude.
    func keyboardPane(in tab: Tab) -> PanelPane? { tab.group(keyboardArea(in: tab)).selected }

    /// ⌘1–9: the tab at that place in the keyboard's area. In the main area 1 is Claude.
    func selectTab(number n: Int) {
        guard let tab = selectedTab else { return }
        let area = keyboardArea(in: tab)
        let panes = tab.group(area).panes
        if area == .main {
            if n == 1 { selectClaude(in: tab) } else if panes.indices.contains(n - 2) { selectPane(panes[n - 2], in: tab) }
        } else if panes.indices.contains(n - 1) {
            selectPane(panes[n - 1], in: tab)
        }
    }

    /// ⌘⇧] / ⌘⇧[: the next or previous tab in the keyboard's area, Claude among the main area's.
    func cycleTab(_ delta: Int) {
        guard let tab = selectedTab else { return }
        let area = keyboardArea(in: tab)
        tab.group(area).cycle(by: delta)
        tab.focusedArea = area
        focusPanel(tab)
    }

    /// Sessions in each window, most recently selected first (ADR-220).
    private var sessionRecency: [UUID: [Tab.ID]] = [:]
    /// A ⌃⇥ walk in progress: the order it walks, frozen when it began, and where it is.
    private var sessionCycle: (window: UUID, order: [Tab.ID], index: Int)?
    private var controlMonitor: Any?

    private func noteSelected(_ tab: Tab, in window: WindowState) {
        guard sessionCycle == nil else { return }
        var order = sessionRecency[window.id] ?? []
        order.removeAll { $0 == tab.id }
        order.insert(tab.id, at: 0)
        sessionRecency[window.id] = order
    }

    /// ⌃⇥ / ⌃⇧⇥: the session used before this one, and on through them while ⌃ is held, as ⌘⇥ walks apps.
    /// Letting go of ⌃ settles on the one reached, which then counts as the most recent.
    func cycleSessions(_ delta: Int) {
        let w = activeWindow
        let open = tabs(in: w).map(\.id)
        if sessionCycle?.window != w.id {
            let recent = (sessionRecency[w.id] ?? []).filter(open.contains)
            sessionCycle = (w.id, recent + open.filter { !recent.contains($0) }, 0)
        }
        guard var cycle = sessionCycle, cycle.order.count > 1 else { sessionCycle = nil; return }
        cycle.index = (cycle.index + delta + cycle.order.count) % cycle.order.count
        sessionCycle = cycle
        w.selectedTabId = cycle.order[cycle.index]
        if NSEvent.modifierFlags.contains(.control) {
            if controlMonitor == nil {
                controlMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                    if !event.modifierFlags.contains(.control) { MainActor.assumeIsolated { self?.endSessionCycle() } }
                    return event
                }
            }
        } else {
            // Chosen from the menu with the mouse: nothing is held, so it settles at once.
            endSessionCycle()
        }
    }

    private func endSessionCycle() {
        if let controlMonitor { NSEvent.removeMonitor(controlMonitor) }
        controlMonitor = nil
        let ended = sessionCycle
        sessionCycle = nil
        if let ended, let w = windows.first(where: { $0.id == ended.window }), let tab = selectedTab(in: w) { noteSelected(tab, in: w) }
    }

    /// ⌃⌥⌘↓ / ↑: the next or previous open session in the order the sidebar lists them — by project, then
    /// the project's rows. A tab that is not a session goes last.
    func walkOpenSessions(_ delta: Int) {
        let w = activeWindow
        let projects = sessions.projects.map(\.path)
        var rows: [String: [SessionID]] = [:]
        func rank(_ tab: Tab) -> (Int, Int) {
            guard let id = tab.sessionId else { return (Int.max, Int.max) }
            let path = sessions.sidebarProjectPath(of: id) ?? tab.projectPath
            if rows[path] == nil { rows[path] = sessions.treeRows(in: Project(path: path), query: "").map(\.id) }
            return (projects.firstIndex(of: path) ?? Int.max - 1, rows[path]?.firstIndex(of: id) ?? Int.max)
        }
        let list = tabs(in: w).sorted { rank($0) < rank($1) }
        guard list.count > 1 else { return }
        let index = list.firstIndex { $0.id == w.selectedTabId } ?? 0
        w.selectedTabId = list[(index + delta + list.count) % list.count].id
    }

    /// ⌘Y: Quick Look whatever the front Images pane has selected. The pane's own space bar needs
    /// the pane to have the keyboard; this is the path from the menu bar, which never does (ADR-107).
    func quickLookFrontImage() {
        guard let tab = selectedTab, let gallery = tab.pane(.attachments)?.images,
              let id = tab.sessionId else { return }
        let rows = gallery.rows(Array((sessions.state.attachments[id] ?? []).reversed()))
        ImageQuickLook.shared.toggle(paths: rows.map(\.path), showing: gallery.selection(in: rows)?.path)
    }

    /// Panel ▸ Post a Sample Round, and the pane's empty state (ADR-133). Goes through the same
    /// `postGrillRound` the tool does, so it exercises what it demonstrates. Opens the pane and takes
    /// the keyboard, because the reader asked for it.
    func postSampleGrillRound(_ tab: Tab? = nil) {
        guard let tab = tab ?? selectedTab, let id = tab.sessionId else { return }
        sessions.postGrillRound(.sample(), to: id)
        toggleGrill(tab)
    }

    var canPostSampleGrillRound: Bool { selectedTab?.sessionId != nil }

    /// ⌘⌃C: the front Grill pane's newest round as Markdown. Deliberately not ⌘C — that is Edit ▸ Copy,
    /// and claiming it here would shadow copying in the terminal window-wide (ADR-131).
    func copyFrontGrillRound() {
        guard let tab = selectedTab, tab.isFront(.grill), let id = tab.sessionId else { return }
        // The round the reader is *looking at*, by the pane's own rule. `rounds.last` copied the newest
        // instead, so picking an older round and pressing ⌘⌃C put a different round on the pasteboard —
        // while the header's copy button, which passes what it shows, was right.
        let rounds = sessions.grillRounds(for: id)
        guard let model = tab.pane(.grill)?.grill,
              let round = model.currentRound(in: rounds) else { return }
        copyGrillRound(round)
    }

    func copyGrillRound(_ round: GrillRound) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(GrillAnswerComposer.markdown(round), forType: .string)
    }

    /// The pane the menu's pane verbs act on: on screen, in the area the reader is in first.
    private func frontPane(_ kind: PanelPane.Kind) -> PanelPane? { selectedTab?.frontPanes.first { $0.kind == kind } }
    /// True when a Files pane is on screen, so the tree toggle knows whether it applies.
    var isFilesPaneFront: Bool { selectedTab?.frontPane?.kind == .files }
    var isImagesPaneFront: Bool { selectedTab?.frontPane?.kind == .attachments }
    /// A Files pane is on screen showing a Markdown file, so the view can be cycled (ADR-191).
    var isMarkdownFront: Bool { frontPane(.files)?.editor?.isMarkdown == true }
    /// The diff the reader is looking at: the Diff panel's, or a pull request pane's (ADR-188).
    var frontDiffBrowser: DiffBrowser? {
        for pane in selectedTab?.frontPanes ?? [] {
            if let browser = pane.diff?.browser ?? pane.changes, !browser.isEmpty { return browser }
        }
        return nil
    }

    var canToggleBrowserList: Bool { isFilesPaneFront || isImagesPaneFront }
    var browserListShown: Bool { isImagesPaneFront ? ImagePrefs.shared.showList : EditorPrefs.shared.showTree }

    func selectPane(_ pane: PanelPane, in tab: Tab) {
        guard let area = tab.area(of: pane) else { return }
        tab.group(area).select(pane)
        tab.focusedArea = area
        focusPanel(tab)
    }

    /// The pinned Claude tab: the main area shows the session again (ADR-212).
    func selectClaude(in tab: Tab) {
        tab.main.selectedId = nil
        tab.focusedArea = .main
        focusPanel(tab)
    }

    func closePane(_ pane: PanelPane, in tab: Tab) {
        guard let area = tab.area(of: pane) else { return }
        tab.group(area).close(pane)
        if case .run(let key) = pane.kind { runs.paneClosed(key, in: tab) }
        if area == .right, !tab.panel.isVisible { tab.focusedArea = .main }
        focusPanel(tab)
    }

    /// The strip's *Close Others*, within the pane's own area: through `closePane`, so a run pane
    /// gives its surface back (ADR-122).
    func closeOtherPanes(_ keep: PanelPane, in tab: Tab) {
        guard let area = tab.area(of: keep) else { return }
        for pane in tab.group(area).panes where pane.id != keep.id { closePane(pane, in: tab) }
    }

    /// *Move to …* or a drop (ADR-212, ADR-215): the same pane, with its state, in `area` — the other one when
    /// none is given — before `before`, or at the end. Dropped within its own strip, this reorders it.
    func movePane(_ pane: PanelPane, in tab: Tab, to area: Tab.Area? = nil, before: PanelPane? = nil) {
        guard let from = tab.area(of: pane), before?.id != pane.id else { return }
        let to = area ?? (from == .main ? .right : .main)
        tab.group(from).detach(pane)
        let target = tab.group(to)
        target.insert(pane, at: before.flatMap { b in target.panes.firstIndex { $0.id == b.id } } ?? target.panes.count)
        target.isVisible = true
        tab.focusedArea = to
        focusPanel(tab)
    }

    /// Opens a run's pane in a tab — fronted, or added behind the pane on screen (a re-run after a turn
    /// never fronts anything, ADR-122).
    /// An emulator a run just booted with its window hidden (ADR pending; docs/Research): its screen in
    /// the run's tab, fronted, since there is no other window to see it in.
    func openDevicePane(_ deviceId: String, in tab: Tab) {
        EmulatorDirectory.shared.rescan()
        showPane(.device(deviceId), in: tab)
    }

    /// A device row in the `+` menu or the empty panel (ADR-226): its tab, fronted, after starting the AVD
    /// with its window hidden when it is not running, so the tab shows it starting. A failed start still
    /// opens the tab, which offers Start again.
    func openDevice(_ deviceId: String, in tab: Tab, area: Tab.Area = .right, coldBoot: Bool = false, wipeData: Bool = false) {
        if EmulatorDirectory.shared.emulator(deviceId) == nil {
            try? EmulatorDirectory.shared.start(deviceId, coldBoot: coldBoot, wipeData: wipeData)
        }
        showPane(.device(deviceId), in: tab, area: area)
    }

    /// A Device pane closing itself: after Stop Emulator, or from its *off* state's Close Tab.
    func closeDevicePane(_ model: DeviceScreenModel) {
        for tab in tabs {
            for area in [Tab.Area.main, .right] {
                if let pane = tab.group(area).panes.first(where: { $0.device === model }) { closePane(pane, in: tab); return }
            }
        }
    }

    func openRunPane(_ key: RunKey, in tab: Tab, front: Bool) {
        if !front {
            // Never shows the panel or moves the keyboard: Claude started this, or a turn ended, and
            // the user may be typing into the session. The toolbar pill and the chip carry the news.
            if !tab.isOpen(.run(key)) { tab.panel.append(PanelPane(kind: .run(key)), select: tab.panel.isEmpty) }
            return
        }
        showPane(.run(key), in: tab)
    }

    /// ⌘⌃] / ⌘⌃[: move through the panel's tabs.
    func cyclePanelTab(_ delta: Int, in tab: Tab? = nil) {
        guard let tab = tab ?? selectedTab, tab.panel.isVisible else { return }
        tab.panel.cycle(by: delta)
        tab.focusedArea = .right
        focusPanel(tab)
    }

    /// ⌘⌃W: close the panel tab on screen.
    func closeFrontPane(in tab: Tab? = nil) {
        guard let tab = tab ?? selectedTab, let pane = tab.panel.selected else { return }
        closePane(pane, in: tab)
    }

    /// The `+` menus' *Add*, into the area whose menu it is: a kind that allows several gets another pane
    /// even when one is open; any other kind is fronted where it already is (ADR-198, ADR-212).
    func addPane(_ kind: PanelPane.Kind, in tab: Tab, area: Tab.Area = .right) {
        guard kind.allowsSeveral, tab.isOpen(kind) else { showPane(kind, in: tab, area: area); return }
        guard let pane = makePane(kind, in: tab) else { return }
        tab.group(area).append(pane)
        tab.group(area).isVisible = true
        tab.focusedArea = area
        focusPanel(tab)
    }

    /// ⌘⇧J: another shell, beside any already open (ADR-198); in the main area with ⌥ (ADR-220).
    func newTerminal(_ tab: Tab? = nil, area: Tab.Area = .right) {
        guard let tab = tab ?? selectedTab else { return }
        addPane(.terminal, in: tab, area: area)
    }

    /// The shell `run_in_terminal` types into (ADR-198): the most recently used one at its prompt, or
    /// a new one when every shell has a job in the foreground — a command typed into a running dev
    /// server goes to the server, not to a shell. Fronted, as the tool always has.
    func idleShell(in tab: Tab) -> PanelPane? {
        let idle = SidePanel.mostRecent(of: tab.panes(.terminal).filter { $0.terminal?.foregroundJobName == nil })
        if let idle { selectPane(idle, in: tab); return idle }
        if tab.isOpen(.terminal) { addPane(.terminal, in: tab) } else { showPane(.terminal, in: tab) }
        return tab.frontPanes.first { $0.kind == .terminal }
    }

    /// Pane kinds the `+` menus can still add for this tab.
    func availablePanes(for tab: Tab) -> [PanelPane.Kind] {
        var kinds: [PanelPane.Kind] = [.terminal, .diff, .files]
        if tab.sessionId != nil { kinds += [.attachments, .grill] }
        kinds += pullRequests(for: tab).map { PanelPane.Kind.pr($0) }
        if let checkout = runs.checkout(for: tab) {
            kinds += runs.runs(inCheckout: checkout).filter { $0.surface != nil }.map { PanelPane.Kind.run($0.key) }
        }
        kinds += EmulatorDirectory.shared.deviceIds.map { PanelPane.Kind.device($0) }
        return kinds.filter { $0.allowsSeveral || !tab.isOpen($0) }
    }

    /// Chip and menu label for a pane: live facts (branch, image count) win over the kind's default.
    func paneTitle(_ kind: PanelPane.Kind, in tab: Tab) -> String {
        switch kind {
        case .diff: return tab.gitBranch ?? "Diff"
        case .attachments:
            let count = tab.sessionId.flatMap { sessions.state.attachments[$0]?.count } ?? 0
            return count > 0 ? "Media (\(count))" : "Media"
        case .run(let key): return runs.run(forKey: key)?.name ?? key.configId
        case .device(let id): return EmulatorDirectory.shared.emulator(id)?.name ?? EmulatorDirectory.name(of: id)
        case .grill:
            // The count on the chip is what still needs the reader, which is the only number that
            // would make them open the pane (ADR-131).
            // Sums across open rounds: several can be waiting at once (ADR-142).
            let waiting = tab.sessionId.map { sessions.openGrillRounds(for: $0) }?
                .reduce(0) { $0 + ($1.questions.count - $1.answeredCount) } ?? 0
            return waiting > 0 ? "Grill (\(waiting))" : "Grill"
        default: return kind.defaultTitle
        }
    }

    /// A pane's chip and menu label. A Files pane is named by the file it has open. A shell is named by
    /// the title it reports, or *Terminal 2*. Two shells reporting the same title — both idle in one
    /// folder, which fish calls `~` — fall back to their numbers, since a title they share names neither
    /// (ADR-198).
    func paneTitle(_ pane: PanelPane, in tab: Tab) -> String {
        guard pane.kind.allowsSeveral else { return paneTitle(pane.kind, in: tab) }
        let numbered = pane.ordinal == 1 ? pane.kind.defaultTitle : "\(pane.kind.defaultTitle) \(pane.ordinal)"
        if pane.kind == .files { return pane.editor?.openPath.map { ($0 as NSString).lastPathComponent } ?? numbered }
        guard let reported = pane.shellTitle else { return numbered }
        let shared = tab.panes(pane.kind).contains { $0.id != pane.id && $0.shellTitle == reported }
        return shared ? numbered : reported
    }

    /// Builds a pane's long-lived content; nil when it cannot exist (no runtime, no session).
    private func makePane(_ kind: PanelPane.Kind, in tab: Tab, cwd: String? = nil, initialInput: String? = nil) -> PanelPane? {
        let pane = PanelPane(kind: kind)
        if kind.allowsSeveral { pane.ordinal = tab.nextOrdinal(for: kind) }
        switch kind {
        case .terminal:
            guard let runtime else { return nil }
            var options = GhosttySurfaceOptions()
            options.workingDirectory = cwd ?? tab.pwd ?? tab.projectPath
            options.environment = ["CLINIC": "1", "CLINIC_PANEL": "1"]
            options.initialInput = initialInput
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
        case .grill:
            guard tab.sessionId != nil else { return nil }
            pane.grill = GrillPaneModel()
        case .pr:
            pane.changes = DiffBrowser()
        case .run:
            break
        case .device:
            break   // PanelPane makes its model
        }
        return pane
    }

    /// The surface that should hold the keyboard in one area: its front shell or run, Claude for a main
    /// area showing Claude, nil for a page (the page takes it on a click).
    private func keyboardTarget(_ area: Tab.Area, in tab: Tab) -> GhosttySurfaceView? {
        let group = tab.group(area)
        guard group.isVisible else { return nil }
        guard let pane = group.selected else { return area == .main && !tab.isReplay ? tab.surface : nil }
        switch pane.kind {
        case .terminal: return pane.terminal
        case .run(let key):
            guard let run = runs.run(forKey: key), run.hostTabId == tab.id else { return nil }
            return run.surface
        default: return nil
        }
    }

    /// Keeps every surface's occlusion and the first responder in step with what the workspace is
    /// showing. The keyboard goes to the area the reader acted in: its shell or run, or — for a page in
    /// the right panel — back to the main area, so reading a diff leaves typing in Claude.
    private func focusPanel(_ tab: Tab) {
        tab.syncOcclusion(hidden: window(of: tab).selectedTabId != tab.id)
        runs.claim(for: tab)
        runs.syncOcclusion()
        let target: GhosttySurfaceView? = if tab.focusedArea == .right, let right = keyboardTarget(.right, in: tab) { right }
                                          else { keyboardTarget(.main, in: tab) }
        // A pane opened in a tab nobody is looking at — by an agent's `ask_round` or `show_image` —
        // must not move the keyboard: the window has one, and it belongs to whatever is on screen.
        // Doing so put the reader's typing into a hidden terminal (ADR-197).
        guard isOnScreen(tab) else { return }
        let window = tab.surface.window
        // A page in front of the main area takes the keyboard itself, on a click; leaving the agent's
        // surface first responder behind it would type into a session that is not on screen.
        if target == nil, !tab.isClaudeInFront, tab.focusedArea == .main {
            DispatchQueue.main.async { if window?.firstResponder === tab.surface { window?.makeFirstResponder(nil) } }
            return
        }
        guard let target else { return }
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
    /// Tabs whose Grill pane should take the keyboard — added whenever the pane is opened, by the
    /// reader or by a round arriving (ADR-139, which reversed ADR-131's "never on arrival"). A round is
    /// the agent stopping and waiting, so the pane takes the keyboard rather than making the reader
    /// reach for it every round. Named per tab rather than a bare flag: a single app-wide one made a
    /// round arriving in one window pull focus in *every* window with a Grill pane open.
    ///
    /// The pane removes its tab once it has the keyboard, which it takes only while its tab is on
    /// screen. A round arriving in a background tab therefore waits here until the reader goes to it,
    /// instead of pulling the keyboard out of the tab they are in (ADR-197).
    var grillKeyboardRequests: Set<Tab.ID> = []

    func toggleGrill(_ tab: Tab? = nil, area: Tab.Area = .right) {
        guard let tab = tab ?? selectedTab else { return }
        showPane(.grill, in: tab, area: area, bringHere: area == .main)
        grillKeyboardRequests.insert(tab.id)
    }

    /// Whether a Grill pane is the one on screen — the menu's Grill verbs are enabled only then, the
    /// way ADR-107's image verbs are (ADR-131).
    var isGrillPaneFront: Bool { selectedTab?.isFront(.grill) ?? false }

    /// PR refs known for a tab's session (from the transcript).
    func pullRequests(for tab: Tab) -> [PullRequestRef] {
        guard let id = tab.sessionId, let s = sessions.sessions[id] else { return [] }
        return s.pullRequests
    }

    /// ⌘⇧P: the newest PR's pane; `ref` picks a specific PR (an opener). Each PR gets its own pane.
    func togglePRPage(_ tab: Tab? = nil, ref: PullRequestRef? = nil, area: Tab.Area = .right) {
        guard let tab = tab ?? selectedTab, let target = ref ?? pullRequests(for: tab).last else { return }
        showPane(.pr(target), in: tab, area: area, bringHere: area == .main)
    }

    func tab(forSurface surface: GhosttySurfaceView) -> Tab? {
        tabs.first { $0.surface === surface || $0.shellPane(for: surface) != nil }
    }

    var runningCount: Int { tabs.filter(\.isRunningClaude).count }

    enum CloseChoice { case close, background, cancel }

    /// Close sheet for one tab; offers Background when the session is idle at its prompt.
    func confirmCloseTab(_ tab: Tab) -> CloseChoice {
        let alert = NSAlert()
        alert.messageText = "Close this session?"
        let canBackground = tab.sessionId != nil && tab.isAtPrompt
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
        // Not a hook: the status line's numbers, many times a turn. It changes no state (ADR-157).
        if let report = event.statusLine {
            // The plan windows are the account's, so they count whether or not the session has a tab here.
            usage?.absorb(report, at: event.receivedAt)
            let reporting = tab(routing: event.sessionId)
            if let tab = reporting, tab.statusLine != report { tab.statusLine = report }
            // Limits a pack voices (ADR-203): this session's context, and the account's five-hour window.
            for witness in soundPacks?.witnesses(for: report, session: event.sessionId) ?? [] {
                voice(witness, tab: reporting, sessionId: event.sessionId)
            }
            return
        }
        // A hook usually means the transcript just grew; the card should not wait for the watcher's debounce.
        activities?.nudge()
        var found = tab(routing: event.sessionId)
        if found == nil, event.hookEventName == "SessionStart", event.source == "clear", let cleared = clearedTab(for: event) {
            rekey(cleared, to: event.sessionId, cwd: event.cwd)
            found = cleared
        }
        if found == nil, event.hookEventName == "SessionStart", let waiting = tabs.first(where: { $0.awaitingId && $0.sessionId != nil }) {
            // Fork / continue: adopt the id the CLI reports (ADR-063). The placeholder stays a former id,
            // since the fork's MCP shim was launched with it (ADR-182).
            if let placeholder = waiting.sessionId { waiting.formerSessionIds.insert(placeholder) }
            waiting.kind = .session(event.sessionId)
            waiting.awaitingId = false
            let cwd = event.cwd ?? waiting.pwd ?? waiting.projectPath
            sessions.registerPending(id: event.sessionId, cwd: cwd, title: waiting.title)
            // A fork now has an id to hang under its parent (ADR-181), and to report with (ADR-182).
            if let parent = waiting.pendingParent {
                sessions.setParent(parent, of: event.sessionId)
                waiting.pendingParent = nil
                if waiting.pendingReporting { reports?.arm(child: event.sessionId); reports?.childIdentified(event.sessionId, parent: parent.id) }
                waiting.pendingReporting = false
            }
            if let pack = waiting.pendingSoundPack {
                soundPacks?.setPack(pack, forSession: event.sessionId)
                waiting.pendingSoundPack = nil
            }
            var resume = ClaudeLaunch(mode: .resume(id: event.sessionId, fork: false), settingsFilePath: hooks.settingsFileURL.path)
            resume.mcpConfigPath = mcp?.configPath(for: event.sessionId)
            waiting.lastResume = resume
            found = waiting
        }
        guard let tab = found else {
            // At `notice`, which the log keeps: a run of these is what a disconnected session looks like.
            Self.log.notice("hook for unknown session \(event.sessionId.rawValue, privacy: .public): \(event.hookEventName, privacy: .public)")
            return
        }
        // ADR-080: turn boundaries become snapshots. Before any early return below, and before the
        // SessionEnd close path so a closing session still gets its last turn sealed.
        snapshots.handle(event, cwd: tab.pwd ?? tab.projectPath)
        let endedTurn = event.hookEventName == "Stop"
        if endedTurn { runs.turnEnded(in: tab, snapshots: snapshots) }
        // A child that ends a turn without ever reporting is reminded once; one whose session ends
        // releases a parent waiting on it (ADR-182).
        if endedTurn, let id = tab.sessionId { reports?.childStopped(id) }
        if event.hookEventName == "SessionEnd", event.reason != "clear", let id = tab.sessionId { reports?.childEnded(id, reason: "its session ended") }
        if event.hookEventName == "SessionEnd", event.reason == "clear" { tab.clearedAt = event.receivedAt }
        voiceHook(event, tab: tab)
        if event.hookEventName == "SessionEnd", tab.closingGracefully { tab.closingGracefully = false; close(tab, confirm: false); return }
        // A tab that stays after its session ended starts the next one undecided (ADR-190).
        if event.hookEventName == "SessionEnd" { tab.worktreeExitAnswer = nil; tab.worktreeAnsweredAt = nil }
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
        // A hook is the first witness: whatever the terminal was about to conclude is out of date.
        tab.pendingVerdict?.cancel(); tab.pendingVerdict = nil
        transition(tab, to: new, waitingOn: SessionStateMachine.waitingOn(tab.waitingOn, from: old, to: new, event: event),
                   failed: event.hookEventName == "StopFailure", message: event.message)
    }

    /// The hook witnesses that are not state changes (ADR-199). `/clear` and compaction are not a
    /// session starting or ending, and a subagent's hooks are its parent's business.
    private func voiceHook(_ event: HookEvent, tab: Tab) {
        guard event.agentId == nil else { return }
        switch event.hookEventName {
        case "SessionStart" where event.source == "startup" || event.source == "resume":
            voice(.sessionStarted, tab: tab, sessionId: event.sessionId)
        case "UserPromptSubmit":
            voice(.promptSubmitted, tab: tab, sessionId: event.sessionId)
            watchForLongTurn(tab, started: event.receivedAt)
        case "SessionEnd" where event.reason != "clear":
            voice(.sessionEnded, tab: tab, sessionId: event.sessionId)
            soundPacks?.forget(session: event.sessionId)
        default:
            break
        }
    }

    /// The opt-in `task.progress` line (ADR-203): once, if the turn this prompt began is still working ten
    /// minutes on. A later prompt starts a new turn and the old watch lapses.
    private func watchForLongTurn(_ tab: Tab, started: Date) {
        tab.turnStartedAt = started
        guard soundPacks?.settings.isOn(.turnLong) == true else { return }
        Task { [weak self, weak tab] in
            try? await Task.sleep(for: .seconds(Self.longTurn))
            guard let self, let tab else { return }
            guard tab.turnStartedAt == started, tab.state == .working else {
                Self.log.debug("long turn lapsed for \(tab.sessionId?.rawValue ?? "-", privacy: .public): state \(String(describing: tab.state), privacy: .public), newer turn \(tab.turnStartedAt != started, privacy: .public)")
                return
            }
            self.voice(.turnLong, tab: tab, sessionId: tab.sessionId)
        }
    }

    /// Ten minutes; `-ClinicLongTurnSeconds <n>` shortens it so a run can be checked without waiting.
    static var longTurn: TimeInterval {
        let override = UserDefaults.standard.double(forKey: "ClinicLongTurnSeconds")
        return override > 0 ? override : 600
    }

    // MARK: Answering a permission prompt from Clinic (ADR-180)

    /// Whether Approve and Deny apply: the session is at the CLI's permission prompt, and that prompt is
    /// not Claude's question dialog, which takes choices rather than a yes or no.
    func canAnswerPermission(_ tab: Tab) -> Bool {
        guard tab.state == .waitingForPermission, let id = tab.sessionId else { return false }
        return activities?.activity(for: id)?.currentTool?.name != "AskUserQuestion"
    }

    /// Presses the key the CLI's own prompt takes: `1` is *Yes*, `3` is *No*, which the CLI treats as an
    /// interrupt and asks what to do instead. Clinic is the reader's hands here, not an authority: the
    /// prompt stays the CLI's, and nothing is remembered. A key press, not committed text: the prompt
    /// reads keys and ignores a typed "1".
    func answerPermission(_ tab: Tab, allow: Bool) {
        guard canAnswerPermission(tab) else { return }
        Self.log.notice("permission \(allow ? "approved" : "denied", privacy: .public) from Clinic for \(tab.sessionId?.rawValue ?? "?", privacy: .public)")
        if allow { tab.surface.pressKey(keycode: 18, character: "1") } else { tab.surface.pressKey(keycode: 20, character: "3") }   // kVK_ANSI_1, kVK_ANSI_3
    }

    /// A notification's Approve or Deny: the session may have moved on, so the state is checked again.
    func answerPermission(sessionId: SessionID, allow: Bool) {
        guard let tab = tab(routing: sessionId) else { return }
        answerPermission(tab, allow: allow)
    }

    /// Moves a tab to a state and tells the user what the move means (ADR-033). Hooks come through here,
    /// and so do the terminal and the transcript when they correct what the hooks left behind (ADR-166).
    private func transition(_ tab: Tab, to new: SessionState, waitingOn: String? = nil, failed: Bool = false, message: String? = nil) {
        guard let old = tab.state, let sessionId = tab.sessionId else { return }
        tab.state = new
        tab.waitingOn = waitingOn
        tab.errorBadge = failed
        let isFrontAndSelected = isFrontAndSelected(tab)
        // The tab on screen is not notified, but its pack still speaks unless told not to (ADR-199).
        if failed {
            notify(tab, sessionId: sessionId, body: message ?? "The turn ended with an API error", kind: .error,
                   witness: ResourceWatch.isLimit(message) ? .rateLimited : .turnFailed)
        } else if SessionStateMachine.isFinishedEdge(from: old, to: new) {
            if !isFrontAndSelected { tab.unread = true; notify(tab, sessionId: sessionId, body: "Finished", kind: .finished, witness: .turnFinished) }
            else { voice(.turnFinished, tab: tab, sessionId: sessionId, onScreen: true) }
        } else if new.isWaiting && !old.isWaiting {
            let permission = new == .waitingForPermission
            if !isFrontAndSelected {
                notify(tab, sessionId: sessionId, body: permission ? "Needs permission" : (message ?? "Waiting for input"),
                       kind: permission ? .needsPermission : .needsInput, witness: permission ? .permissionNeeded : .inputNeeded)
            } else {
                voice(permission ? .permissionNeeded : .inputNeeded, tab: tab, sessionId: sessionId, onScreen: true)
            }
        }
        updateBadge()
        // A parent that can take a prompt again receives what its children held for it (ADR-182).
        reports?.deliverPending(to: sessionId)
    }

    // MARK: /clear (ADR-166)

    /// The tab whose `SessionEnd(reason: clear)` just arrived, or, when that hook was lost, the only
    /// live session tab in the directory the new session reports.
    private func clearedTab(for event: HookEvent) -> Tab? {
        let recent = tabs.filter { tab in tab.clearedAt.map { event.receivedAt.timeIntervalSince($0) < 10 } ?? false }
        if let tab = recent.max(by: { ($0.clearedAt ?? .distantPast) < ($1.clearedAt ?? .distantPast) }) { return tab }
        let sameDirectory = tabs.filter { $0.sessionId != nil && $0.state != nil && $0.state != .exited && !$0.childExited && $0.pwd == event.cwd }
        return sameDirectory.count == 1 ? sameDirectory[0] : nil
    }

    /// `/clear` keeps the process and starts a session with a new id and a new transcript. The tab
    /// follows the process; the transcript it leaves stays in the sidebar as a session of its own.
    private func rekey(_ tab: Tab, to id: SessionID, cwd: String?) {
        guard let old = tab.sessionId, old != id else { return }
        Self.log.notice("session \(old.rawValue, privacy: .public) cleared; tab follows \(id.rawValue, privacy: .public)")
        tab.formerSessionIds.insert(old)
        tab.clearedAt = nil
        tab.kind = .session(id)
        tab.statusLine = nil
        tab.unread = false
        sessions.registerPending(id: id, cwd: cwd ?? tab.pwd ?? tab.projectPath)
        var resume = ClaudeLaunch(mode: .resume(id: id, fork: false), settingsFilePath: hooks.settingsFileURL.path)
        resume.mcpConfigPath = mcp?.configPath(for: id)
        tab.lastResume = resume
        if tab.state == .exited, !tab.childExited { tab.state = .idle }   // an older build's reducer, or a lost ordering
    }

    // MARK: The terminal and the transcript as witnesses (ADR-166)

    private func progressReported(_ tab: Tab, busy: Bool) {
        tab.progressBusy = busy
        if busy { tab.sawProgressBusy = true }
        tab.pendingVerdict?.cancel(); tab.pendingVerdict = nil
        guard let state = tab.state else { return }
        guard case .after(let delay, let target) = TerminalWitness.progress(busy: busy, sawBusy: tab.sawProgressBusy, state: state, waitingOn: tab.waitingOn) else { return }
        let work = DispatchWorkItem { [weak self, weak tab] in
            guard let self, let tab, let state = tab.state else { return }
            tab.pendingVerdict = nil
            guard TerminalWitness.stillHolds(target, busy: tab.progressBusy, state: state, waitingOn: tab.waitingOn) else { return }
            Self.log.notice("terminal progress moved \(tab.sessionId?.rawValue ?? "?", privacy: .public) from \(state.rawValue, privacy: .public) to \(target.rawValue, privacy: .public); no hook did")
            self.transition(tab, to: target)
        }
        tab.pendingVerdict = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func titleReported(_ tab: Tab, title: String) {
        guard let state = tab.state, let new = TerminalWitness.title(title, state: state) else { return }
        transition(tab, to: new)
    }

    private func transcriptChanged(_ id: SessionID, _ activity: SessionActivity) {
        guard let tab = tab(for: id), let state = tab.state,
              TerminalWitness.transcriptEndsTurn(lastTurnEnd: activity.lastTurnEnd, state: state, since: tab.stateSince) else { return }
        Self.log.notice("transcript ended the turn of \(id.rawValue, privacy: .public) in \(state.rawValue, privacy: .public); no hook did")
        tab.pendingVerdict?.cancel(); tab.pendingVerdict = nil
        transition(tab, to: .idle)
    }

    func updateBadge() {
        notifications.setBadge(tabs.filter { $0.unread || ($0.state?.isWaiting ?? false) }.count + history.entries.filter { !$0.read && $0.sessionId == nil }.count)
    }

    // MARK: libghostty actions (ADR-035)

    private func handleAppAction(_ action: GhosttyAction) -> Bool {
        switch action {
        case .newTab, .newWindow, .newSplit: newTerminalTab(); return true
        case .quit: NSApp.terminate(nil); return true
        // libghostty asks for this when the colour scheme changes (ADR-152) and a `theme = light:…,
        // dark:…` config has a different theme to apply. Handing it the same config back is how it
        // re-evaluates the conditional; the files are not re-read.
        case .unhandled(kind: "reload_config"):
            if let runtime { runtime.reloadConfig(runtime.config) }
            return true
        case .unhandled(let kind): Self.log.debug("unhandled app action \(kind, privacy: .public)"); return false
        default: return false
        }
    }
}

// MARK: Terminal file links (ADR-192)

extension TabStore {
    static let fileLinksInFilesKey = "ClinicOpenFileLinksInFiles"

    /// Opens a ⌘-clicked file link in the tab's Files pane instead of the file's default app: the
    /// file Claude Code just named is read beside the session that named it. A folder, a file the pane
    /// cannot show and anything not on disk still go to the system; so does everything, with the
    /// setting off. A relative path is read from `cwd`, the directory the text was printed in: the
    /// shell's for a session or shell, the run's own for a run's output.
    func openInFiles(_ url: URL, from tab: Tab, cwd: String? = nil) -> Bool {
        guard UserDefaults.standard.object(forKey: Self.fileLinksInFilesKey) as? Bool ?? true,
              let link = FileLink.resolve(url, cwd: cwd ?? tab.pwd ?? tab.projectPath, isFile: Self.isRegularFile),
              MediaFile.isMedia(link.path) || Self.isText(link.path) else { return false }
        showPane(.files, in: tab)
        guard let editor = tab.pane(.files)?.editor else { return false }
        editor.open(absolute: link.path, line: link.line, column: link.column)
        Self.log.info("opened a terminal file link in the Files pane")
        return true
    }

    private nonisolated static func isRegularFile(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }

    /// What the pane would open as text: under its 8 MB limit, with no NUL in the first 8 KB, and UTF-8
    /// there. A zip, a database or a compiled binary goes to the app that can open it.
    private static func isText(_ path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        guard size < 8 * 1024 * 1024 else { return false }
        try? handle.seek(toOffset: 0)
        let head = (try? handle.read(upToCount: 8192)) ?? Data()
        if head.contains(0) { return false }
        // A multi-byte character cut at the 8 KB boundary is not a reason to refuse the file.
        return (0...3).contains { String(data: head.dropLast($0), encoding: .utf8) != nil }
    }
}

extension TabStore: GhosttySurfaceDelegate {
    func surface(_ surface: GhosttySurfaceView, didReceive action: GhosttyAction) -> Bool {
        let tab = tab(forSurface: surface)
        let shellPane = tab?.shellPane(for: surface)
        let isPanel = shellPane != nil
        switch action {
        case .newTab, .newWindow, .newSplit:
            // Ghostty's own new tab or split, from inside a session: a terminal tab beside Claude (ADR-221).
            if let tab, tab.sessionId != nil { addPane(.terminal, in: tab, area: .main) }
            return true
        case .openURL(let url, _):
            if let tab, openInFiles(url, from: tab) { return true }
            NSWorkspace.shared.open(url); return true
        case .ringBell:
            if let tab, !isFrontAndSelected(tab) {
                notify(tab, sessionId: tab.sessionId, title: tab.title, body: "Rang the bell", kind: .bell)
            } else { NSSound.beep() }
            return true
        case .setTitle(let t):
            // A panel shell's title names its chip, never the tab (ADR-046, ADR-198).
            if let shellPane { shellPane.shellTitle = t.isEmpty ? nil : t }
            if let tab, !isPanel {
                titleReported(tab, title: t)
            }
            return true
        case .pwd(let p):
            if let tab, !isPanel {
                let changed = tab.pwd != p
                tab.pwd = p
                flushPendingInput(tab)
                if changed { refreshFooter(tab) }
            }
            return true
        case .progressReport(let state, _):
            // `pause` and `error` are not the CLI's; they say nothing about whether a turn is running.
            if let tab, !isPanel, tab.sessionId != nil, state == .remove || state == .set || state == .indeterminate {
                progressReported(tab, busy: state != .remove)
            }
            return true
        case .commandFinished, .mouseShape, .colorScheme: return true
        case .quit: NSApp.terminate(nil); return true
        case .unhandled(let kind): Self.log.debug("unhandled surface action \(kind, privacy: .public)"); return false
        }
    }

    func surfaceRequestedClose(_ surface: GhosttySurfaceView, processAlive: Bool) {
        guard let tab = tab(forSurface: surface) else { return }
        // A panel shell's pane goes, and the keyboard follows whatever is in front now — another
        // shell, or the session (ADR-198).
        if let pane = tab.shellPane(for: surface) { closePane(pane, in: tab) } else { close(tab, confirm: processAlive) }
    }

    func surfaceChildExited(_ surface: GhosttySurfaceView, exitCode: Int32?) {
        guard let tab = tab(forSurface: surface) else { return }
        if let pane = tab.shellPane(for: surface) { closePane(pane, in: tab); return }
        if tab.detaching { close(tab, confirm: false); Task { await backgroundAgents?.refresh() }; return }
        tab.childExited = true
        tab.pendingVerdict?.cancel(); tab.pendingVerdict = nil
        tab.progressBusy = false; tab.sawProgressBusy = false
        if tab.state != nil { tab.state = .exited }
        updateBadge()
    }
}
