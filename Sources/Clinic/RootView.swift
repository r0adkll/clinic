import SwiftUI
import ClinicCore
import GhosttyBridge

struct RootView: View {
    @Environment(TabStore.self) private var tabs
    @Environment(SessionStore.self) private var sessions
    @State private var showNewSession = false
    @State private var showSwitcher = false
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
        .sheet(isPresented: $showNewSession) { NewSessionSheet(initialProject: newSessionProject) }
        .sheet(isPresented: $showSwitcher) { QuickSwitcher() }
        .onReceive(NotificationCenter.default.publisher(for: .clinicQuickSwitch)) { _ in showSwitcher = true }
        .alert("Could not open a terminal", isPresented: Binding(get: { tabs.lastSurfaceError != nil }, set: { if !$0 { tabs.lastSurfaceError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(tabs.lastSurfaceError ?? "") }
        .onReceive(NotificationCenter.default.publisher(for: .clinicNewSession)) { n in newSessionProject = n.object as? String; showNewSession = true }
        .toolbar {
            ToolbarItemGroup {
                Button { showNewSession = true } label: { Label("New Session", systemImage: "plus") }
                Button { tabs.newShell() } label: { Label("New Shell", systemImage: "terminal") }
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
            if let tab = tabs.selectedTab { Divider(); TabFooter(tab: tab) }
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
                    TabSurfaces(tab: tab, isSelected: tab.id == tabs.selectedTabId)
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
        if tab.gitPageVisible, let git = tab.gitPage {
            HSplitView {
                terminals.frame(minWidth: 360)
                GitPage(tab: tab, model: git).frame(minWidth: 380, idealWidth: 520)
            }
        } else {
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
    let tab: Tab

    var body: some View {
        HStack(spacing: 14) {
            if let model = tab.model {
                Label(Self.shortModel(model), systemImage: "cpu").help(model)
            }
            if let branch = tab.gitBranch {
                Button { tabs.toggleGitPage(tab) } label: { Label(branch, systemImage: "arrow.triangle.branch").lineLimit(1) }
                    .buttonStyle(.plain).help("Toggle git page (⌘⇧G)")
            }
            if let pwd = tab.pwd {
                Button {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(pwd, forType: .string)
                } label: {
                    Label(Self.abbreviate(pwd), systemImage: "folder").lineLimit(1).truncationMode(.head)
                }
                .buttonStyle(.plain)
                .help("Click to copy: \(pwd)")
            }
            Spacer()
            if let pid = tab.surface.foregroundPID { Text("pid " + String(pid)).foregroundStyle(.tertiary).monospacedDigit() }
            Button { tabs.togglePanel(tab) } label: { Image(systemName: "rectangle.bottomthird.inset.filled") }.buttonStyle(.plain).help("Terminal panel (⌘J)")
                .foregroundStyle(tab.panelVisible ? Color.accentColor : .secondary)
            Button { tabs.toggleGitPage(tab) } label: { Image(systemName: "arrow.triangle.branch") }.buttonStyle(.plain).help("Git page (⌘⇧G)")
                .foregroundStyle(tab.gitPageVisible ? Color.accentColor : .secondary)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
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
