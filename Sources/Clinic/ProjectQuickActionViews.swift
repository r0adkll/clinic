import SwiftUI
import ClinicCore

extension ProjectQuickAction {
    var title: String {
        switch self {
        case .newSession: "New Session"
        case .newWorktreeSession: "New Session in Worktree"
        case .continueLast: "Continue Last Session"
        case .openShell: "Open Shell Here"
        case .run: "Run"
        case .openIn: "Open In"
        case .gitPull: "Git Pull"
        case .group: "Move to Group"
        case .openOnGitHub: "Open on GitHub"
        case .copyPath: "Copy Path"
        case .showInFinder: "Show in Finder"
        }
    }

    var symbol: String {
        switch self {
        case .newSession: "plus"
        case .newWorktreeSession: "arrow.triangle.branch"
        case .continueLast: "clock.arrow.circlepath"
        case .openShell: "terminal"
        case .run: "play"
        case .openIn: "arrow.up.forward.app"
        case .gitPull: "arrow.down.circle"
        case .group: "rectangle.stack"
        case .openOnGitHub: "safari"
        case .copyPath: "doc.on.doc"
        case .showInFinder: "folder"
        }
    }

    /// What the Settings checklist says each one does.
    var detail: String {
        switch self {
        case .newSession: "Opens the composer for this project"
        case .newWorktreeSession: "Starts a session in a new worktree"
        case .continueLast: "Resumes the project's most recent session"
        case .openShell: "Opens a shell tab in the project's folder"
        case .run: "Lists the project's run configurations"
        case .openIn: "Opens the folder in the project's Open In app"
        case .gitPull: "Pulls the checkout and says what arrived"
        case .group: "Moves the project into a group, or out of one"
        case .openOnGitHub: "Opens the repository's page"
        case .copyPath: "Copies the folder's path"
        case .showInFinder: "Reveals the folder in Finder"
        }
    }
}

/// A project header's hover buttons (ADR-211): the chosen quick actions, then the ⋯ menu, which always
/// holds everything.
struct ProjectQuickActions: View {
    @Environment(TabStore.self) private var tabs
    @Environment(SessionStore.self) private var sessions
    @AppStorage(ProjectQuickAction.defaultsKey) private var stored: String?
    let project: Project

    var body: some View {
        let chats = SessionStore.isChats(project.path)
        HStack(spacing: 2) {
            ForEach(ProjectQuickAction.parse(stored).filter { !chats || $0.appliesToChats }, id: \.self) { action($0) }
            Menu { ProjectMenu(project: project) } label: { glyph("ellipsis") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Project actions")
                .accessibilityLabel("Project actions")
        }
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func action(_ action: ProjectQuickAction) -> some View {
        let path = project.path
        switch action {
        case .run:
            Menu { ProjectRunItems(projectPath: path) } label: { glyph(action.symbol) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Run a configuration in \(project.name)").accessibilityLabel(action.title)
        case .group:
            Menu { MoveToGroupItems(project: project) } label: { glyph(action.symbol) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help(sessions.group(of: path).map { "In \($0.name). Move to another group" } ?? "Move to a group")
                .accessibilityLabel(action.title)
        default:
            Button { perform(action) } label: { glyph(action.symbol) }
                .buttonStyle(.plain)
                .help(help(action))
                .accessibilityLabel(action.title)
        }
    }

    private func glyph(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
            .frame(width: 18, height: 18).contentShape(Rectangle())
    }

    private func help(_ action: ProjectQuickAction) -> String {
        switch action {
        case .newSession: SessionStore.isChats(project.path) ? "New chat" : "New session in \(project.name)"
        case .openIn: OpenInApps.shared.target(forProjectPick: sessions.state.openInByProject[project.path]).map { "Open in \($0.name)" } ?? "Open In"
        default: action.title
        }
    }

    private func perform(_ action: ProjectQuickAction) {
        let path = project.path
        switch action {
        case .newSession: if SessionStore.isChats(path) { tabs.newChat() } else { tabs.startNewSession(projectPath: path) }
        case .newWorktreeSession: tabs.newSession(projectPath: path, model: sessions.state.lastModelByProject[path], worktree: true)
        case .continueLast: tabs.continueLast(in: path)
        case .openShell: tabs.newShell(in: path)
        case .openIn:
            let apps = OpenInApps.shared
            if let target = apps.target(forProjectPick: sessions.state.openInByProject[path]) { apps.open(path, in: target) }
        case .gitPull: NotificationCenter.default.post(name: .clinicGitPull, object: path)
        case .openOnGitHub:
            Task { if let url = await GitInfo.remoteWebURL(at: path) { NSWorkspace.shared.open(url) } else { NSSound.beep() } }
        case .copyPath: NSPasteboard.general.clearContents(); NSPasteboard.general.setString(path, forType: .string)
        case .showInFinder: NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        case .run, .group: break   // menus, above
        }
    }
}

/// Settings ▸ General ▸ Sidebar (ADR-211): which quick actions a project header shows on hover.
struct ProjectQuickActionSettings: View {
    @AppStorage(ProjectQuickAction.defaultsKey) private var stored: String?

    var body: some View {
        let chosen = ProjectQuickAction.parse(stored)
        Section {
            ForEach(ProjectQuickAction.allCases, id: \.self) { action in
                let on = chosen.contains(action)
                Toggle(isOn: Binding(get: { on }, set: { stored = ProjectQuickAction.serialize($0 ? chosen + [action] : chosen.filter { $0 != action }) })) {
                    Label {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(action.title)
                            Text(action.detail).font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: { Image(systemName: action.symbol) }
                }
                .disabled(!on && chosen.count >= ProjectQuickAction.maxChosen)
            }
        } header: {
            HStack {
                Text("Project quick actions")
                Spacer()
                Button("Restore Defaults") { stored = nil }.disabled(stored == nil).controlSize(.small)
            }
        } footer: {
            Text("Up to \(ProjectQuickAction.maxChosen) buttons appear beside a project's name while the pointer is on it, "
                 + "in this order and before the \u{22EF} menu, which keeps every action. Chats shows only the ones "
                 + "that need no repository. \(chosen.count) of \(ProjectQuickAction.maxChosen) chosen.")
        }
    }
}
