import SwiftUI
import os
import ClinicCore
import GhosttyBridge

struct RootView: View {
    /// Which `WindowState` this window renders (ADR-072); nil = the primary window the system opened.
    let windowValue: UUID?
    @Environment(TabStore.self) private var tabs
    @Environment(SessionStore.self) private var sessions
    @Environment(NotificationStore.self) private var history
    @Environment(KeyBindings.self) private var bindings
    @Environment(CaffeineController.self) private var caffeine
    @Environment(\.openWindow) private var openWindow
    @State private var showNewSession = false
    @State private var showSwitcher = false
    @State private var detailsFor: SessionSummary?
    @State private var iconProject: IconGenerationTarget?
    @State private var pullProject: Project?
    @State private var newSessionProject: String?
    @State private var runSheet: RunSheetRequest?

    private var windowId: UUID { windowValue ?? TabStore.primaryWindowId }
    private var window: WindowState { tabs.windowState(id: windowId) }
    /// App-wide requests (⌘K, details, folder picker…) are answered by the active window only.
    private var isActive: Bool { (tabs.activeWindowId ?? tabs.windows.first?.id) == windowId }

    var body: some View {
        let window = self.window
        NavigationSplitView {
            SidebarView(showNewSession: $showNewSession)
                .navigationSplitViewColumnWidth(min: 220, ideal: 300, max: 420)
        } detail: {
            DetailView()
        }
        .environment(window)
        .background(WindowAccessor { tabs.bind($0, to: window) })
        .frame(minWidth: 800, minHeight: 480)
        .overlay(alignment: .topTrailing) { if isActive { NotificationCard().animation(.easeOut(duration: 0.25), value: history.card?.id) } }
        .sheet(isPresented: $showNewSession) { NewSessionSheet(initialProject: newSessionProject) }
        .sheet(isPresented: $showSwitcher) { QuickSwitcher() }
        .sheet(item: $detailsFor) { SessionDetailsSheet(summary: $0) }
        .sheet(item: $iconProject) { GenerateIconSheet(target: $0) }
        .sheet(item: $pullProject) { PullSheet(target: $0) }
        .modifier(CloneRouting(isActive: isActive, showNewSession: $showNewSession))
        .sheet(item: $runSheet) { RunSheet(request: $0) }
        .onReceive(NotificationCenter.default.publisher(for: .clinicRunSheet)) { n in
            guard isActive, let request = n.object as? RunSheetRequest else { return }
            runSheet = request
        }
        .modifier(TasksRouting(window: window, isActive: isActive))
        .modifier(ScreenRouting(window: window, isActive: isActive))
        .onReceive(NotificationCenter.default.publisher(for: .clinicSessionDetails)) { n in
            guard isActive else { return }
            if let raw = n.object as? String { detailsFor = sessions.sessions[SessionID(raw)] }
            else if let id = tabs.selectedTab(in: window)?.sessionId { detailsFor = sessions.sessions[id] }
        }
        .onReceive(NotificationCenter.default.publisher(for: .clinicQuickSwitch)) { _ in if isActive { showSwitcher = true } }
        .onReceive(NotificationCenter.default.publisher(for: .clinicGenerateIcon)) { n in
            guard isActive, let path = n.object as? String else { return }
            iconProject = IconGenerationTarget(path: path)
        }
        .onReceive(NotificationCenter.default.publisher(for: .clinicGitPull)) { n in
            guard isActive, let path = n.object as? String else { return }
            pullProject = Project(path: path)
        }
        .onReceive(NotificationCenter.default.publisher(for: .clinicOpenSettings)) { _ in if isActive { openWindow(id: PreferencesView.windowID) } }
        .onReceive(NotificationCenter.default.publisher(for: .clinicOpenWindow)) { n in
            guard isActive, let id = n.object as? UUID else { return }
            openWindow(id: "main", value: id)
        }
        .alert("Could not open a terminal", isPresented: Binding(get: { isActive && tabs.lastSurfaceError != nil }, set: { if !$0 { tabs.lastSurfaceError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(tabs.lastSurfaceError ?? "") }
        .onReceive(NotificationCenter.default.publisher(for: .clinicNewSession)) { n in
            guard isActive else { return }
            newSessionProject = n.object as? String; showNewSession = true
        }
        .modifier(RootToolbar(window: window))
        // An empty title, so the toolbar draws only the header (ADR-212). The toolbar draws whatever
        // the window's title is, whatever its `titleVisibility`, and `.toolbar(removing: .title)` also
        // takes the flexible space that holds the controls at the trailing edge.
        .navigationTitle("")
    }

}

/// Presents the Clone sheet (ADR-168). Its own modifier because `RootView.body` is already as long
/// a chain as the type checker will take.
private struct CloneRouting: ViewModifier {
    let isActive: Bool
    @Binding var showNewSession: Bool
    @State private var request: CloneRequest?

    func body(content: Content) -> some View {
        content
            .sheet(item: $request) { CloneSheet(request: $0) }
            .onReceive(NotificationCenter.default.publisher(for: .clinicCloneProject)) { n in
                guard isActive else { return }
                let asked = n.object as? CloneRequest ?? CloneRequest()
                // Asked for from the New Session sheet: one sheet at a time, so that one leaves first.
                guard showNewSession else { request = asked; return }
                showNewSession = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { request = asked }
            }
    }
}

/// The window shows one session's workspace at a time (ADR-212): no session tab bar and no footer. The
/// sidebar lists the sessions, the toolbar's header names this one, and its own tab row is part of its
/// content view.
struct DetailView: View {
    @Environment(TabStore.self) private var tabs
    @Environment(WindowState.self) private var window

    var body: some View {
        let mine = tabs.tabs(in: window)
        let selected = mine.first { $0.id == window.selectedTabId }
        terminalArea(mine: mine, selected: selected)
    }

    private func terminalArea(mine: [Tab], selected: Tab?) -> some View {
        let live = mine.filter { $0.replay == nil }
        let showTerminals = tabs.startupError == nil && !window.isShowingScreen && !mine.isEmpty && selected?.replay == nil
        return ZStack {
            // Every live tab keeps its content view mounted in this window's stack; only the selected one is visible (ADR-019, ADR-072).
            // With no live tab there is nothing to keep mounted, and an empty stack left in place freezes
            // the width of everything else in this `ZStack` (ADR-149).
            if !live.isEmpty {
                TerminalStack(live: live, selectedId: window.selectedTabId, visible: showTerminals,
                              keys: live.map { "\($0.id)|\($0.main.renderKey)|\($0.panel.renderKey)|\($0.focusedArea)|\(tabs.runs.renderKey(for: $0))" })
            }
            ForEach(mine.filter { $0.replay != nil }) { tab in
                ReplayView(model: tab.replay!)
                    .opacity(tab.id == window.selectedTabId ? 1 : 0)
                    .allowsHitTesting(tab.id == window.selectedTabId)
            }
            if let error = tabs.startupError {
                ContentUnavailableView("libghostty failed to start", systemImage: "exclamationmark.triangle", description: Text(error))
                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(nsColor: .windowBackgroundColor))
            } else if window.screen == .tasks {
                TasksScreen()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if window.screen == .marketplace {
                MarketplaceScreen()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if window.screen == .automations {
                AutomationsScreen()
            } else if window.screen == .sounds {
                SoundsScreen()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if window.screen == .mcpServers {
                MCPServersScreen()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let draft = window.editingDraft {
                // One view per draft: reused across projects, the editor and ⌘↩ kept writing to and
                // sending the previous project's draft, and its git state outlived a switch to a non-repo.
                NewSessionScreen(draft: draft)
                    .id(draft.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(nsColor: .windowBackgroundColor))
            } else if mine.isEmpty {
                HomeScreen()
            } else if let tab = selected, tab.childExited {
                ExitedOverlay(tab: tab)
            }
        }
    }
}

/// Path and model-name formatting the footer used to own (milestone 2); the footer itself went with
/// ADR-212, its facts moving into the session header.
enum TabFooter {
    static func abbreviate(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    /// "claude-opus-5" → "Opus 5", "claude-haiku-4-5-20251001" → "Haiku 4.5".
    static func shortModel(_ id: String) -> String {
        var parts = id.split(separator: "-").map(String.init)
        if parts.first == "claude" { parts.removeFirst() }
        parts.removeAll { $0.count == 8 && Int($0) != nil }
        guard let family = parts.first else { return id }
        let version = parts.dropFirst().joined(separator: ".")
        return family.capitalized + (version.isEmpty ? "" : " " + version)
    }
}

/// Footer model chip: a menu that types `/model` when the session is idle (ADR-064), named by the status
/// line, which knows the model before the transcript does and follows a typed `/model` (ADR-196).
struct ModelMenu: View {
    @Environment(TabStore.self) private var tabs
    let tab: Tab
    /// The header's form (ADR-212): the name alone, at the line's own size.
    var compact = false
    private let aliases = ["default"] + ModelAlias.all
    private var modelId: String? { tab.statusLine?.modelId ?? tab.model }
    private var name: String? { tab.statusLine?.modelDisplayName ?? tab.model.map(TabFooter.shortModel) }

    var body: some View {
        Menu {
            ForEach(aliases, id: \.self) { a in
                Button(ModelAlias.title(a)) { tabs.switchModel(tab, to: a) }
            }
            Button("Custom…") { customModel() }
            if let m = modelId {
                Divider()
                Button("Copy Model ID") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(m, forType: .string) }
            }
        } label: {
            if compact { Text(name ?? "Model") } else { Label(name ?? "Model", systemImage: "cpu").font(.callout) }
        }
        .menuStyle(.borderlessButton).fixedSize()
        .disabled(!tab.isAtPrompt)
        .help(tab.isAtPrompt ? "Switch model (/model)" : "Model can be switched when the session is idle at its prompt")
    }

    private func customModel() {
        let alert = NSAlert(); alert.messageText = "Model id"; alert.informativeText = "Sent as /model <id>."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24)); field.stringValue = modelId ?? ""
        alert.accessoryView = field; alert.addButton(withTitle: "Switch"); alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn, !field.stringValue.isEmpty { tabs.switchModel(tab, to: field.stringValue) }
    }
}

/// Footer effort chip: types `/effort` (ADR-064) and shows the level the status line reports (ADR-195).
struct EffortMenu: View {
    @Environment(TabStore.self) private var tabs
    let tab: Tab
    var compact = false
    private let levels = ["low", "medium", "high", "xhigh", "max"]

    var body: some View {
        Menu {
            ForEach(levels, id: \.self) { l in Button(l == "xhigh" ? "Extra high" : l.capitalized) { tabs.switchEffort(tab, to: l) } }
        } label: {
            let level = tab.liveEffort.map { $0 == "xhigh" ? "Extra high" : $0.capitalized } ?? "Effort"
            if compact { Text(level) } else { Label(level, systemImage: "gauge.with.dots.needle.33percent").font(.callout) }
        }
        .menuStyle(.borderlessButton).fixedSize()
        .disabled(!tab.isAtPrompt)
        .help(tab.isAtPrompt ? "Switch effort (/effort)" : "Effort can be switched when the session is idle at its prompt")
    }
}

/// Resume affordance for a tab whose Claude process exited (ADR-037).
struct ExitedOverlay: View {
    @Environment(TabStore.self) private var tabs
    let tab: Tab

    var body: some View {
        VStack {
            Spacer()
            HStack(spacing: 12) {
                Image(systemName: "power").foregroundStyle(.secondary)
                Text(tab.sessionId == nil ? "Shell exited" : "Claude Code exited").font(.callout)
                if tab.sessionId != nil, tab.lastResume != nil {
                    Button("Resume") { tabs.resume(tab) }.keyboardShortcut(.defaultAction)
                }
                Button("Close") { tabs.close(tab, confirm: false) }
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .padding(16)
        }
    }
}


/// The window toolbar. On macOS 26 each split control gets its own glass capsule (ADR-123): adjacent
/// items otherwise share one, and the split controls are plain buttons now, so they would all run
/// together. `ToolbarSpacer(.fixed)` between them did not break the shared capsule (tried 2026-09-11),
/// so these items opt out of it and draw their own.
///
/// Which items exist is decided here, not inside them: a `ToolbarItem` whose content is empty still
/// takes its own width and its capsule's padding, which left a gap where the Run or device control
/// would be (found 2026-09-11).
private struct RootToolbar: ViewModifier {
    @Environment(TabStore.self) private var tabs
    @Environment(SessionStore.self) private var sessions
    let window: WindowState

    func body(content: Content) -> some View {
        // A screen or the composer is not a tab: the tab's controls step aside for them.
        let tab = tabs.selectedTab(in: window)
        let runTab = tab.flatMap { $0.replay == nil && !window.isShowingScreen && window.editingDraft == nil ? $0 : nil }
        let platforms = runTab.map { tabs.devicePlatforms(for: $0) } ?? []
        let openIn = tab.flatMap { $0.replay == nil ? ($0.pwd ?? $0.projectPath) : nil }
        let openInProject = tab.flatMap { $0.replay == nil ? $0.projectPath : nil }
        if #available(macOS 26.0, *) {
            content.toolbar { SpacedItems(window: window, runTab: runTab, platforms: platforms, openIn: openIn, openInProject: openInProject, sessions: sessions) }
        } else {
            content.toolbar { Items(window: window, runTab: runTab, platforms: platforms, openIn: openIn, openInProject: openInProject, sessions: sessions) }
        }
    }

    private struct Items: ToolbarContent {
        let window: WindowState
        let runTab: Tab?
        let platforms: [RunDevicePlatform]
        let openIn: String?
        let openInProject: String?
        let sessions: SessionStore

        var body: some ToolbarContent {
            ToolbarItem(placement: .navigation) { WorkspaceHeader(window: window) }
            ToolbarItemGroup(placement: .primaryAction) {
                StartButtons()
                TabControls(runTab: runTab, platforms: platforms, openIn: openIn, openInProject: openInProject, sessions: sessions)
                NotificationBell()
            }
        }
    }

    @available(macOS 26.0, *)
    private struct SpacedItems: ToolbarContent {
        let window: WindowState
        let runTab: Tab?
        let platforms: [RunDevicePlatform]
        let openIn: String?
        let openInProject: String?
        let sessions: SessionStore

        var body: some ToolbarContent {
            // Always present, whatever it holds: an item added after the first build never appears.
            ToolbarItem(placement: .navigation) { WorkspaceHeader(window: window) }
                .sharedBackgroundVisibility(.hidden)
            // With the title removed nothing else pushes the controls to the trailing edge.
            ToolbarSpacer(.flexible)
            ToolbarItemGroup(placement: .primaryAction) { StartButtons() }
            // One item for every control that comes and goes, rather than one item each: SwiftUI
            // settles a toolbar's *items* on the first build, so an item added later never appears and
            // an item whose content went away keeps its width as a gap (both seen 2026-09-11). Inside
            // one item they are ordinary views, which appear and collapse as they should.
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 8) { TabControls(runTab: runTab, platforms: platforms, openIn: openIn, openInProject: openInProject, sessions: sessions) }
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarItem(placement: .primaryAction) { NotificationBell() }
        }
    }

    /// Caffeine, Run, its devices and Open In: what the selected tab (or the lack of one) decides. Then
    /// the sound packs' speaker, which comes and goes with installed packs.
    private struct TabControls: View {
        let runTab: Tab?
        let platforms: [RunDevicePlatform]
        let openIn: String?
        let openInProject: String?
        let sessions: SessionStore

        var body: some View {
            CaffeineItem()
            if let runTab { RunToolbarControl(tab: runTab).ownGlass() }
            if let runTab, !platforms.isEmpty { DeviceControls(tab: runTab, platforms: platforms) }
            if let openIn { OpenInToolbarMenu(path: openIn, projectPath: openInProject, sessions: sessions).ownGlass() }
            SoundsItem()
        }
    }

    /// The speaker beside the bell (ADR-208), once there is a pack to quiet.
    private struct SoundsItem: View {
        @Environment(SoundPackStore.self) private var store
        var body: some View {
            if !store.installed.isEmpty { SoundsToolbarControl().ownGlass() }
        }
    }

    private struct StartButtons: View {
        @Environment(TabStore.self) private var tabs
        @Environment(KeyBindings.self) private var bindings
        var body: some View {
            Button { tabs.startNewSession() } label: { Label("New Session", systemImage: "square.and.pencil") }.help("New Claude Code session" + bindings.hint(.newSession))
            Button { tabs.newShell() } label: { Label("New Shell", systemImage: "terminal") }.help("New shell tab" + bindings.hint(.newShell))
        }
    }

    private struct CaffeineItem: View {
        @Environment(CaffeineController.self) private var caffeine
        @Environment(KeyBindings.self) private var bindings
        // The capsule washes accent while the Mac is actually being held awake — Always, or an agent
        // working — and not merely while caffeine is on (ADR-151). It is the one fact worth catching
        // from the corner of the eye, and the cup says the rest.
        var body: some View {
            let lit = caffeine.isHolding
            CaffeineToolbarMenu(caffeine: caffeine, hint: bindings.hint(.caffeine))
                // Always washed, at nothing when unlit, so the capsule fades rather than snapping.
                .ownGlass(wash: .accent.opacity(lit ? 0.16 : 0))
                .animation(.easeInOut(duration: 0.25), value: lit)
        }
    }

    /// One capsule per platform the selected configuration installs onto (ADR-124).
    private struct DeviceControls: View {
        let tab: Tab
        let platforms: [RunDevicePlatform]
        var body: some View {
            HStack(spacing: 8) {
                ForEach(platforms) { platform in
                    RunDeviceControl(platform: platform, projectPath: tab.projectPath).ownGlass()
                }
            }
        }
    }
}

private extension View {
    /// A capsule of toolbar glass around a control that has left the shared one, drawn only where
    /// there is a control — an empty item would otherwise leave an empty capsule. Earlier systems
    /// draw no toolbar capsules.
    ///
    /// `wash` lights the capsule for a control whose state is worth catching without looking straight
    /// at it. Only caffeine passes one today (ADR-151).
    @ViewBuilder func ownGlass(wash: Color? = nil) -> some View {
        if #available(macOS 26.0, *) {
            padding(.horizontal, 4).frame(height: 36)
                // Behind the control but above the glass (ADR-151). An overlay across the whole capsule
                // dulls the glyphs it covers, and `Glass.tint` changes the capsule's brightness rather
                // than its hue, so neither produces an accent wash.
                .background { if let wash { Capsule().fill(wash) } }
                .glassEffect(.regular.interactive(), in: Capsule())
        } else {
            self
        }
    }
}

/// The View menu's screens (ADR-084, ADR-093, ADR-095, ADR-199), apart from Tasks, which routes itself.
/// A modifier of its own so the root view's chain stays short enough to type-check.
private struct ScreenRouting: ViewModifier {
    let window: WindowState
    let isActive: Bool

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .clinicMCPServers)) { _ in if isActive { window.screen = .mcpServers } }
            .onReceive(NotificationCenter.default.publisher(for: .clinicMarketplace)) { _ in if isActive { window.screen = .marketplace } }
            .onReceive(NotificationCenter.default.publisher(for: .clinicAutomations)) { _ in if isActive { window.screen = .automations } }
            .onReceive(NotificationCenter.default.publisher(for: .clinicSounds)) { _ in if isActive { window.screen = .sounds } }
    }
}
