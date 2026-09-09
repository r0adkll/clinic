import AppKit
import Observation
import os
import ClinicCore

/// Menu bar item mirroring session state and unread count (ADR-067).
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private var item: NSStatusItem?
    private let tabs: TabStore
    private let history: NotificationStore
    private let caffeine: CaffeineController
    private let menu = NSMenu()
    private static let log = Logger(subsystem: "com.r0adkll.clinic", category: "statusitem")

    init(tabs: TabStore, history: NotificationStore, caffeine: CaffeineController) {
        self.tabs = tabs; self.history = history; self.caffeine = caffeine
        super.init()
        menu.delegate = self
        applyPreference()
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.applyPreference() }
        }
    }

    private var enabled: Bool { UserDefaults.standard.object(forKey: "ClinicShowStatusItem") as? Bool ?? true }

    private func applyPreference() {
        if enabled, item == nil {
            let i = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            i.menu = menu
            i.button?.imagePosition = .imageLeading
            i.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            item = i
            observe()
        } else if !enabled, let i = item {
            NSStatusBar.system.removeStatusItem(i); item = nil
        }
    }

    /// Re-armed on every change of the observed properties.
    private func observe() {
        withObservationTracking {
            render()
        } onChange: {
            Task { @MainActor [weak self] in self?.observe() }
        }
    }

    private func render() {
        guard let button = item?.button else { return }
        let working = tabs.tabs.contains { $0.state == .working || $0.state == .launching }
        let unread = tabs.tabs.filter { $0.unread || ($0.state?.isWaiting ?? false) }.count + history.entries.filter { !$0.read && $0.sessionId == nil }.count
        let symbol = unread > 0 ? "bell.badge.fill" : working ? "circle.dotted" : "circle"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Clinic") ?? NSImage(systemSymbolName: "circle", accessibilityDescription: "Clinic")
        image?.isTemplate = true
        button.image = image
        button.title = unread > 0 ? " \(unread)" : ""
        item?.length = unread > 0 ? NSStatusItem.variableLength : 28
        Self.log.debug("status item symbol=\(symbol, privacy: .public) unread=\(unread) frame=\(String(describing: button.window?.frame), privacy: .public)")
        button.toolTip = working ? "Clinic — a session is working" : unread > 0 ? "Clinic — \(unread) need attention" : "Clinic"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let sessionTabs = tabs.tabs.filter { $0.sessionId != nil }
        if sessionTabs.isEmpty {
            let none = NSMenuItem(title: "No open sessions", action: nil, keyEquivalent: ""); none.isEnabled = false; menu.addItem(none)
        }
        for tab in sessionTabs {
            // Same precedence as StateGlyph (ADR-096): live state first, then the unread flag.
            let glyph: String = switch tab.state {
            case .working, .launching: "◐"
            case .waitingForPermission, .waitingForInput: "!"
            case .exited: tab.unread ? "●" : "○"
            default: tab.unread ? "●" : "·"
            }
            let mi = NSMenuItem(title: "\(glyph) \(tab.title)", action: #selector(reveal(_:)), keyEquivalent: "")
            mi.target = self; mi.representedObject = tab.id
            menu.addItem(mi)
        }
        menu.addItem(.separator())
        let show = NSMenuItem(title: "Show Clinic", action: #selector(showApp), keyEquivalent: ""); show.target = self; menu.addItem(show)
        let new = NSMenuItem(title: "New Session…", action: #selector(newSession), keyEquivalent: ""); new.target = self; menu.addItem(new)
        let caf = NSMenuItem(title: "Caffeine Mode", action: #selector(toggleCaffeine), keyEquivalent: ""); caf.target = self; caf.state = caffeine.isOn ? .on : .off; menu.addItem(caf)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Clinic", action: #selector(quit), keyEquivalent: ""); quit.target = self; menu.addItem(quit)
    }

    @objc private func reveal(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID, let tab = tabs.tabs.first(where: { $0.id == id }) else { return }
        showApp()
        tabs.select(tab)
    }
    @objc private func toggleCaffeine() { caffeine.isOn.toggle() }
    @objc private func showApp() { WindowLifecycle.showMainWindow() }
    @objc private func newSession() { showApp(); NotificationCenter.default.post(name: .clinicNewSession, object: tabs.selectedTab?.projectPath) }
    @objc private func quit() { NSApp.terminate(nil) }
}
