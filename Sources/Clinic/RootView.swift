import SwiftUI
import ClinicCore
import GhosttyBridge

struct RootView: View {
    @Environment(TabStore.self) private var tabs
    @Environment(SessionStore.self) private var sessions
    @Environment(NotificationStore.self) private var history
    @State private var showNewSession = false
    @State private var showSwitcher = false
    @State private var detailsFor: SessionSummary?
    @State private var showMCPServers = false
    @State private var newSessionProject: String?
    @AppStorage("ClinicShowTabBar") private var showTabBar = true

    var body: some View {
        NavigationSplitView {
            SidebarView(showNewSession: $showNewSession)
                .navigationSplitViewColumnWidth(min: 220, ideal: 300, max: 420)
        } detail: {
            DetailView()
        }
        .frame(minWidth: 800, minHeight: 480)
        .overlay(alignment: .topTrailing) { NotificationCard().animation(.easeOut(duration: 0.25), value: history.card?.id) }
        .sheet(isPresented: $showNewSession) { NewSessionSheet(initialProject: newSessionProject) }
        .sheet(isPresented: $showSwitcher) { QuickSwitcher() }
        .sheet(item: $detailsFor) { SessionDetailsSheet(summary: $0) }
        .sheet(isPresented: $showMCPServers) { MCPServersSheet() }
        .onReceive(NotificationCenter.default.publisher(for: .clinicMCPServers)) { _ in showMCPServers = true }
        .onReceive(NotificationCenter.default.publisher(for: .clinicSessionDetails)) { n in
            if let raw = n.object as? String { detailsFor = sessions.sessions[SessionID(raw)] }
            else if let id = tabs.selectedTab?.sessionId { detailsFor = sessions.sessions[id] }
        }
        .onReceive(NotificationCenter.default.publisher(for: .clinicQuickSwitch)) { _ in showSwitcher = true }
        .alert("Could not open a terminal", isPresented: Binding(get: { tabs.lastSurfaceError != nil }, set: { if !$0 { tabs.lastSurfaceError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(tabs.lastSurfaceError ?? "") }
        .onReceive(NotificationCenter.default.publisher(for: .clinicNewSession)) { n in newSessionProject = n.object as? String; showNewSession = true }
        .toolbar {
            ToolbarItemGroup {
                Button { newSessionProject = tabs.selectedTab?.projectPath; showNewSession = true } label: { Label("New Session", systemImage: "square.and.pencil") }.help("New Claude Code session (⌘N)")
                Button { tabs.newShell() } label: { Label("New Shell", systemImage: "terminal") }.help("New shell tab (⌘T)")
                NotificationBell()
            }
        }
        .navigationTitle(tabs.selectedTab?.title ?? "Clinic")
    }
}

struct DetailView: View {
    @Environment(TabStore.self) private var tabs

    @AppStorage("ClinicShowTabBar") private var showTabBar = true

    var body: some View {
        VStack(spacing: 0) {
            if showTabBar && !tabs.tabs.isEmpty { TabBarView(); Divider() }
            terminalArea
            if let tab = tabs.selectedTab, !tab.isReplay { Divider(); TabFooter(tab: tab) }
        }
    }

    private var terminalArea: some View {
        ZStack {
            if let error = tabs.startupError {
                ContentUnavailableView("libghostty failed to start", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if tabs.tabs.isEmpty {
                ContentUnavailableView("No session open", systemImage: "rectangle.on.rectangle.slash",
                                       description: Text("Pick a session from the sidebar, or press ⌘N to start a new one."))
            } else {
                // Every open tab keeps its surface mounted; only the selected one is visible (ADR-019).
                ForEach(tabs.tabs) { tab in
                    Group {
                        if let replay = tab.replay { ReplayView(model: replay) } else { TabSurfaces(tab: tab, isSelected: tab.id == tabs.selectedTabId) }
                    }
                    .opacity(tab.id == tabs.selectedTabId ? 1 : 0)
                    .allowsHitTesting(tab.id == tabs.selectedTabId)
                }
                if let tab = tabs.selectedTab, tab.childExited {
                    ExitedOverlay(tab: tab)
                }
            }
        }
    }
}

/// Main surface plus the optional shell panel below it (ADR-046).
struct TabSurfaces: View {
    let tab: Tab
    let isSelected: Bool

    var body: some View {
        switch tab.rightPane {
        case .git:
            RightSplit { terminals } right: { if let git = tab.gitPage { GitPage(tab: tab, model: git) } }
        case .pr(let ref):
            RightSplit { terminals } right: { PRPage(tab: tab, ref: ref) }
        case .attachments:
            RightSplit { terminals } right: { AttachmentsPanel(tab: tab) }
        case .editor:
            RightSplit(rightMin: 520) { terminals } right: { if let e = tab.editor { EditorPanel(tab: tab, model: e) } }
        case .none:
            terminals
        }
    }

    @ViewBuilder
    private var terminals: some View {
        if tab.panelVisible, let panel = tab.panelSurface {
            VSplitView {
                SurfaceContainer(surface: tab.surface, isVisible: false)
                    .frame(minHeight: 120)
                SurfaceContainer(surface: panel, isVisible: isSelected)
                    .frame(minHeight: 80, idealHeight: 220)
            }
        } else {
            SurfaceContainer(surface: tab.surface, isVisible: isSelected)
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
            HStack(spacing: 6) {
                FooterToggle(title: "Panel", symbol: "rectangle.bottomthird.inset.filled", active: tab.panelVisible, help: "Shell panel below the session (⌘J)") { tabs.togglePanel(tab) }
                FooterToggle(title: tab.gitBranch ?? "Git", symbol: "arrow.triangle.branch", active: tab.gitPageVisible, help: "Git page (⌘⇧G)") { tabs.toggleGitPage(tab) }
                FooterToggle(title: "Files", symbol: "doc.text.magnifyingglass", active: tab.rightPane == .editor, help: "Editor (⌘⇧E)") { tabs.toggleEditor(tab) }
                if let id = tab.sessionId, let n = sessions.state.attachments[id]?.count, n > 0 {
                    FooterToggle(title: "Images (\(n))", symbol: "photo.on.rectangle", active: tab.rightPane == .attachments, help: "Attachments (⌘⇧I)") { tabs.toggleAttachments(tab) }
                }
                ForEach(tabs.pullRequests(for: tab)) { ref in
                    PRChip(ref: ref, active: tab.rightPane == .pr(ref)) { tabs.togglePRPage(tab, ref: ref) }
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

/// Labeled footer toggle (icon + title) so each control reads at a glance.
struct FooterToggle: View {
    let title: String
    let symbol: String
    let active: Bool
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

/// Hosts a long-lived GhosttySurfaceView owned by its Tab, never by this representable (ADR-019).
struct SurfaceContainer: NSViewRepresentable {
    let surface: GhosttySurfaceView
    let isVisible: Bool

    func makeNSView(context: Context) -> NSView {
        let host = NSView()
        host.autoresizesSubviews = true
        install(in: host)
        return host
    }

    func updateNSView(_ host: NSView, context: Context) {
        if surface.superview !== host { install(in: host) }
        if isVisible { DispatchQueue.main.async { surface.window?.makeFirstResponder(surface) } }
    }

    private func install(in host: NSView) {
        surface.removeFromSuperview()
        surface.frame = host.bounds
        surface.autoresizingMask = [.width, .height]
        host.addSubview(surface)
    }
}
