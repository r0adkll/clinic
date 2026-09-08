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
    @Environment(\.openSettings) private var openSettings
    @State private var showNewSession = false
    @State private var showSwitcher = false
    @State private var detailsFor: SessionSummary?
    @State private var showMCPServers = false
    @State private var newSessionProject: String?
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
        .sheet(isPresented: $showMCPServers) { MCPServersSheet() }
        .onReceive(NotificationCenter.default.publisher(for: .clinicMCPServers)) { _ in if isActive { showMCPServers = true } }
        .onReceive(NotificationCenter.default.publisher(for: .clinicSessionDetails)) { n in
            guard isActive else { return }
            if let raw = n.object as? String { detailsFor = sessions.sessions[SessionID(raw)] }
            else if let id = tabs.selectedTab(in: window)?.sessionId { detailsFor = sessions.sessions[id] }
        }
        .onReceive(NotificationCenter.default.publisher(for: .clinicQuickSwitch)) { _ in if isActive { showSwitcher = true } }
        .onReceive(NotificationCenter.default.publisher(for: .clinicOpenSettings)) { _ in if isActive { openSettings() } }
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
        .toolbar {
            ToolbarItemGroup {
                Button { tabs.startNewSession() } label: { Label("New Session", systemImage: "square.and.pencil") }.help("New Claude Code session" + bindings.hint(.newSession))
                Button { tabs.newShell() } label: { Label("New Shell", systemImage: "terminal") }.help("New shell tab" + bindings.hint(.newShell))
                Button { caffeine.isOn.toggle() } label: {
                    Label("Caffeine", systemImage: caffeine.isOn ? "cup.and.saucer.fill" : "cup.and.saucer")
                        .foregroundStyle(caffeine.isOn ? Color.accentColor : Color.primary)
                }
                .help(caffeine.isOn ? "Caffeine mode is on: the Mac will not sleep" + bindings.hint(.caffeine) : "Caffeine mode: keep the Mac awake" + bindings.hint(.caffeine))
                NotificationBell()
            }
        }
        .navigationTitle(window.editingDraft != nil ? "New session" : (tabs.selectedTab(in: window)?.title ?? "Clinic"))
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
            if showTabBar && !mine.isEmpty && window.editingDraft == nil { TabBarView(); Divider() }
            terminalArea(mine: mine, selected: selected)
            if window.editingDraft == nil, let tab = selected, !tab.isReplay { Divider(); TabFooter(tab: tab) }
        }
    }

    private func terminalArea(mine: [Tab], selected: Tab?) -> some View {
        let live = mine.filter { $0.replay == nil }
        let showTerminals = tabs.startupError == nil && window.editingDraft == nil && !mine.isEmpty && selected?.replay == nil
        return ZStack {
            // Every live tab keeps its content view mounted in this window's stack; only the selected one is visible (ADR-019, ADR-072).
            TerminalStack(live: live, selectedId: window.selectedTabId, visible: showTerminals,
                          keys: live.map { "\($0.id)|\($0.panelVisible)|\(String(describing: $0.rightPane))|\($0.panelSurface == nil)|\($0.gitPage == nil)|\($0.editor == nil)" })
            ForEach(mine.filter { $0.replay != nil }) { tab in
                ReplayView(model: tab.replay!)
                    .opacity(tab.id == window.selectedTabId ? 1 : 0)
                    .allowsHitTesting(tab.id == window.selectedTabId)
            }
            if let error = tabs.startupError {
                ContentUnavailableView("libghostty failed to start", systemImage: "exclamationmark.triangle", description: Text(error))
                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(nsColor: .windowBackgroundColor))
            } else if let draft = window.editingDraft {
                NewSessionScreen(draft: draft)
                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(nsColor: .windowBackgroundColor))
            } else if mine.isEmpty {
                ContentUnavailableView("No session open", systemImage: "rectangle.on.rectangle.slash",
                                       description: Text("Pick a session from the sidebar, or press ⌘N to start a new one."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(nsColor: .windowBackgroundColor))
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

