import AppKit
import SwiftUI
import ClinicCore

// MARK: - Tab pieces shared by the strips (ADR-212)

/// A pane's glyph in a strip: a PR's service glyph with its state, a run's status, else its symbol.
struct PaneGlyph: View {
    @Environment(TabStore.self) private var tabs
    let tab: Tab
    let pane: PanelPane
    let compact: Bool

    var body: some View {
        if case .pr(let ref) = pane.kind {
            PRTabGlyph(ref: ref, size: pane.kind.glyphSize(compact: compact))
        } else if case .run(let key) = pane.kind {
            RunStatusGlyph(run: tabs.runs.run(forKey: key), idleSymbol: "play.fill", size: pane.kind.glyphSize(compact: compact) + 1)
        } else {
            Image(systemName: pane.kind.symbol).font(.system(size: pane.kind.glyphSize(compact: compact)))
        }
    }
}

// MARK: - The session header (ADR-212)

/// The toolbar's leading item: what the window is showing. For a session, its project's icon, its title
/// and state, and a line of project · branch · model ▾ · effort ▾ · context, which the footer used to
/// carry, with a ⋯ menu for the verbs the session tab's ✕ and menu used to hold.
struct WorkspaceHeader: View {
    @Environment(TabStore.self) private var tabs
    /// Passed in: toolbar content sits outside the `.environment(window)` the window's views get.
    let window: WindowState

    var body: some View {
        if let screen = window.screen {
            Text(screen.title).font(.headline)
        } else if window.editingDraft != nil {
            Text("New session").font(.headline)
        } else if let tab = tabs.selectedTab(in: window) {
            SessionHeader(tab: tab)
        }
    }
}

struct SessionHeader: View {
    @Environment(TabStore.self) private var tabs
    @Environment(SessionStore.self) private var sessions
    let tab: Tab

    var body: some View {
        HStack(spacing: 10) {
            ProjectIcon(project: Project(path: tab.projectPath), size: 26)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(tab.title).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.tail)
                    StatePill(tab: tab)
                }
                meta
            }
            // A toolbar item is as wide as it asks to be, and the controls after it overflow into a »
            // menu rather than squeeze it: the cap is what lets a long title truncate instead.
            .frame(maxWidth: 290, alignment: .leading)
            menu
        }
        .padding(.horizontal, 4)
    }

    private var meta: some View {
        HStack(spacing: 5) {
            Button(action: copyDirectory) {
                // The branch when there is one: the icon beside the title already names the project.
                HStack(spacing: 3) {
                    if let branch = tab.gitBranch {
                        Image(systemName: "arrow.triangle.branch").font(.system(size: 9))
                        Text(branch).truncationMode(.middle)
                    } else {
                        Text(Project(path: tab.projectPath).name)
                    }
                }
                .lineLimit(1)
            }
            .buttonStyle(.plain)
            .help("Working directory (click to copy): \(tab.pwd ?? tab.projectPath)")
            if tab.sessionId != nil {
                Text("·")
                ModelMenu(tab: tab, compact: true)
                Text("·")
                EffortMenu(tab: tab, compact: true)
                if let percent = tab.statusLine?.contextUsedPercentage {
                    Text("·")
                    ContextGauge(percent: percent, windowSize: tab.statusLine?.contextWindowSize).fixedSize()
                }
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }

    private var menu: some View {
        Menu {
            Button("Close Session…") { tabs.close(tab) }
            if let id = tab.sessionId, let summary = sessions.sessions[id] {
                Button("Archive") { SessionActions.archive(summary, sessions: sessions, tabs: tabs) }
                Divider()
                Button("Details…") { NotificationCenter.default.post(name: .clinicSessionDetails, object: id.rawValue) }
            }
            Divider()
            MoveToWindowMenu(tab: tab)
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Close, archive, move or show details of this session")
    }

    private func copyDirectory() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(tab.pwd ?? tab.projectPath, forType: .string)
    }
}

/// The session's state in words, coloured only for what wants the reader (ADR-096's palette).
struct StatePill: View {
    let tab: Tab

    var body: some View {
        if let label {
            let tint = label.1
            Text(label.0)
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(tint.opacity(0.18), in: Capsule())
                .foregroundStyle(tint)
        }
    }

    private var label: (String, Color)? {
        if tab.isReplay { return ("Replay", .secondary) }
        switch tab.state {
        case .launching: return ("Starting", .secondary)
        case .working: return ("Working", .secondary)
        case .waitingForPermission, .waitingForInput: return ("Needs you", .orange)
        case .idle: return tab.unread ? ("Finished", .blue) : ("Idle", .secondary)
        case .exited: return ("Exited", .secondary)
        case nil: return nil
        }
    }
}
