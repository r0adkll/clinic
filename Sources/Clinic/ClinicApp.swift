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
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1180, height: 760)
        .commands { ClinicCommands(tabs: appDelegate.tabs) }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let sessions = SessionStore()
    let hooks = HookService()
    let notifications = NotificationService()
    lazy var tabs = TabStore(sessions: sessions, hooks: hooks, notifications: notifications)

    func applicationDidFinishLaunching(_ notification: Notification) {
        scrubInheritedClaudeEnvironment()
        notifications.requestAuthorization()
        hooks.start()
        sessions.start()
        tabs.start()
        // Hidden smoke-test key (ADR-038): `open Clinic.app --args -ClinicOpenShellOnLaunch YES`
        if UserDefaults.standard.bool(forKey: "ClinicOpenShellOnLaunch") { tabs.newShell() }
        // `-ClinicNewSessionOnLaunch /path/to/project` starts a Claude session there (smoke test for the hook binding).
        if let path = UserDefaults.standard.string(forKey: "ClinicNewSessionOnLaunch"), !path.isEmpty {
            tabs.newSession(projectPath: path, model: "haiku", worktree: false)
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
            Button("New Session…") { NotificationCenter.default.post(name: .clinicNewSession, object: nil) }.keyboardShortcut("n", modifiers: .command)
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
            Divider()
            Button("Jump to Session…") { NotificationCenter.default.post(name: .clinicQuickSwitch, object: nil) }
                .keyboardShortcut("k", modifiers: .command)
        }
        CommandGroup(after: .sidebar) {
            Toggle("Show Archived Sessions", isOn: Binding(get: { sessions.showArchived }, set: { sessions.showArchived = $0 }))
        }
        CommandMenu("Tabs") {
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
}
