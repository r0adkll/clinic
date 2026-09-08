import AppKit
import SwiftUI
import Observation
import ClinicCore

/// Per-window UI state (ADR-072): which tab is selected, the new-session screen, sidebar select mode.
/// Tabs and surfaces stay in the single `TabStore`; a `Tab.windowId` says where it is shown.
@MainActor
@Observable
final class WindowState: Identifiable {
    let id: UUID
    let isPrimary: Bool
    @ObservationIgnored weak var store: TabStore?
    @ObservationIgnored weak var nsWindow: NSWindow?
    @ObservationIgnored var lifecycle: WindowLifecycle?
    @ObservationIgnored var observers: [NSObjectProtocol] = []

    var selectedTabId: UUID? {
        didSet {
            guard selectedTabId != oldValue else { return }
            if selectedTabId != nil, editingDraft != nil { editingDraft = nil }
            store?.selectionChanged(in: self)
        }
    }
    /// The new-session screen shown in the content area (ADR-071); selecting a tab dismisses it (text kept per project).
    var editingDraft: NewSessionDraft? {
        didSet { if editingDraft != nil, selectedTabId != nil { selectedTabId = nil } }
    }
    /// Sidebar select mode and the multi-selection (ADR-074).
    var selectMode = false { didSet { if !selectMode { bulkSelection = [] } } }
    var bulkSelection: Set<SidebarItem> = []

    init(id: UUID, isPrimary: Bool) { self.id = id; self.isPrimary = isPrimary }

    var title: String { nsWindow?.title ?? "Clinic" }
}

/// Keeps the Mac awake while on (ADR-075). Not persisted; the assertion dies with the process.
@MainActor
@Observable
final class CaffeineController {
    var isOn = false { didSet { apply() } }
    @ObservationIgnored private var activity: NSObjectProtocol?

    private func apply() {
        if isOn, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled], reason: "Clinic caffeine mode")
        } else if !isOn, let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }
}

/// Reports the NSWindow a SwiftUI hierarchy landed in.
struct WindowAccessor: NSViewRepresentable {
    let onWindow: @MainActor (NSWindow) -> Void
    func makeNSView(context: Context) -> AccessorView { let v = AccessorView(); v.onWindow = onWindow; return v }
    func updateNSView(_ v: AccessorView, context: Context) {}

    final class AccessorView: NSView {
        var onWindow: (@MainActor (NSWindow) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { MainActor.assumeIsolated { onWindow?(window) } }
        }
    }
}

/// AppKit host for every live tab of one window (ADR-072). Adds each tab's persistent `TabContentView`,
/// hides the unselected ones, and removes only views that are still its own subviews — so a tab moved to
/// another window is simply re-parented, whichever window SwiftUI updates first.
@MainActor
final class TerminalStackView: NSView {
    func sync(tabs: [Tab], selected: UUID?, visible: Bool) {
        isHidden = !visible
        let wanted = tabs.map(\.contentView)
        for v in subviews where !wanted.contains(where: { $0 === v }) { v.removeFromSuperview() }
        for tab in tabs {
            let cv = tab.contentView
            if cv.superview !== self { addSubview(cv) }
            cv.frame = bounds
            cv.autoresizingMask = [.width, .height]
            cv.isHidden = tab.id != selected
        }
    }
    override func layout() { super.layout(); for v in subviews { v.frame = bounds } }
}

struct TerminalStack: NSViewRepresentable {
    @Environment(TabStore.self) private var tabs
    @Environment(SessionStore.self) private var sessions
    @Environment(PRStore.self) private var prs
    @Environment(NotificationStore.self) private var history
    @Environment(UsageService.self) private var usage
    let live: [Tab]
    let selectedId: UUID?
    let visible: Bool
    /// Per-tab panel/page facts read in the body so SwiftUI re-runs `updateNSView` when they change.
    let keys: [String]

    func makeNSView(context: Context) -> TerminalStackView { TerminalStackView() }

    func updateNSView(_ v: TerminalStackView, context: Context) {
        v.sync(tabs: live, selected: selectedId, visible: visible)
        for tab in live {
            tab.contentView.setPanel(tab.panelVisible ? tab.panelSurface : nil)
            let (page, minWidth) = pageContent(tab)
            tab.contentView.setPage(page, minWidth: minWidth)
        }
        if visible, let tab = live.first(where: { $0.id == selectedId }) {
            DispatchQueue.main.async {
                guard let w = tab.surface.window, w.firstResponder !== tab.surface, !tab.panelVisible else { return }
                w.makeFirstResponder(tab.surface)
            }
        }
    }

    private func inject<V: View>(_ view: V) -> AnyView {
        AnyView(view.environment(tabs).environment(sessions).environment(prs).environment(history).environment(usage))
    }

    private func pageContent(_ tab: Tab) -> (AnyView?, CGFloat) {
        switch tab.rightPane {
        case .none: return (nil, 320)
        case .git: return (tab.gitPage.map { inject(GitPage(tab: tab, model: $0)) }, 380)
        case .pr(let ref): return (inject(PRPage(tab: tab, ref: ref)), 380)
        case .attachments: return (inject(AttachmentsPanel(tab: tab)), 320)
        case .editor: return (tab.editor.map { inject(EditorPanel(tab: tab, model: $0)) }, 520)
        }
    }
}

/// "Move to New Window" and "Move to Window ▸" for a tab (ADR-072).
struct MoveToWindowMenu: View {
    @Environment(TabStore.self) private var tabs
    let tab: Tab

    var body: some View {
        Button("Move to New Window") { tabs.moveToNewWindow(tab) }
        let others = tabs.windows.filter { $0.id != tab.windowId && $0.nsWindow?.isVisible == true }
        if !others.isEmpty {
            Menu("Move to Window") {
                ForEach(others) { w in Button(w.title) { tabs.move(tab, to: w) } }
            }
        }
    }
}
