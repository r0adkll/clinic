import SwiftUI
import AppKit
import ClinicCore

/// What a window with no tabs shows (ADR-120): every launch lands here, and so does closing the last
/// tab. Start actions, anything waiting on you, the most recent sessions across every project and one
/// shortcut tip; with no project registered yet, a folder drop target instead.
struct HomeScreen: View {
    @Environment(SessionStore.self) private var sessions

    var body: some View {
        Group {
            // Chats is always pinned (ADR-077), so an empty roster means the first scan has not landed
            // yet; drawing the first-launch screen then would flash it at everyone on every launch.
            if sessions.projects.isEmpty {
                Color.clear
            } else if sessions.projects.allSatisfy({ SessionStore.isChats($0.path) }) {
                FirstLaunchHome()
            } else {
                ResumeHome()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// MARK: - Resume

private struct ResumeHome: View {
    @Environment(TabStore.self) private var tabs
    @Environment(SessionStore.self) private var sessions
    @Environment(BackgroundAgentsService.self) private var background

    private static let recentCount = 5

    var body: some View {
        let waiting = waitingItems
        let recent = recentSessions(excluding: Set(waiting.map(\.sessionId)))
        // Centred in the pane when it fits, scrolling from the top when it does not.
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    HomeHeader().frame(maxWidth: .infinity)
                    VStack(alignment: .leading, spacing: 8) {
                        HomeSectionLabel("Start")
                        StartActions()
                    }
                    if !waiting.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            HomeSectionLabel("Needs you")
                            ForEach(waiting) { WaitingRow(item: $0) }
                        }
                    }
                    if !recent.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            HomeSectionLabel("Recent") { FindSessionButton() }
                            VStack(spacing: 2) {
                                ForEach(recent) { RecentSessionRow(summary: $0) }
                            }
                        }
                    }
                    ShortcutTip()
                }
                .frame(maxWidth: 640)
                .padding(.horizontal, 24).padding(.vertical, 40)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    /// Sessions in any window whose hooks say they are waiting, then detached ones that need you (ADR-061).
    private var waitingItems: [WaitingItem] {
        var items: [WaitingItem] = []
        for tab in tabs.tabs {
            guard let id = tab.sessionId, let state = tab.state, state.isWaiting else { continue }
            items.append(WaitingItem(sessionId: id, title: tab.title, projectPath: tab.projectPath,
                                     reason: state == .waitingForPermission ? "Waiting for permission" : "Waiting for your input"))
        }
        for agent in background.background where agent.isRunning && agent.needsAttention {
            guard let id = agent.sessionId, tabs.tab(for: id) == nil, let summary = sessions.sessions[id] else { continue }
            items.append(WaitingItem(sessionId: id, title: sessions.displayName(for: summary),
                                     projectPath: ProjectGrouping.project(for: summary)?.path ?? summary.cwd ?? "",
                                     reason: agent.waitingFor == "permission" ? "Detached · waiting for permission" : "Detached · needs you"))
        }
        return items
    }

    /// Across every project, by last activity: the sidebar groups by project, so this is the one place
    /// "what was I doing?" is a single glance.
    private func recentSessions(excluding ids: Set<SessionID>) -> [SessionSummary] {
        sessions.sessions.values
            .filter { sessions.isVisible($0) && !sessions.isArchived($0.id) && !ids.contains($0.id) }
            .sorted { ($0.activityDate, $0.id.rawValue) > ($1.activityDate, $1.id.rawValue) }
            .prefix(Self.recentCount)
            .map { $0 }
    }
}

private struct WaitingItem: Identifiable {
    let sessionId: SessionID
    let title: String
    let projectPath: String
    let reason: String
    var id: SessionID { sessionId }
}

/// New Session, New Chat, New Shell, Add Project: four across, two by two when the pane is narrow.
private struct StartActions: View {
    @Environment(TabStore.self) private var tabs
    @Environment(SessionStore.self) private var sessions

    var body: some View {
        let newSession = HomeActionCard(symbol: "square.and.pencil", title: "New Session", action: .newSession) { tabs.startNewSession() }
        let newChat = HomeActionCard(symbol: "bubble.left.and.bubble.right", title: "New Chat", action: .newChat) { tabs.newChat() }
        let newShell = HomeActionCard(symbol: "terminal", title: "New Shell", action: .newShell) { tabs.newShell() }
        let addProject = HomeActionCard(symbol: "folder.badge.plus", title: "Add Project…", action: nil) {
            if let path = ProjectFolderPicker.choose() { sessions.addProject(path) }
        }
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { newSession; newChat; newShell; addProject }
            VStack(spacing: 12) {
                HStack(spacing: 12) { newSession; newChat }
                HStack(spacing: 12) { newShell; addProject }
            }
        }
    }
}

private struct WaitingRow: View {
    @Environment(TabStore.self) private var tabs
    let item: WaitingItem

    var body: some View {
        Button { tabs.reveal(sessionId: item.sessionId) } label: {
            HStack(spacing: 10) {
                Image(systemName: "hand.raised")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.orange)
                    .frame(width: 20, height: 20)
                    .background(Color.orange.opacity(0.2), in: Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title).font(.system(size: 13)).lineLimit(1)
                    Text(Project(path: item.projectPath).name + " · " + item.reason)
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                Text("Show")
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 10).frame(height: 24)
                    .background(Color.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
            }
            // Status colour, not the accent: orange is what "needs you" wears in the sidebar (ADR-096).
            .padding(.leading, 10).padding(.trailing, 8)
            .frame(height: 44)
            .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.orange.opacity(0.22)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// One click resumes the session, as a sidebar row does; one already open in a tab is brought forward.
private struct RecentSessionRow: View {
    @Environment(TabStore.self) private var tabs
    @Environment(SessionStore.self) private var sessions
    let summary: SessionSummary
    @State private var hovering = false

    var body: some View {
        let project = ProjectGrouping.project(for: summary)
        let isOpen = tabs.tab(for: summary.id) != nil
        Button { tabs.reveal(sessionId: summary.id) } label: {
            HStack(spacing: 10) {
                if let project { ProjectIcon(project: project, size: 20) }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(sessions.displayName(for: summary)).font(.system(size: 13)).lineLimit(1)
                    if let project { Text(project.name).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).layoutPriority(-1) }
                }
                Spacer(minLength: 8)
                PRMarkView(refs: summary.pullRequests)
                Group {
                    if hovering { Text(isOpen ? "Show" : "Resume") }
                    else { Text(summary.activityDate, format: .relative(presentation: .numeric, unitsStyle: .abbreviated)) }
                }
                .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.horizontal, 8)
            .frame(height: 34)
            .background(hovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(isOpen ? "Show this session's tab" : "Resume this session")
    }
}

private struct FindSessionButton: View {
    @Environment(KeyBindings.self) private var bindings

    var body: some View {
        Button { NotificationCenter.default.post(name: .clinicQuickSwitch, object: nil) } label: {
            HStack(spacing: 6) {
                Text("Find any session")
                if let chord = bindings.chord(for: .jumpToSession) { KeyCap(chord.display) }
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Jump to any session, including ones started outside Clinic")
    }
}

/// One tip per launch, read through `KeyBindings` so a rebound chord (ADR-073) shows as bound and an
/// unbound one's tip is skipped.
private struct ShortcutTip: View {
    @Environment(KeyBindings.self) private var bindings

    private static let tips: [(ShortcutAction, String)] = [
        (.jumpToSession, "finds any session, including ones started outside Clinic."),
        (.newSessionInFolder, "starts a session in a folder that isn't a project yet."),
        (.newChat, "starts a chat that needs no project."),
        (.togglePanel, "opens a shell in the panel beside a session."),
        (.toggleDiffPage, "shows what a session changed, turn by turn."),
        (.backgroundSession, "keeps a session running after you close its tab."),
        (.selectSessions, "selects several sessions to archive or stop at once."),
        (.newWindow, "opens another window with tabs of its own."),
    ]
    /// Fixed for the life of the process, so closing the last tab twice does not reshuffle it.
    private static let seed = Int.random(in: 0..<1000)

    var body: some View {
        let bound = Self.tips.compactMap { tip in bindings.chord(for: tip.0).map { ($0, tip.1) } }
        if !bound.isEmpty {
            let (chord, text) = bound[Self.seed % bound.count]
            HStack(spacing: 8) {
                Image(systemName: "lightbulb").font(.system(size: 12)).foregroundStyle(.tertiary)
                KeyCap(chord.display)
                Text(text).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 8)
                Button("All Shortcuts…") { PreferencesView.open(.shortcuts) }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Color.accentColor)
            }
            .padding(.horizontal, 8)
        }
    }
}

// MARK: - First launch

/// No project registered yet: the recent list would be empty, so the screen is a folder drop target.
/// The drop is accepted anywhere in the pane, not only inside the dashed box.
private struct FirstLaunchHome: View {
    @Environment(TabStore.self) private var tabs
    @Environment(SessionStore.self) private var sessions
    @State private var targeted = false

    var body: some View {
        VStack(spacing: 28) {
            HomeHeader()
            VStack(spacing: 14) {
                AccentTile(symbol: "folder.badge.plus", size: 48, glyph: 24)
                VStack(spacing: 6) {
                    Text("Add your first project").font(.system(size: 17, weight: .semibold))
                    Text("Drop a folder here, or choose one. Sessions group under the folder they run in.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                Button("Choose Folder…") { if let path = ProjectFolderPicker.choose() { sessions.addProject(path) } }
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 4)
            }
            .padding(.horizontal, 24).padding(.top, 34).padding(.bottom, 28)
            .frame(maxWidth: 560)
            .background(targeted ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.02),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(targeted ? Color.accentColor : Color.primary.opacity(0.16), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
            HStack(spacing: 12) {
                HomeActionCard(symbol: "bubble.left.and.bubble.right", title: "New Chat", action: .newChat) { tabs.newChat() }
                HomeActionCard(symbol: "terminal", title: "New Shell", action: .newShell) { tabs.newShell() }
                HomeActionCard(symbol: "arrow.right.to.line", title: "Import a Session", action: .jumpToSession) {
                    NotificationCenter.default.post(name: .clinicQuickSwitch, object: nil)
                }
            }
            .frame(maxWidth: 560)
        }
        .padding(.horizontal, 24).padding(.bottom, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .dropDestination(for: URL.self) { urls, _ in
            let folders = urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            for url in folders { sessions.addProject(url.path) }
            return !folders.isEmpty
        } isTargeted: { targeted = $0 }
    }
}

// MARK: - Pieces

/// The app's icon and name over the content, centred.
private struct HomeHeader: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().interpolation(.high)
                .frame(width: 72, height: 72)
                .accessibilityHidden(true)
            Text("Clinic").font(.system(size: 34, weight: .bold)).tracking(-0.5)
                .accessibilityAddTraits(.isHeader)
        }
    }
}

/// A start action: an accent tile, its chord top-right, the title underneath.
private struct HomeActionCard: View {
    @Environment(KeyBindings.self) private var bindings
    let symbol: String
    let title: String
    /// The menu command this card mirrors; its chord is read live, so a rebinding shows here too.
    let action: ShortcutAction?
    let perform: () -> Void
    @State private var hovering = false

    var body: some View {
        let chord = action.flatMap { bindings.chord(for: $0) }
        Button(action: perform) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    AccentTile(symbol: symbol, size: 30, glyph: 15)
                    Spacer(minLength: 4)
                    if let chord { KeyCap(chord.display) }
                }
                Spacer(minLength: 8)
                Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            }
            .padding(14)
            .frame(minWidth: 128, maxWidth: .infinity, minHeight: 88, maxHeight: 88, alignment: .leading)
            .background(Color.primary.opacity(hovering ? 0.08 : 0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(hovering ? 0.12 : 0.07)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(title.replacingOccurrences(of: "…", with: "") + (action.map { bindings.hint($0) } ?? ""))
    }
}

/// The nav rows' and Settings' tile (ADR-108, ADR-111) at any size: accent glyph on accent at 16 %.
struct AccentTile: View {
    let symbol: String
    var size: CGFloat = 22
    var glyph: CGFloat = 12

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: glyph, weight: .medium))
            .foregroundStyle(Color.accentColor)
            .frame(width: size, height: size)
            .background(Color.accentColor.opacity(0.16), in: RoundedRectangle(cornerRadius: size * 0.23, style: .continuous))
    }
}

/// A chord drawn as one key, the way a menu shows it.
struct KeyCap: View {
    let chord: String
    init(_ chord: String) { self.chord = chord }

    var body: some View {
        Text(chord)
            .font(.system(size: 11, weight: .medium))
            .tracking(1)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .frame(height: 18)
            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary.opacity(0.09)))
    }
}

private struct HomeSectionLabel<Trailing: View>: View {
    let title: String
    let trailing: Trailing

    init(_ title: String, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.trailing = trailing()
    }

    var body: some View {
        HStack {
            // The sidebar's "Projects" caption.
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 8)
        .frame(height: 20)
    }
}

extension HomeSectionLabel where Trailing == EmptyView {
    init(_ title: String) { self.init(title) { EmptyView() } }
}

/// The folder picker behind every "Add Project" (sidebar toolbar, home screen).
@MainActor
enum ProjectFolderPicker {
    static func choose() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.message = "Choose a project folder to show in the sidebar"
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}
