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
    @State private var newSessionProject: String?
    @State private var runSheet: RunSheetRequest?
    @AppStorage("ClinicShowTabBar") private var showTabBar = true

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
        .sheet(item: $runSheet) { RunSheet(request: $0) }
        .onReceive(NotificationCenter.default.publisher(for: .clinicRunSheet)) { n in
            guard isActive, let request = n.object as? RunSheetRequest else { return }
            runSheet = request
        }
        .modifier(TasksRouting(window: window, isActive: isActive))
        .onReceive(NotificationCenter.default.publisher(for: .clinicMCPServers)) { _ in if isActive { window.screen = .mcpServers } }
        .onReceive(NotificationCenter.default.publisher(for: .clinicMarketplace)) { _ in if isActive { window.screen = .marketplace } }
        .onReceive(NotificationCenter.default.publisher(for: .clinicAutomations)) { _ in if isActive { window.screen = .automations } }
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
        .navigationTitle(title(for: window))
    }

    /// A screen names the window while it is up; otherwise the selected tab does.
    private func title(for window: WindowState) -> String {
        if let screen = window.screen { return screen.title }
        if window.editingDraft != nil { return "New session" }
        return tabs.selectedTab(in: window)?.title ?? "Clinic"
    }
}

struct DetailView: View {
    @Environment(TabStore.self) private var tabs
    @Environment(WindowState.self) private var window
    @AppStorage("ClinicShowTabBar") private var showTabBar = true

    var body: some View {
        let mine = tabs.tabs(in: window)
        let selected = mine.first { $0.id == window.selectedTabId }
        VStack(spacing: 0) {
            if showTabBar && !mine.isEmpty && !window.isShowingScreen { TabBarView(); Divider() }
            terminalArea(mine: mine, selected: selected)
            if !window.isShowingScreen, let tab = selected, !tab.isReplay { Divider(); TabFooter(tab: tab) }
        }
    }

    private func terminalArea(mine: [Tab], selected: Tab?) -> some View {
        let live = mine.filter { $0.replay == nil }
        let showTerminals = tabs.startupError == nil && !window.isShowingScreen && !mine.isEmpty && selected?.replay == nil
        return ZStack {
            // Every live tab keeps its content view mounted in this window's stack; only the selected one is visible (ADR-019, ADR-072).
            TerminalStack(live: live, selectedId: window.selectedTabId, visible: showTerminals,
                          keys: live.map { "\($0.id)|\($0.panel.renderKey)|\(tabs.runs.renderKey(for: $0))" })
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
            } else if window.screen == .mcpServers {
                MCPServersScreen()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let draft = window.editingDraft {
                NewSessionScreen(draft: draft)
                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(nsColor: .windowBackgroundColor))
            } else if mine.isEmpty {
                HomeScreen()
            } else if let tab = selected, tab.childExited {
                ExitedOverlay(tab: tab)
            }
        }
    }
}

/// Model, branch and cwd for the selected tab (milestone 2, Collins footer).
struct TabFooter: View {
    @Environment(TabStore.self) private var tabs
    @Environment(SessionStore.self) private var sessions
    let tab: Tab

    var body: some View {
        HStack(spacing: 10) {
            if tab.sessionId != nil {
                ModelMenu(tab: tab)
                EffortMenu(tab: tab)
            }
            if let pwd = tab.pwd {
                Button {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(pwd, forType: .string)
                } label: {
                    Label(Self.abbreviate(pwd), systemImage: "folder").lineLimit(1).truncationMode(.head)
                }
                .buttonStyle(.plain)
                .help("Working directory (click to copy): \(pwd)")
            }
            Spacer(minLength: 8)
            // Quick actions (ADR-079): each one shows the panel with its tab in front; the tab bar's chevron hides it.
            HStack(spacing: 6) {
                PaneToggle(tab: tab, kind: .terminal, help: "Shell in the panel (⌘J)")
                PaneToggle(tab: tab, kind: .diff, help: "Diff panel (⌘⇧G)")
                PaneToggle(tab: tab, kind: .files, help: "Editor (⌘⇧E)")
                if let id = tab.sessionId, let n = sessions.state.attachments[id]?.count, n > 0 {
                    PaneToggle(tab: tab, kind: .attachments, help: "Attachments (⌘⇧I)")
                }
                ForEach(tabs.pullRequests(for: tab)) { ref in
                    PRChip(ref: ref, active: tab.panel.isFront(.pr(ref)), open: tab.panel.isOpen(.pr(ref))) { tabs.togglePRPage(tab, ref: ref) }
                }
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.bar)
    }

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

/// Footer model chip: a menu that types `/model` when the session is idle (ADR-064).
struct ModelMenu: View {
    @Environment(TabStore.self) private var tabs
    let tab: Tab
    private let aliases = ["default", "sonnet", "opus", "haiku"]

    var body: some View {
        Menu {
            ForEach(aliases, id: \.self) { a in
                Button(a.capitalized) { tabs.switchModel(tab, to: a) }
            }
            Button("Custom…") { customModel() }
            if let m = tab.model {
                Divider()
                Button("Copy Model ID") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(m, forType: .string) }
            }
        } label: {
            Label(tab.model.map(TabFooter.shortModel) ?? "Model", systemImage: "cpu").font(.callout)
        }
        .menuStyle(.borderlessButton).fixedSize()
        .disabled(tab.state != .idle)
        .help(tab.state == .idle ? "Switch model (/model)" : "Model can be switched when the session is idle at its prompt")
    }

    private func customModel() {
        let alert = NSAlert(); alert.messageText = "Model id"; alert.informativeText = "Sent as /model <id>."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24)); field.stringValue = tab.model ?? ""
        alert.accessoryView = field; alert.addButton(withTitle: "Switch"); alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn, !field.stringValue.isEmpty { tabs.switchModel(tab, to: field.stringValue) }
    }
}

/// Footer effort chip: types `/effort` (ADR-064).
struct EffortMenu: View {
    @Environment(TabStore.self) private var tabs
    let tab: Tab
    private let levels = ["low", "medium", "high", "xhigh", "max"]

    var body: some View {
        Menu {
            ForEach(levels, id: \.self) { l in Button(l == "xhigh" ? "Extra high" : l.capitalized) { tabs.switchEffort(tab, to: l) } }
        } label: {
            Label(tab.effort.map { $0 == "xhigh" ? "Extra high" : $0.capitalized } ?? "Effort", systemImage: "gauge.with.dots.needle.33percent").font(.callout)
        }
        .menuStyle(.borderlessButton).fixedSize()
        .disabled(tab.state != .idle)
        .help(tab.state == .idle ? "Switch effort (/effort)" : "Effort can be switched when the session is idle at its prompt")
    }
}

/// Footer quick action for one panel pane (ADR-079): shows the panel with this pane in front. Never hides.
struct PaneToggle: View {
    @Environment(TabStore.self) private var tabs
    let tab: Tab
    let kind: PanelPane.Kind
    let help: String

    var body: some View {
        FooterToggle(title: tabs.paneTitle(kind, in: tab), symbol: kind.symbol,
                     active: tab.panel.isFront(kind), open: tab.panel.isOpen(kind), help: help) {
            tabs.showPane(kind, in: tab)
        }
    }
}

/// Labeled footer toggle (icon + title) so each control reads at a glance. `active` = this pane is on
/// screen; `open` = its panel tab exists but something else is in front.
struct FooterToggle: View {
    let title: String
    let symbol: String
    let active: Bool
    var open = false
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .labelStyle(.titleAndIcon)
                .font(.callout)
                .lineLimit(1)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(active ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(open && !active ? Color.accentColor.opacity(0.35) : .clear))
                .foregroundStyle(active ? Color.accentColor : Color.primary)
        }
        .buttonStyle(.plain)
        .help(help)
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
    let window: WindowState

    func body(content: Content) -> some View {
        // A screen or the composer is not a tab: the tab's controls step aside for them.
        let tab = tabs.selectedTab(in: window)
        let runTab = tab.flatMap { $0.replay == nil && !window.isShowingScreen && window.editingDraft == nil ? $0 : nil }
        let platforms = runTab.map { tabs.devicePlatforms(for: $0) } ?? []
        let openIn = tab.flatMap { $0.replay == nil ? ($0.pwd ?? $0.projectPath) : nil }
        if #available(macOS 26.0, *) {
            content.toolbar { SpacedItems(runTab: runTab, platforms: platforms, openIn: openIn) }
        } else {
            content.toolbar { Items(runTab: runTab, platforms: platforms, openIn: openIn) }
        }
    }

    private struct Items: ToolbarContent {
        let runTab: Tab?
        let platforms: [RunDevicePlatform]
        let openIn: String?

        var body: some ToolbarContent {
            ToolbarItemGroup {
                StartButtons()
                TabControls(runTab: runTab, platforms: platforms, openIn: openIn)
                NotificationBell()
            }
        }
    }

    @available(macOS 26.0, *)
    private struct SpacedItems: ToolbarContent {
        let runTab: Tab?
        let platforms: [RunDevicePlatform]
        let openIn: String?

        var body: some ToolbarContent {
            ToolbarItemGroup { StartButtons() }
            // One item for every control that comes and goes, rather than one item each: SwiftUI
            // settles a toolbar's *items* on the first build, so an item added later never appears and
            // an item whose content went away keeps its width as a gap (both seen 2026-09-11). Inside
            // one item they are ordinary views, which appear and collapse as they should.
            ToolbarItem {
                HStack(spacing: 8) { TabControls(runTab: runTab, platforms: platforms, openIn: openIn) }
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarItem { NotificationBell() }
        }
    }

    /// Caffeine, Run, its devices and Open In: what the selected tab (or the lack of one) decides.
    private struct TabControls: View {
        let runTab: Tab?
        let platforms: [RunDevicePlatform]
        let openIn: String?

        var body: some View {
            CaffeineItem()
            if let runTab { RunToolbarControl(tab: runTab).ownGlass() }
            if let runTab, !platforms.isEmpty { DeviceControls(tab: runTab, platforms: platforms) }
            if let openIn { OpenInToolbarMenu(path: openIn).ownGlass() }
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
        var body: some View { CaffeineToolbarMenu(caffeine: caffeine, hint: bindings.hint(.caffeine)).ownGlass() }
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
    @ViewBuilder func ownGlass() -> some View {
        if #available(macOS 26.0, *) {
            padding(.horizontal, 4).frame(height: 36).glassEffect(.regular.interactive(), in: Capsule())
        } else {
            self
        }
    }
}
