import SwiftUI
import ClinicCore
import GhosttyBridge

@main
struct ClinicApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Clinic") {
            RootView()
                .environment(appDelegate.tabs)
                .environment(appDelegate.sessions)
                .environment(appDelegate.history)
                .environment(appDelegate.usage)
                .environment(appDelegate.prs)
                .environment(appDelegate.backgroundAgents)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1180, height: 760)
        .commands { ClinicCommands(tabs: appDelegate.tabs) }
        Settings { PreferencesView() }
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
    var statusItem: StatusItemController?
    lazy var tabs = TabStore(sessions: sessions, hooks: hooks, notifications: notifications, history: history)

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: ["ClinicShowUsage": true, "ClinicShowTabBar": true, "ClinicUsageExpanded": true])
        scrubInheritedClaudeEnvironment()
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
        backgroundAgents.start(sessions: sessions, history: history, notifications: notifications)
        statusItem = StatusItemController(tabs: tabs, history: history)
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
        // Hidden smoke-test key (ADR-038): `open Clinic.app --args -ClinicOpenShellOnLaunch YES`
        if UserDefaults.standard.bool(forKey: "ClinicOpenShellOnLaunch") {
            tabs.newShell(in: UserDefaults.standard.string(forKey: "ClinicShellDirectory"))
            if UserDefaults.standard.bool(forKey: "ClinicOpenPanelOnLaunch") { tabs.togglePanel() }
            if UserDefaults.standard.bool(forKey: "ClinicOpenGitPageOnLaunch") { tabs.toggleGitPage() }
            if UserDefaults.standard.bool(forKey: "ClinicOpenEditorOnLaunch") {
                tabs.toggleEditor()
                if let file = UserDefaults.standard.string(forKey: "ClinicOpenFileOnLaunch") { tabs.selectedTab?.editor?.open(absolute: file) }
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
            tabs.newSession(projectPath: path, model: "haiku", worktree: false)
            // `-ClinicStopAfterLaunch <seconds>`: exercise the graceful Stop path (ADR-063).
            // `-ClinicSwitchModelAfterLaunch <alias>`: exercise /model via the footer path (ADR-064).
            if let alias = UserDefaults.standard.string(forKey: "ClinicSwitchModelAfterLaunch"), !alias.isEmpty {
                Task { try? await Task.sleep(for: .seconds(9)); if let t = tabs.selectedTab { tabs.switchModel(t, to: alias) } }
            }
            let stopAfter = UserDefaults.standard.double(forKey: "ClinicStopAfterLaunch")
            if stopAfter > 0 { Task { try? await Task.sleep(for: .seconds(stopAfter)); if let t = tabs.selectedTab { tabs.stop(t) } } }
        }
        if UserDefaults.standard.bool(forKey: "ClinicNewChatOnLaunch") { tabs.newChat() }
        // `-ClinicSelectTabAfterLaunch <index>`: select a tab once launch tabs exist (attention smoke tests).
        if UserDefaults.standard.object(forKey: "ClinicSelectTabAfterLaunch") != nil {
            let i = UserDefaults.standard.integer(forKey: "ClinicSelectTabAfterLaunch")
            Task { try? await Task.sleep(for: .seconds(4)); tabs.selectIndex(i) }
        }
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

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let running = tabs.runningCount
        if running > 0 && !tabs.confirmClose(count: running) { return .terminateCancel }
        for tab in tabs.tabs { tab.surface.free() }
        hooks.stop()
        mcp.stop()
        Task { await sessions.flush(); NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}

struct ClinicCommands: Commands {
    let tabs: TabStore
    var sessions: SessionStore { tabs.sessions }
    private var selectedSession: SessionSummary? { tabs.selectedTab?.sessionId.flatMap { sessions.sessions[$0] } }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Session…") { NotificationCenter.default.post(name: .clinicNewSession, object: tabs.selectedTab?.projectPath) }.keyboardShortcut("n", modifiers: .command)
            Button("New Chat") { tabs.newChat() }.keyboardShortcut("n", modifiers: [.command, .option])
            Button("New Shell") { tabs.newShell() }.keyboardShortcut("t", modifiers: .command)
            Divider()
            Button("Close Tab") { tabs.closeSelected() }.keyboardShortcut("w", modifiers: .command).disabled(tabs.selectedTab == nil)
        }
        CommandMenu("Session") {
            Button("Rename…") { if let s = selectedSession { SessionActions.rename(s, sessions: sessions) } }
                .keyboardShortcut("r", modifiers: [.command, .shift]).disabled(selectedSession == nil)
            Button(selectedSession.map { sessions.isFavorite($0.id) } == true ? "Remove from Favorites" : "Add to Favorites") {
                if let s = selectedSession { sessions.toggleFavorite(s.id) }
            }.keyboardShortcut("d", modifiers: [.command, .shift]).disabled(selectedSession == nil)
            Button("Archive") { if let s = selectedSession { SessionActions.archive(s, sessions: sessions, tabs: tabs) } }
                .keyboardShortcut("a", modifiers: [.command, .shift]).disabled(selectedSession == nil)
            Button("Undo Archive") { sessions.undoArchive() }
                .keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!sessions.canUndoArchive)
            Button("Stop Session") { if let t = tabs.selectedTab { tabs.stop(t) } }
                .keyboardShortcut(".", modifiers: .command).disabled(!tabs.canStopSelected)
            Button("Fork Session") { if let s = selectedSession { tabs.fork(s) } }.disabled(selectedSession == nil)
            Button("Background This Session") { if let t = tabs.selectedTab { tabs.background(t) } }
                .keyboardShortcut("b", modifiers: [.command, .option]).disabled(!tabs.canBackgroundSelected)
            Button("Details…") { NotificationCenter.default.post(name: .clinicSessionDetails, object: nil) }
                .keyboardShortcut("i", modifiers: .command).disabled(selectedSession == nil)
            Button("Replay…") { if let s = selectedSession { tabs.openReplay(s) } }
                .keyboardShortcut("r", modifiers: [.command, .option]).disabled(selectedSession == nil)
            Divider()
            Button("Jump to Session…") { NotificationCenter.default.post(name: .clinicQuickSwitch, object: nil) }
                .keyboardShortcut("k", modifiers: .command)
        }
        CommandGroup(after: .sidebar) {
            Button("MCP Servers…") { NotificationCenter.default.post(name: .clinicMCPServers, object: nil) }.keyboardShortcut("m", modifiers: [.command, .shift])
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
        CommandMenu("Tabs") {
            Button("Toggle Terminal Panel") { tabs.togglePanel() }.keyboardShortcut("j", modifiers: .command).disabled(tabs.selectedTab == nil)
            Button("Toggle Git Page") { tabs.toggleGitPage() }.keyboardShortcut("g", modifiers: [.command, .shift]).disabled(tabs.selectedTab == nil)
            Button("Toggle Editor") { tabs.toggleEditor() }.keyboardShortcut("e", modifiers: [.command, .shift]).disabled(tabs.selectedTab == nil)
            Button("Toggle Attachments") { tabs.toggleAttachments() }.keyboardShortcut("i", modifiers: [.command, .shift]).disabled(tabs.selectedTab?.sessionId == nil)
            Button("Toggle Pull Request Page") { tabs.togglePRPage() }.keyboardShortcut("p", modifiers: [.command, .shift]).disabled(tabs.selectedTab.map { tabs.pullRequests(for: $0).isEmpty } ?? true)
            Divider()
            Button("Next Tab") { tabs.selectNext(1) }.keyboardShortcut("]", modifiers: [.command, .shift])
            Button("Previous Tab") { tabs.selectNext(-1) }.keyboardShortcut("[", modifiers: [.command, .shift])
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
}
