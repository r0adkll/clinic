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
        notifications.requestAuthorization()
        hooks.start()
        sessions.start()
        tabs.start()
        // Hidden smoke-test key (ADR-038): `open Clinic.app --args -ClinicOpenShellOnLaunch YES`
        if UserDefaults.standard.bool(forKey: "ClinicOpenShellOnLaunch") { tabs.newShell() }
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

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Session…") { NotificationCenter.default.post(name: .clinicNewSession, object: nil) }.keyboardShortcut("n", modifiers: .command)
            Button("New Shell") { tabs.newShell() }.keyboardShortcut("t", modifiers: .command)
            Divider()
            Button("Close Tab") { tabs.closeSelected() }.keyboardShortcut("w", modifiers: .command).disabled(tabs.selectedTab == nil)
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
}
