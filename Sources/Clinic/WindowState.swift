import AppKit
import SwiftUI
import Observation
import ClinicCore
import GhosttyBridge

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

    /// A destination that fills the content area instead of a tab, because it owns no session.
    ///
    /// One optional rather than a boolean per screen (ADR-093): the mutual exclusion between content
    /// modes is pairwise, so a third and fourth boolean would have cost twelve `didSet` assignments
    /// to keep straight. Adding a screen is now a new case.
    enum Screen: Hashable {
        case tasks         // ADR-112
        case marketplace   // ADR-084
        case mcpServers    // ADR-093
        case automations   // ADR-095
        case sounds        // ADR-199

        var title: String {
            switch self {
            case .tasks: "Tasks"
            case .marketplace: "Marketplace"
            case .mcpServers: "MCP Servers"
            case .automations: "Automations"
            case .sounds: "Sounds"
            }
        }
    }

    var selectedTabId: UUID? {
        didSet {
            guard selectedTabId != oldValue else { return }
            if selectedTabId != nil {
                if editingDraft != nil { editingDraft = nil }
                screen = nil
            }
            store?.selectionChanged(in: self)
        }
    }
    /// The new-session screen shown in the content area (ADR-071); selecting a tab dismisses it (text kept per project).
    var editingDraft: NewSessionDraft? {
        didSet {
            guard editingDraft != nil else { return }
            if selectedTabId != nil { selectedTabId = nil }
            screen = nil
        }
    }
    /// The Marketplace or MCP Servers screen. Like the draft screen it fills the content area instead
    /// of a tab, so the three are mutually exclusive; showing one clears the other two.
    var screen: Screen? {
        didSet {
            guard screen != nil, screen != oldValue else { return }
            selectedTabId = nil
            editingDraft = nil
        }
    }
    /// Sidebar select mode and the multi-selection (ADR-074).
    var selectMode = false { didSet { if !selectMode { bulkSelection = [] } } }
    var bulkSelection: Set<SidebarItem> = []
    /// What this window's Tasks screen shows (ADR-112); each window keeps its own.
    let tasks = TasksViewState()
    /// The project group this window's sidebar shows, nil for all of them (ADR-210). Each window
    /// keeps its own; the main window's is remembered across launches, since only its geometry is
    /// restored (ADR-042) and other windows open fresh, on All.
    var groupScope: UUID? {
        didSet {
            guard isPrimary, groupScope != oldValue else { return }
            UserDefaults.standard.set(groupScope?.uuidString, forKey: Self.groupScopeKey)
        }
    }
    static let groupScopeKey = "ClinicGroupScope"

    /// True while the content area belongs to a screen rather than a tab: no tab bar, no footer, no terminals.
    var isShowingScreen: Bool { screen != nil || editingDraft != nil }

    init(id: UUID, isPrimary: Bool) {
        self.id = id; self.isPrimary = isPrimary
        if isPrimary { groupScope = UserDefaults.standard.string(forKey: Self.groupScopeKey).flatMap(UUID.init(uuidString:)) }
    }

    /// What the window is showing, in words: a screen, the composer or the selected session, for
    /// *Move to Window ▸*. The `NSWindow` itself has no title, which the toolbar would draw beside the
    /// header that already names it (ADR-212).
    var title: String {
        if let screen { return screen.title }
        if editingDraft != nil { return "New session" }
        return store.flatMap { $0.selectedTab(in: self)?.title } ?? "Clinic"
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
    @Environment(KeyBindings.self) private var bindings
    let live: [Tab]
    let selectedId: UUID?
    let visible: Bool
    /// Per-tab panel/page facts read in the body so SwiftUI re-runs `updateNSView` when they change.
    let keys: [String]

    func makeNSView(context: Context) -> TerminalStackView { TerminalStackView() }

    func updateNSView(_ v: TerminalStackView, context: Context) {
        v.sync(tabs: live, selected: selectedId, visible: visible)
        for tab in live {
            tab.contentView.setMain(mainContent(tab))
            tab.contentView.setPanel(panelContent(tab))
        }
        if visible, let tab = live.first(where: { $0.id == selectedId }) {
            DispatchQueue.main.async {
                // What the main area shows takes the keyboard back — Claude, or a shell in front of it —
                // but not from a right-panel shell the reader is
                // in, and not out of a pane they are using (ADR-212).
                let target: GhosttySurfaceView? = tab.isClaudeInFront ? tab.surface
                    : tab.main.selected?.terminal
                guard let target, let w = tab.surface.window, w.firstResponder !== target,
                      !(tab.focusedArea == .right && tab.panel.isFront(.terminal)),
                      !tab.contentView.panelHoldsKeyboard, !tab.contentView.mainPaneHoldsKeyboard else { return }
                w.makeFirstResponder(target)
            }
        }
    }

    /// Each of these becomes an `NSHostingView` root of its own, so it gets the accent as well as the
    /// stores; neither crosses from the window's root into a separate hosting view (ADR-152).
    private func inject<V: View>(_ view: V) -> AnyView {
        AnyView(view.environment(tabs).environment(sessions).environment(prs).environment(history).environment(usage)
            .environment(bindings).clinicAppearance())
    }

    /// Panel pages fill their hosting view, so a page whose ideal size is small does not float in it.
    private func page<V: View>(_ view: V) -> AnyView {
        inject(view.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading))
    }

    /// The main area (ADR-212): its strip, over Claude while the pinned tab is in front, or the pane that is.
    private func mainContent(_ tab: Tab) -> TabContentView.PanelContent {
        let chrome = inject(PaneTabStrip(tab: tab, area: .main))
        guard let pane = tab.main.selected else {
            return TabContentView.PanelContent(chrome: chrome, page: nil, terminal: nil, showsAgent: true,
                                               minWidth: 360)
        }
        return content(of: pane, in: tab, chrome: chrome)
    }

    /// The chrome and the front pane's content for one tab's panel (ADR-079); nil when the panel is hidden.
    private func panelContent(_ tab: Tab) -> TabContentView.PanelContent? {
        guard tab.panel.isVisible else { return nil }
        let chrome = inject(PaneTabStrip(tab: tab, area: .right))
        guard let pane = tab.panel.selected else {
            return TabContentView.PanelContent(chrome: chrome, page: page(SidePanelEmptyState(tab: tab)),
                                               terminal: nil, minWidth: 320)
        }
        return content(of: pane, in: tab, chrome: chrome)
    }

    /// One pane's page or surface, in whichever area it is.
    private func content(of pane: PanelPane, in tab: Tab, chrome: AnyView) -> TabContentView.PanelContent {
        var page: AnyView?
        var terminal: GhosttySurfaceView?
        var header: AnyView?
        var footer: AnyView?
        switch pane.kind {
        case .terminal: terminal = pane.terminal
        case .diff: page = pane.diff.map { self.page(DiffPanel(tab: tab, model: $0)) }
        case .files: page = pane.editor.map { self.page(EditorPanel(tab: tab, model: $0)) }
        case .attachments: page = pane.images.map { self.page(AttachmentsPanel(tab: tab, gallery: $0)) }
        case .grill: page = pane.grill.map { self.page(GrillPane(tab: tab, model: $0)) }
        case .pr(let ref): page = self.page(PRPage(tab: tab, ref: ref))
        case .run(let key):
            // Only the tab holding the run shows its surface; any other shows why not (ADR-122).
            if let run = tabs.runs.run(forKey: key), let surface = run.surface, run.hostTabId == tab.id {
                terminal = surface
                header = inject(RunPaneHeader(run: run, tab: tab))
                if run.status.isFailure { footer = inject(RunFailureBar(run: run, tab: tab)) }
            } else {
                page = self.page(RunPanePlaceholder(runKey: key, tab: tab))
            }
        }
        return TabContentView.PanelContent(chrome: chrome, page: page,
                                           terminal: terminal, terminalHeader: header, terminalFooter: footer,
                                           minWidth: pane.kind.minWidth)
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
