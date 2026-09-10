import SwiftUI
import ClinicCore

/// The right-column diff panel for a session tab (ADR-080): one reader, four scopes, read-only.
///
/// The scope header is this panel's own; everything under it is `DiffBrowserView`, the file tree and
/// one-file viewer it shares with the pull request panel (ADR-101).
struct DiffPanel: View {
    let tab: Tab
    @Bindable var model: DiffPanelModel
    @Environment(TabStore.self) private var tabs

    @AppStorage("ClinicDiffTreeWidth") private var treeWidth: Double = 200
    /// Its own key, not the pull request panel's: same reasoning as ADR-091's split from the editor.
    @AppStorage("ClinicDiffShowTree") private var showTree = true

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if !model.isBound {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !model.hasRepo {
                ContentUnavailableView("Not a git repository", systemImage: "folder.badge.questionmark",
                                       description: Text(tab.pwd ?? tab.projectPath))
            } else {
                content
            }
        }
        .task(id: tab.pwd) {
            await model.bind(directory: tab.pwd ?? tab.projectPath, sessionId: tab.sessionId, snapshots: tabs.snapshots)
        }
    }

    @ViewBuilder
    private var content: some View {
        if let reason = model.emptyReason {
            ContentUnavailableView("No changes", systemImage: "equal.circle", description: Text(reason))
        } else if let error = model.error, model.files.isEmpty {
            ContentUnavailableView("Could not read the diff", systemImage: "exclamationmark.triangle", description: Text(error))
        } else {
            DiffBrowserView(browser: model.browser, showTree: $showTree, treeWidth: $treeWidth)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 6) {
            scopeMenu
            secondaryControl
            Spacer(minLength: 4)
            if model.isLoading {
                ProgressView().controlSize(.small)
            } else if !model.files.isEmpty {
                Text("+\(model.totals.additions)").foregroundStyle(.green).font(.caption.monospacedDigit())
                Text("−\(model.totals.deletions)").foregroundStyle(.red).font(.caption.monospacedDigit())
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(.bar)
    }

    private var scopeMenu: some View {
        Menu {
            Picker("Scope", selection: $model.scope) {
                ForEach(DiffPanelModel.Scope.allCases) { scope in
                    Label(scope.title, systemImage: scope.symbol).tag(scope)
                }
            }
            .pickerStyle(.inline).labelsHidden()
        } label: {
            Label(model.scope.title, systemImage: model.scope.symbol)
        }
        .menuStyle(.borderlessButton).fixedSize()
        .help("What the diff is showing")
    }

    /// One control per scope: which turn, which side of the index, which commit.
    @ViewBuilder
    private var secondaryControl: some View {
        switch model.scope {
        case .turn: turnMenu
        case .session: EmptyView()
        case .workingTree:
            Picker("", selection: $model.workingSide) {
                ForEach(DiffPanelModel.WorkingSide.allCases) { side in Text(side.title).tag(side) }
            }
            .labelsHidden().fixedSize().controlSize(.small)
        case .branch: commitMenu
        }
    }

    private var turnMenu: some View {
        Menu {
            Button { model.selectedTurnId = nil } label: {
                Label("Latest turn", systemImage: model.selectedTurnId == nil ? "checkmark" : "")
            }
            if !model.turns.isEmpty { Divider() }
            ForEach(model.turns) { turn in
                Button { model.selectedTurnId = turn.id } label: {
                    Text(turnMenuLabel(turn))
                }
            }
        } label: {
            Text(model.selectedTurn.map(turnLabel) ?? "No turns")
                .lineLimit(1).truncationMode(.tail)
        }
        .menuStyle(.borderlessButton).frame(maxWidth: 190)
        .onTapGesture { model.loadTurnStats() }
        .help("Which turn to show")
    }

    private func turnLabel(_ turn: TurnSnapshot) -> String {
        turn.isInFlight ? "\(turn.label) — running" : turn.label
    }

    private func turnMenuLabel(_ turn: TurnSnapshot) -> String {
        var parts = ["\(turn.index). \(turn.label)"]
        if let stat = model.turnStats[turn.id], !stat.isEmpty { parts.append("+\(stat.additions) −\(stat.deletions)") }
        else if turn.isInFlight { parts.append("running") }
        return parts.joined(separator: "   ")
    }

    private var commitMenu: some View {
        Menu {
            Button { model.selectedCommit = nil } label: { Text("All commits on the branch") }
            if !model.commits.isEmpty { Divider() }
            ForEach(model.commits) { commit in
                Button { model.selectedCommit = commit.sha } label: { Text("\(commit.shortSha)  \(commit.subject)") }
            }
        } label: {
            Text(model.selectedCommitSummary.map { "\($0.shortSha) \($0.subject)" } ?? branchLabel)
                .lineLimit(1).truncationMode(.tail)
        }
        .menuStyle(.borderlessButton).frame(maxWidth: 190)
        .help("Which commit to show")
    }

    /// The branch and its ahead/behind live here rather than in their own header row: at 380 pt the
    /// panel cannot spare a third row, and the pane chip and footer both already name the branch.
    private var branchLabel: String {
        guard let s = model.status else { return "All commits" }
        let name = s.branch ?? (s.isDetached ? "detached" : "—")
        return s.ahead + s.behind > 0 ? "\(name) ↑\(s.ahead) ↓\(s.behind)" : name
    }
}
