import SwiftUI
import ClinicCore
import GhosttyBridge

@main
struct ClinicApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // One window group; the launch window carries no value (primary), others are opened by id (ADR-072).
        WindowGroup("Clinic", id: "main", for: UUID.self) { $value in
            RootView(windowValue: value)
                .environment(appDelegate.tabs)
                .environment(appDelegate.sessions)
                .environment(appDelegate.history)
                .environment(appDelegate.usage)
                .environment(appDelegate.prs)
                .environment(appDelegate.backgroundAgents)
                .environment(appDelegate.bindings)
                .environment(appDelegate.caffeine)
                .environment(appDelegate.marketplace)
                .environment(appDelegate.mcpServers)
                .environment(appDelegate.automations)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1180, height: 760)
        .commands { ClinicCommands(tabs: appDelegate.tabs, bindings: appDelegate.bindings, caffeine: appDelegate.caffeine) }
        Settings { PreferencesView().environment(appDelegate.usage).environment(appDelegate.bindings).environment(appDelegate.tabs.snapshots) }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let sessions = SessionStore()
    let hooks = HookService()
    let notifications = NotificationService()
    let history = NotificationStore()
    let usage = UsageService()
    let prs = PRStore()
    let mcp = MCPToolService()
    let backgroundAgents = BackgroundAgentsService()
    let updates = UpdateCheck()
    let bindings = KeyBindings()
    let caffeine = CaffeineController()
    let marketplace = MarketplaceModel()
    let mcpServers = MCPServersModel()
    let automations = AutomationsModel()
    var statusItem: StatusItemController?
    lazy var tabs = TabStore(sessions: sessions, hooks: hooks, notifications: notifications, history: history)

    /// ADR-042/ADR-072: open tabs are never restored, the primary window keeps its frame through an autosave name,
    /// and AppKit state restoration is opted out — saved state from a build with another scene shape would otherwise
    /// be "restored" into no window at all.
    func applicationWillFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.set(true, forKey: "ApplePersistenceIgnoreState")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: ["ClinicShowUsage": true, "ClinicShowTabBar": true, "ClinicUsageExpanded": true])
        scrubInheritedClaudeEnvironment()
        // Resolve the login shell's PATH now, off the main thread, so the first `gh`/`git`/`claude`
        // call does not pay for it (ADR-086).
        ProcessEnvironment.prewarm()
        notifications.requestAuthorization()
        hooks.start()
        sessions.onArchive = { [weak self] id in self?.history.markRead(sessionId: id) }
        sessions.start()
        tabs.start()
        if UserDefaults.standard.bool(forKey: "ClinicShowUsage") { usage.start() }
        prs.openRefsProvider = { [weak self] in
            guard let self else { return [] }
            return self.tabs.tabs.flatMap { tab in self.tabs.pullRequests(for: tab) }
        }
        prs.start()
        tabs.mcp = mcp
        tabs.backgroundAgents = backgroundAgents
        backgroundAgents.isAttachedProvider = { [weak self] in self?.tabs.tabs.contains(where: \.isAttached) ?? false }
        backgroundAgents.router = { [weak self] sid, title, body, kind in self?.tabs.notify(self?.tabs.tab(for: sid), sessionId: sid, title: title, body: body, kind: kind) }
        backgroundAgents.onRefresh = { [weak self] agents in self?.automations.reconcile(agents: agents) }
        backgroundAgents.start(sessions: sessions, history: history, notifications: notifications)
        automations.router = { [weak self] sid, title, body, kind in
            self?.tabs.notify(sid.flatMap { self?.tabs.tab(for: $0) }, sessionId: sid, title: title, body: body, kind: kind)
        }
        tabs.automations = automations
        automations.start(sessions: sessions, settingsFilePath: hooks.settingsFileURL.path,
                          chatsDirectory: SessionStore.chatsDirectory)
        // Starting by hand re-arms the wake agent that an explicit quit switched off.
        AutomationWake.clearQuitSuppression()
        statusItem = StatusItemController(tabs: tabs, history: history, caffeine: caffeine)
        updates.start { [weak self] version, url in
            self?.tabs.notify(nil, sessionId: nil, title: "Clinic \(version) is available", body: "You are on \(UpdateCheck.currentVersion). Click to open the release.", kind: .update, url: url)
        }
        mcp.start(tabs: tabs, sessions: sessions, history: history, notifications: notifications, prs: prs)
        if UserDefaults.standard.bool(forKey: Prefs.reopenLastSession) {
            Task {
                await sessions.initialScan?.value
                if let id = sessions.state.selectedSessionId, let s = sessions.sessions[id] { tabs.open(session: s) }
            }
        }
        // `-ClinicScreenOnLaunch automations|marketplace|mcpServers` (ADR-038): land straight on a
        // screen, so a smoke run does not have to synthesise a click into the sidebar.
        if let screen = UserDefaults.standard.string(forKey: "ClinicScreenOnLaunch"), !screen.isEmpty {
            let mapped: WindowState.Screen? = switch screen {
            case "automations": .automations
            case "marketplace": .marketplace
            case "mcpServers": .mcpServers
            default: nil
            }
            if let mapped { tabs.activeWindow.screen = mapped }
        }

        // Hidden smoke-test key (ADR-038): `open Clinic.app --args -ClinicOpenShellOnLaunch YES`
        if UserDefaults.standard.bool(forKey: "ClinicOpenShellOnLaunch") {
            tabs.newShell(in: UserDefaults.standard.string(forKey: "ClinicShellDirectory"))
            if UserDefaults.standard.bool(forKey: "ClinicOpenPanelOnLaunch") { tabs.togglePanel() }
            // `-ClinicCyclePanelAfter <seconds>` hides the panel and shows it again a second later, from a
            // settled window: the path where a newly added panel used to come up blank.
            let cycle = UserDefaults.standard.double(forKey: "ClinicCyclePanelAfter")
            if cycle > 0 {
                Task {
                    try? await Task.sleep(for: .seconds(cycle))
                    let drag = UserDefaults.standard.double(forKey: "ClinicDragPanelTo")
                    if drag > 0 { tabs.selectedTab?.contentView.setPanelWidth(CGFloat(drag)) }
                    try? await Task.sleep(for: .seconds(1)); tabs.togglePanelVisibility()
                    try? await Task.sleep(for: .seconds(1)); tabs.togglePanelVisibility()
                }
            }
            if UserDefaults.standard.bool(forKey: "ClinicOpenEditorOnLaunch") {
                tabs.toggleEditor()
                if let file = UserDefaults.standard.string(forKey: "ClinicOpenFileOnLaunch") { tabs.selectedTab?.panel.pane(.files)?.editor?.open(absolute: file) }
                // `-ClinicHideFileTree YES` (ADR-081): the Files pane with its tree collapsed.
                if UserDefaults.standard.bool(forKey: "ClinicHideFileTree") { EditorPrefs.shared.showTree = false }
                // `-ClinicOpenSecondFileAfterLaunch <path>`: opens another file into a Files pane that is
                // already on screen — the path a tree click takes, and the one that used to leave the
                // code view showing the first file (ADR-081).
                if let second = UserDefaults.standard.string(forKey: "ClinicOpenSecondFileAfterLaunch"), !second.isEmpty {
                    Task {
                        try? await Task.sleep(for: .seconds(5))
                        tabs.selectedTab?.panel.pane(.files)?.editor?.open(absolute: second)
                    }
                }
            }
        }
        // `-ClinicZoomPanelAfterLaunch <seconds>` (ADR-081): let the panel settle, then zoom it over the tab.
        let zoomAfter = UserDefaults.standard.double(forKey: "ClinicZoomPanelAfterLaunch")
        if zoomAfter > 0 { Task { try? await Task.sleep(for: .seconds(zoomAfter)); tabs.togglePanelZoom() } }
        // `-ClinicOpenFileWindowOnLaunch <path>` (ADR-081): pop a file straight out into its own window.
        if let file = UserDefaults.standard.string(forKey: "ClinicOpenFileWindowOnLaunch"), !file.isEmpty {
            Task {
                try? await Task.sleep(for: .seconds(2))
                let root = tabs.selectedTab.map { $0.pwd ?? $0.projectPath } ?? (file as NSString).deletingLastPathComponent
                FileWindowController.show(path: file, root: root)
            }
        }
        // `-ClinicOpenDiffPanelOnLaunch YES [-ClinicDiffScope turn|session|workingTree|branch]`
        // (ADR-080). Deferred so it lands on whichever tab the other launch keys opened, and because
        // the scope picker is a menu no smoke test can open.
        if UserDefaults.standard.bool(forKey: "ClinicOpenDiffPanelOnLaunch") {
            Task {
                try? await Task.sleep(for: .seconds(2))
                tabs.toggleDiffPanel()
                if let raw = UserDefaults.standard.string(forKey: "ClinicDiffScope"),
                   let scope = DiffPanelModel.Scope(rawValue: raw) {
                    tabs.selectedTab?.panel.pane(.diff)?.diff?.scope = scope
                }
                if UserDefaults.standard.bool(forKey: "ClinicCollapseAllAfterLaunch") {
                    try? await Task.sleep(for: .seconds(6))
                    tabs.selectedTab?.panel.pane(.diff)?.diff?.smokeCollapseAll()
                }
            }
        }
        // `-ClinicOpenSessionOnLaunch <session-id>` imports and opens an existing session (PR page smoke test) without resuming.
        if let raw = UserDefaults.standard.string(forKey: "ClinicOpenSessionOnLaunch"), !raw.isEmpty {
            Task {
                await sessions.initialScan?.value
                if let s = sessions.sessions[SessionID(raw)] {
                    if UserDefaults.standard.bool(forKey: "ClinicReplayOnLaunch") { tabs.openReplay(s); return }
                    if UserDefaults.standard.bool(forKey: "ClinicDetailsOnLaunch") {
                        try? await Task.sleep(for: .seconds(1))
                        NotificationCenter.default.post(name: .clinicSessionDetails, object: s.id.rawValue); return
                    }
                    tabs.open(session: s)
                    if UserDefaults.standard.bool(forKey: "ClinicOpenPRPageOnLaunch") { tabs.togglePRPage() }
                }
            }
        }
        if UserDefaults.standard.bool(forKey: "ClinicMCPServersOnLaunch") {
            Task { try? await Task.sleep(for: .seconds(1)); NotificationCenter.default.post(name: .clinicMCPServers, object: nil) }
        }
        // `-ClinicNewSessionOnLaunch /path/to/project` starts a Claude session there (smoke test for the hook binding).
        if let path = UserDefaults.standard.string(forKey: "ClinicNewSessionOnLaunch"), !path.isEmpty {
            // `-ClinicPromptOnLaunch <text>`: send a first prompt, so a smoke run produces a real
            // turn to look at in the diff panel (ADR-080).
            tabs.newSession(projectPath: path, model: "haiku", worktree: false,
                            prompt: UserDefaults.standard.string(forKey: "ClinicPromptOnLaunch"))
            // `-ClinicStopAfterLaunch <seconds>`: exercise the graceful Stop path (ADR-063).
            // `-ClinicSwitchModelAfterLaunch <alias>`: exercise /model via the footer path (ADR-064).
            if let alias = UserDefaults.standard.string(forKey: "ClinicSwitchModelAfterLaunch"), !alias.isEmpty {
                Task { try? await Task.sleep(for: .seconds(9)); if let t = tabs.selectedTab { tabs.switchModel(t, to: alias) } }
            }
            let stopAfter = UserDefaults.standard.double(forKey: "ClinicStopAfterLaunch")
            if stopAfter > 0 { Task { try? await Task.sleep(for: .seconds(stopAfter)); if let t = tabs.selectedTab { tabs.stop(t) } } }
        }
        // `-ClinicGenerateIconOnLaunch /path/to/project`: open the icon sheet for a project (ADR-076 smoke test).
        if let path = UserDefaults.standard.string(forKey: "ClinicGenerateIconOnLaunch"), !path.isEmpty {
            Task { try? await Task.sleep(for: .seconds(2)); NotificationCenter.default.post(name: .clinicGenerateIcon, object: path) }
        }
        if UserDefaults.standard.bool(forKey: "ClinicNewChatOnLaunch") { tabs.newChat() }
        if let path = UserDefaults.standard.string(forKey: "ClinicNewSessionScreenOnLaunch"), !path.isEmpty {
            tabs.startNewSession(projectPath: path)
            // `-ClinicDraftPromptOnLaunch <text>`: fill the editor, so a screenshot shows typed text where the
            // placeholder would otherwise be — the only way to check the two line up (ADR-082).
            if let text = UserDefaults.standard.string(forKey: "ClinicDraftPromptOnLaunch"), !text.isEmpty {
                tabs.editingDraft?.prompt = text
            }
            // `-ClinicDraftEffortOnLaunch <level>`: the effort gauge only has something to show once a level is set.
            if let effort = UserDefaults.standard.string(forKey: "ClinicDraftEffortOnLaunch"), !effort.isEmpty {
                tabs.editingDraft?.effort = effort
            }
            // `-ClinicDraftWorktreeOnLaunch YES [-ClinicDraftBranchOnLaunch <name>]` (ADR-083): the worktree row
            // is only on screen once the toggle is on.
            if UserDefaults.standard.bool(forKey: "ClinicDraftWorktreeOnLaunch") {
                tabs.editingDraft?.worktree = true
                if let name = UserDefaults.standard.string(forKey: "ClinicDraftBranchOnLaunch") { tabs.editingDraft?.worktreeName = name }
            }
        }
        // `-ClinicSelectTabAfterLaunch <index>`: select a tab once launch tabs exist (attention smoke tests).
        if UserDefaults.standard.object(forKey: "ClinicSelectTabAfterLaunch") != nil {
            let i = UserDefaults.standard.integer(forKey: "ClinicSelectTabAfterLaunch")
            Task { try? await Task.sleep(for: .seconds(4)); tabs.selectIndex(i) }
        }
        // `-ClinicMoveToNewWindowAfterLaunch <seconds>`: move the selected tab to a new window (ADR-072 smoke test).
        let moveAfter = UserDefaults.standard.double(forKey: "ClinicMoveToNewWindowAfterLaunch")
        if moveAfter > 0 { Task { try? await Task.sleep(for: .seconds(moveAfter)); if let t = tabs.selectedTab { tabs.moveToNewWindow(t) } } }
        // `-ClinicMarketplaceOnLaunch YES [-ClinicMarketplaceSection discover|installed|marketplaces]`
        // [-ClinicMarketplaceSelect <plugin@marketplace>] [-ClinicMarketplaceQuery <text>] (ADR-084 smoke test):
        // the screen has states — a selected plugin's detail, a filtered list — no click-free run could reach.
        if UserDefaults.standard.bool(forKey: "ClinicMarketplaceOnLaunch") {
            if let raw = UserDefaults.standard.string(forKey: "ClinicMarketplaceSection"),
               let section = MarketplaceModel.Section(rawValue: raw) { marketplace.section = section }
            if let q = UserDefaults.standard.string(forKey: "ClinicMarketplaceQuery") { marketplace.query = q }
            Task {
                try? await Task.sleep(for: .seconds(1))
                tabs.activeWindow.screen = .marketplace
                if let id = UserDefaults.standard.string(forKey: "ClinicMarketplaceSelect") {
                    // Wait for the catalogue the screen loads on appear before pointing at a row in it.
                    for _ in 0..<40 where self.marketplace.selectedId == nil {
                        if self.marketplace.hasLoaded { self.marketplace.selectedId = id; break }
                        try? await Task.sleep(for: .milliseconds(250))
                    }
                }
            }
        }
        // `-ClinicPreferencesOnLaunch <tab>`: open Preferences (ADR-073 smoke test).
        if UserDefaults.standard.bool(forKey: "ClinicPreferencesOnLaunch") {
            Task { try? await Task.sleep(for: .seconds(2)); NotificationCenter.default.post(name: .clinicOpenSettings, object: nil) }
        }
        // `-ClinicCaffeineOnLaunch YES`: hold the sleep assertion (ADR-075 smoke test; check with `pmset -g assertions`).
        if UserDefaults.standard.bool(forKey: "ClinicCaffeineOnLaunch") { caffeine.isOn = true }
        // `-ClinicCloseSecondaryAfterLaunch <seconds>`: close the newest secondary window so its tabs re-home (ADR-072 smoke test).
        let closeAfter = UserDefaults.standard.double(forKey: "ClinicCloseSecondaryAfterLaunch")
        if closeAfter > 0 { Task { try? await Task.sleep(for: .seconds(closeAfter)); tabs.windows.last(where: { !$0.isPrimary })?.nsWindow?.performClose(nil) } }
        // `-ClinicSelectModeOnLaunch YES`: sidebar select mode (ADR-074 smoke test).
        if UserDefaults.standard.bool(forKey: "ClinicSelectModeOnLaunch") { Task { try? await Task.sleep(for: .seconds(2)); tabs.activeWindow.selectMode = true } }
        // `-ClinicForkOnLaunch <session-id>`: fork an existing session (ADR-063).
        if let raw = UserDefaults.standard.string(forKey: "ClinicForkOnLaunch"), !raw.isEmpty {
            Task { await sessions.initialScan?.value; if let s = sessions.sessions[SessionID(raw)] { tabs.fork(s) } }
        }
    }

    /// If Clinic was launched from inside a Claude Code session (e.g. `open` from a terminal), the CLI's
    /// marker variables would make every session Clinic starts look like a nested child session and
    /// disable transcript saving. Shells spawned by libghostty inherit Clinic's environment, so unset them here.
    private func scrubInheritedClaudeEnvironment() {
        let keep: Set<String> = ["CLAUDE_CONFIG_DIR"]
        let exact: Set<String> = ["CLAUDECODE", "CLAUDE_PID", "CLAUDE_EFFORT"]
        for key in ProcessInfo.processInfo.environment.keys where (exact.contains(key) || key.hasPrefix("CLAUDE_CODE_")) && !keep.contains(key) {
            unsetenv(key)
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        tabs.runtime?.setFocus(true)
        tabs.selectedTab?.unread = false
        tabs.updateBadge()
    }
    func applicationDidResignActive(_ notification: Notification) { tabs.runtime?.setFocus(false) }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        // An explicit quit switches the wake agent off until the next login (ADR-095).
        AutomationWake.suppressUntilNextLogin()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let running = tabs.runningCount
        if running > 0 {
            switch WindowLifecycle.quitChoice(runningCount: running) {
            case .cancel: return .terminateCancel
            case .hide: NSApp.windows.forEach { if $0.canBecomeMain { $0.orderOut(nil) } }; return .terminateCancel
            case .backgroundAll:
                for tab in tabs.tabs where tab.sessionId != nil && tab.state == .idle { tabs.background(tab) }
                Task { try? await Task.sleep(for: .seconds(3)); self.finishTermination() }
                return .terminateLater
            case .quit:
                for tab in tabs.tabs where tab.isRunningClaude && !tab.isAttached { tabs.stop(tab) }
                Task {
                    // Bounded wait for clean exits, then tear down.
                    for _ in 0..<25 { if self.tabs.tabs.allSatisfy({ $0.state == .exited || $0.state == nil || $0.childExited }) { break }; try? await Task.sleep(for: .milliseconds(200)) }
                    self.finishTermination()
                }
                return .terminateLater
            }
        }
        finishTermination()
        return .terminateLater
    }

    private func finishTermination() {
        FileWindowController.closeAll()
        for tab in tabs.tabs { tab.surface.free(); tab.panelSurface?.free() }
        hooks.stop()
        mcp.stop()
        Task { await sessions.flush(); NSApp.reply(toApplicationShouldTerminate: true) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { WindowLifecycle.showMainWindow() }
        return true
    }
}

struct ClinicCommands: Commands {
    let tabs: TabStore
    let bindings: KeyBindings
    let caffeine: CaffeineController
    var sessions: SessionStore { tabs.sessions }
    private var selectedSession: SessionSummary? { tabs.selectedTab?.sessionId.flatMap { sessions.sessions[$0] } }
    private func key(_ a: ShortcutAction) -> KeyboardShortcut? { bindings.shortcut(for: a) }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Session") { tabs.startNewSession() }.keyboardShortcut(key(.newSession))
            Button("New Session in Folder…") { NotificationCenter.default.post(name: .clinicNewSession, object: nil) }.keyboardShortcut(key(.newSessionInFolder))
            Button("New Chat") { tabs.newChat() }.keyboardShortcut(key(.newChat))
            Button("New Shell") { tabs.newShell() }.keyboardShortcut(key(.newShell))
            Button("New Window") { tabs.openNewWindow() }.keyboardShortcut(key(.newWindow))
            Divider()
            Button("Close Tab") { if tabs.editingDraft != nil { tabs.closeDraftScreen() } else { tabs.closeSelected() } }.keyboardShortcut(key(.closeTab)).disabled(tabs.selectedTab == nil && tabs.editingDraft == nil)
        }
        CommandMenu("Session") {
            Button("Rename…") { if let s = selectedSession { SessionActions.rename(s, sessions: sessions) } }
                .keyboardShortcut(key(.renameSession)).disabled(selectedSession == nil)
            Button(selectedSession.map { sessions.isFavorite($0.id) } == true ? "Remove from Favorites" : "Add to Favorites") {
                if let s = selectedSession { sessions.toggleFavorite(s.id) }
            }.keyboardShortcut(key(.toggleFavorite)).disabled(selectedSession == nil)
            Button("Archive") { if let s = selectedSession { SessionActions.archive(s, sessions: sessions, tabs: tabs) } }
                .keyboardShortcut(key(.archiveSession)).disabled(selectedSession == nil)
            Button("Undo Archive") { sessions.undoArchive() }
                .keyboardShortcut(key(.undoArchive)).disabled(!sessions.canUndoArchive)
            Button("Stop Session") { if let t = tabs.selectedTab { tabs.stop(t) } }
                .keyboardShortcut(key(.stopSession)).disabled(!tabs.canStopSelected)
            Button("Fork Session") { if let s = selectedSession { tabs.fork(s) } }.keyboardShortcut(key(.forkSession)).disabled(selectedSession == nil)
            Button("Background This Session") { if let t = tabs.selectedTab { tabs.background(t) } }
                .keyboardShortcut(key(.backgroundSession)).disabled(!tabs.canBackgroundSelected)
            Button("Details…") { NotificationCenter.default.post(name: .clinicSessionDetails, object: nil) }
                .keyboardShortcut(key(.sessionDetails)).disabled(selectedSession == nil)
            Button("Replay…") { if let s = selectedSession { tabs.openReplay(s) } }
                .keyboardShortcut(key(.replaySession)).disabled(selectedSession == nil)
            Divider()
            Button("Jump to Session…") { NotificationCenter.default.post(name: .clinicQuickSwitch, object: nil) }
                .keyboardShortcut(key(.jumpToSession))
        }
        CommandGroup(after: .sidebar) {
            Button("MCP Servers") { NotificationCenter.default.post(name: .clinicMCPServers, object: nil) }.keyboardShortcut(key(.mcpServers))
            Button("Marketplace") { NotificationCenter.default.post(name: .clinicMarketplace, object: nil) }.keyboardShortcut(key(.marketplace))
            Button("Automations") { NotificationCenter.default.post(name: .clinicAutomations, object: nil) }.keyboardShortcut(key(.automations))
            Toggle("Select Sessions", isOn: Binding(get: { tabs.activeWindow.selectMode }, set: { tabs.activeWindow.selectMode = $0 })).keyboardShortcut(key(.selectSessions))
            Toggle("Caffeine Mode", isOn: Binding(get: { caffeine.isOn }, set: { caffeine.isOn = $0 })).keyboardShortcut(key(.caffeine))
            Toggle("Show Archived Sessions", isOn: Binding(get: { sessions.showArchived }, set: { sessions.showArchived = $0 }))
            Toggle("Show Tab Bar", isOn: Binding(get: { UserDefaults.standard.bool(forKey: "ClinicShowTabBar") }, set: { UserDefaults.standard.set($0, forKey: "ClinicShowTabBar") }))
            Toggle("Show Folder Paths", isOn: Binding(get: { UserDefaults.standard.bool(forKey: "ClinicShowFolderPaths") }, set: { UserDefaults.standard.set($0, forKey: "ClinicShowFolderPaths") }))
            Picker("Sort Sessions By", selection: Binding(get: { UserDefaults.standard.string(forKey: "ClinicSessionSort") ?? "activity" }, set: { UserDefaults.standard.set($0, forKey: "ClinicSessionSort"); sessions.update { _ in } })) {
                Text("Last Activity").tag("activity"); Text("Creation Time").tag("created")
            }
            Divider()
            Button("Collapse All Projects") { sessions.collapseAll() }
            Button("Expand All Projects") { sessions.expandAll() }
        }
        CommandMenu("Panel") {
            Button(tabs.selectedTab?.panel.isVisible == true ? "Hide Panel" : "Show Panel") { tabs.togglePanelVisibility() }
                .keyboardShortcut(key(.togglePanelVisibility)).disabled(tabs.selectedTab == nil)
            Button(tabs.selectedTab?.panel.isZoomed == true ? "Unzoom Panel" : "Zoom Panel") { tabs.togglePanelZoom() }
                .keyboardShortcut(key(.zoomPanel)).disabled(tabs.selectedTab == nil)
            Toggle("Show File Tree", isOn: Binding(get: { EditorPrefs.shared.showTree }, set: { EditorPrefs.shared.showTree = $0 }))
                .keyboardShortcut(key(.toggleFileTree)).disabled(!tabs.isFilesPaneFront)
            Divider()
            Button("Terminal") { tabs.togglePanel() }.keyboardShortcut(key(.togglePanel)).disabled(tabs.selectedTab == nil)
            Button("Diff") { tabs.toggleDiffPanel() }.keyboardShortcut(key(.toggleDiffPage)).disabled(tabs.selectedTab == nil)
            Button("Files") { tabs.toggleEditor() }.keyboardShortcut(key(.toggleEditor)).disabled(tabs.selectedTab == nil)
            Button("Images") { tabs.toggleAttachments() }.keyboardShortcut(key(.toggleAttachments)).disabled(tabs.selectedTab?.sessionId == nil)
            Button("Pull Request") { tabs.togglePRPage() }.keyboardShortcut(key(.togglePRPage)).disabled(tabs.selectedTab.map { tabs.pullRequests(for: $0).isEmpty } ?? true)
            Divider()
            Button("Next Panel Tab") { tabs.cyclePanelTab(1) }.keyboardShortcut(key(.nextPanelTab)).disabled((tabs.selectedTab?.panel.panes.count ?? 0) < 2)
            Button("Previous Panel Tab") { tabs.cyclePanelTab(-1) }.keyboardShortcut(key(.previousPanelTab)).disabled((tabs.selectedTab?.panel.panes.count ?? 0) < 2)
            Button("Close Panel Tab") { tabs.closeFrontPane() }.keyboardShortcut(key(.closePanelTab)).disabled(tabs.selectedTab?.panel.selected == nil)
        }
        CommandMenu("Tabs") {
            Button("Move Tab to New Window") { if let t = tabs.selectedTab { tabs.moveToNewWindow(t) } }.keyboardShortcut(key(.moveTabToNewWindow)).disabled(tabs.selectedTab == nil)
            Divider()
            Button("Next Tab") { tabs.selectNext(1) }.keyboardShortcut(key(.nextTab))
            Button("Previous Tab") { tabs.selectNext(-1) }.keyboardShortcut(key(.previousTab))
            Divider()
            ForEach(0..<9, id: \.self) { i in
                Button("Tab \(i + 1)") { tabs.selectIndex(i) }.keyboardShortcut(KeyEquivalent(Character(String(i + 1))), modifiers: .command)
            }
        }
    }
}

extension Notification.Name {
    static let clinicNewSession = Notification.Name("com.r0adkll.clinic.newSession")
    static let clinicQuickSwitch = Notification.Name("com.r0adkll.clinic.quickSwitch")
    static let clinicSessionDetails = Notification.Name("com.r0adkll.clinic.sessionDetails")
    static let clinicMCPServers = Notification.Name("com.r0adkll.clinic.mcpServers")
    static let clinicMarketplace = Notification.Name("com.r0adkll.clinic.marketplace")
    static let clinicAutomations = Notification.Name("com.r0adkll.clinic.automations")
    static let clinicGenerateIcon = Notification.Name("com.r0adkll.clinic.generateIcon")
    static let clinicOpenWindow = Notification.Name("com.r0adkll.clinic.openWindow")
    static let clinicOpenSettings = Notification.Name("com.r0adkll.clinic.openSettings")
}
