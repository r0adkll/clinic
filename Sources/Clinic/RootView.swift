import SwiftUI
import ClinicCore
import GhosttyBridge

struct RootView: View {
    @Environment(TabStore.self) private var tabs
    @Environment(SessionStore.self) private var sessions
    @State private var showNewSession = false
    @State private var showSwitcher = false

    var body: some View {
        NavigationSplitView {
            SidebarView(showNewSession: $showNewSession)
                .navigationSplitViewColumnWidth(min: 220, ideal: 300, max: 420)
        } detail: {
            DetailView()
        }
        .frame(minWidth: 800, minHeight: 480)
        .sheet(isPresented: $showNewSession) { NewSessionSheet() }
        .sheet(isPresented: $showSwitcher) { QuickSwitcher() }
        .onReceive(NotificationCenter.default.publisher(for: .clinicQuickSwitch)) { _ in showSwitcher = true }
        .alert("Could not open a terminal", isPresented: Binding(get: { tabs.lastSurfaceError != nil }, set: { if !$0 { tabs.lastSurfaceError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(tabs.lastSurfaceError ?? "") }
        .onReceive(NotificationCenter.default.publisher(for: .clinicNewSession)) { _ in showNewSession = true }
        .toolbar {
            ToolbarItemGroup {
                Button { showNewSession = true } label: { Label("New Session", systemImage: "plus") }
                Button { tabs.newShell() } label: { Label("New Shell", systemImage: "terminal") }
            }
        }
        .navigationTitle(tabs.selectedTab?.title ?? "Clinic")
    }
}

struct DetailView: View {
    @Environment(TabStore.self) private var tabs

    var body: some View {
        ZStack {
            if let error = tabs.startupError {
                ContentUnavailableView("libghostty failed to start", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if tabs.tabs.isEmpty {
                ContentUnavailableView("No session open", systemImage: "rectangle.on.rectangle.slash",
                                       description: Text("Pick a session from the sidebar, or press ⌘N to start a new one."))
            } else {
                // Every open tab keeps its surface mounted; only the selected one is visible (ADR-019).
                ForEach(tabs.tabs) { tab in
                    SurfaceContainer(surface: tab.surface, isVisible: tab.id == tabs.selectedTabId)
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
