import SwiftUI
import ClinicCore

/// The right-column diff panel for a session tab (ADR-080): one reader, four scopes, read-only.
struct DiffPanel: View {
    let tab: Tab
    @Bindable var model: DiffPanelModel
    @Environment(TabStore.self) private var tabs

    @State private var visibleFile: String?
    @State private var scrollTarget: String?

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
                if !model.page.files.isEmpty {
                    DiffFileRail(files: model.fileSummaries, current: visibleFile) { path in
                        if model.reveal(path: path) { scrollTarget = path }
                    }
                    Divider()
                }
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
            VStack(spacing: 0) {
                DiffTextBody(source: model.text,
                             onVisibleFileChanged: { visibleFile = $0 },
                             onToggleCollapse: { model.toggleCollapsed($0) },
                             scrollTarget: $scrollTarget)
                if model.page.hasMore { showMore }
            }
        }
    }

    /// A footer rather than a row at the end of the body (ADR-100): a text view holds text, not
    /// buttons, and a pinned footer is reachable without scrolling to the end of the page.
    private var showMore: some View {
        Button { model.showMoreFiles() } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.down.circle")
                Text("Show \(model.page.remainingFiles) more file\(model.page.remainingFiles == 1 ? "" : "s")")
                Text("of \(model.page.totalFiles)").foregroundStyle(.secondary)
            }
            .font(.callout)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .center)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
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

/// The file index, one row tall: chips that scroll sideways and follow the reader, plus a popover
/// listing full paths for jumping (ADR-080).
struct DiffFileRail: View {
    let files: [DiffFileSummary]
    let current: String?
    let jump: (String) -> Void

    @State private var showingList = false

    var body: some View {
        HStack(spacing: 4) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(files) { file in
                            Button { jump(file.path) } label: { chip(file) }
                                .buttonStyle(.plain)
                                .id(file.path)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onChange(of: current) {
                    guard let current else { return }
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(current, anchor: .center) }
                }
            }
            Button { showingList.toggle() } label: { Image(systemName: "list.bullet").font(.caption) }
                .buttonStyle(.borderless)
                .help("\(files.count) changed file\(files.count == 1 ? "" : "s")")
                .popover(isPresented: $showingList, arrowEdge: .bottom) { fileList }
        }
        .padding(.horizontal, 8)
        .background(.bar)
    }

    private func chip(_ file: DiffFileSummary) -> some View {
        let isCurrent = file.path == current
        return HStack(spacing: 4) {
            Text(file.name).font(.caption).lineLimit(1)
            Text("\(file.changedLines)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 7).padding(.vertical, 2)
        .background(isCurrent ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.05), in: Capsule())
        .foregroundStyle(isCurrent ? Color.accentColor : Color.primary)
    }

    private var fileList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(files) { file in
                    Button {
                        jump(file.path)
                        showingList = false
                    } label: {
                        HStack(spacing: 8) {
                            Text(file.path).font(.system(.caption, design: .monospaced)).lineLimit(1).truncationMode(.head)
                            Spacer(minLength: 8)
                            Text("+\(file.additions)").foregroundStyle(.green).font(.caption2.monospacedDigit())
                            Text("−\(file.deletions)").foregroundStyle(.red).font(.caption2.monospacedDigit())
                        }
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .background(file.path == current ? Color.accentColor.opacity(0.15) : .clear)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 4)
        }
        .frame(width: 420, height: min(CGFloat(files.count) * 24 + 16, 400))
    }
}
