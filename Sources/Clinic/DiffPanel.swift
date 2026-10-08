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
    @State private var showingTurns = false
    /// Per panel and not remembered: turns that changed nothing are the exception worth asking for.
    @State private var showEmptyTurns = false

    var body: some View {
        VStack(spacing: 0) {
            header
            if model.isBound, model.hasRepo { contextStrip }
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
        // Keyed on the session too: `/clear`, a fork and a continue re-key the tab, and binding only on
        // the directory kept reading the old session's turns (ADR-170).
        .task(id: BindKey(directory: tab.pwd ?? tab.projectPath, sessionId: tab.sessionId)) {
            await model.bind(directory: tab.pwd ?? tab.projectPath, sessionId: tab.sessionId, snapshots: tabs.snapshots)
        }
        .onChange(of: tabs.snapshots.revision) { model.reload() }
    }

    private struct BindKey: Hashable { var directory: String; var sessionId: SessionID? }

    @ViewBuilder
    private var content: some View {
        if let reason = model.emptyReason {
            // An empty scope says where the changes are (ADR-188): the counts are already known, and
            // the alternative is opening each scope in turn to find out.
            ContentUnavailableView {
                Label("No changes", systemImage: "equal.circle")
            } description: {
                Text(reason)
            } actions: {
                ForEach(model.scopesWithChanges, id: \.scope) { other in
                    Button { model.scope = other.scope } label: {
                        Label("\(other.scope.title): \(Self.files(other.stat.files))", systemImage: other.scope.symbol)
                    }
                    .controlSize(.small)
                }
            }
        } else if let error = model.error, model.files.isEmpty {
            ContentUnavailableView("Could not read the diff", systemImage: "exclamationmark.triangle", description: Text(error))
        } else if model.isLoading, model.files.isEmpty {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            DiffBrowserView(browser: model.browser, showTree: $showTree, treeWidth: $treeWidth, openFile: openInFiles)
        }
    }

    private static func files(_ count: Int) -> String { count == 1 ? "1 file" : "\(count) files" }

    /// A path of the diff, opened in the Files panel beside it.
    private func openInFiles(_ path: String) {
        guard let root = model.repo?.root else { return }
        tabs.showPane(.files, in: tab)
        tab.panel.pane(.files)?.editor?.open(absolute: (root as NSString).appendingPathComponent(path))
    }

    // MARK: What is being compared (ADR-187)

    /// One quiet line under the header naming both sides of the diff, and under it whatever the
    /// reader should know before trusting it: a newer turn held back, a checkout that moved, another
    /// session writing to the same files, a refresh that failed. Each is a line, not a dialog — the
    /// diff stays on screen and readable under all of them.
    @ViewBuilder
    private var contextStrip: some View {
        let notices = self.notices
        if model.comparison != nil || !notices.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                if let comparison = model.comparison {
                    HStack(spacing: 6) {
                        Text(comparison).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 4)
                        if model.browser.viewedCount > 0 {
                            Text("\(model.browser.viewedCount) of \(model.browser.fileCount) viewed").fixedSize()
                        }
                    }
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                }
                ForEach(notices) { notice in DiffNoticeRow(notice: notice) }
            }
            .padding(.horizontal, PaneMetrics.padding)
            .padding(.top, 1).padding(.bottom, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar)
        }
    }

    private var notices: [DiffNotice] {
        var out: [DiffNotice] = []
        if let pending = model.pendingTurn {
            out.append(DiffNotice(id: "pending", symbol: "arrow.down.circle.fill", tint: .accent,
                                  text: "Turn #\(pending.index) has changes: \(pending.label)",
                                  action: "Show") { model.showPendingTurn() })
        }
        if let move = model.resolution?.move {
            let what = model.scope == .session ? "since this session attached" : "during this turn"
            let moved = move.changedBranch
                ? "The checkout moved from \(move.fromBranch ?? String(move.fromCommit.prefix(7))) to \(move.toBranch ?? String(move.toCommit.prefix(7))) \(what)."
                : "The checkout moved to other commits \(what) (\(move.fromCommit.prefix(7)) to \(move.toCommit.prefix(7)))."
            if model.showsCheckoutMove {
                out.append(DiffNotice(id: "move", symbol: "arrow.triangle.swap", tint: .secondary,
                                      text: moved + " Showing everything that differs, including what the move brought.",
                                      action: "Only its own changes") { model.showsCheckoutMove = false })
            } else {
                out.append(DiffNotice(id: "move", symbol: "arrow.triangle.swap", tint: .secondary,
                                      text: moved + " Showing only what was changed on top of that.",
                                      action: "Show everything") { model.showsCheckoutMove = true })
            }
        }
        if model.overlappingSessions > 0 {
            let who = model.overlappingSessions == 1 ? "Another session was" : "\(model.overlappingSessions) other sessions were"
            out.append(DiffNotice(id: "overlap", symbol: "person.2", tint: .secondary,
                                  text: "\(who) changing this checkout during this turn. Their changes are in here too."))
        }
        if let error = model.error, !model.files.isEmpty {
            out.append(DiffNotice(id: "error", symbol: "exclamationmark.triangle.fill", tint: .orange,
                                  text: "Could not refresh, so this may be out of date: \(error)"))
        }
        return out
    }

    // MARK: Header

    /// `PaneHeader`, so the scope band and the two headers of the browser under it are one chrome
    /// rather than three bars of three heights (ADR-102, sized by ADR-103).
    private var header: some View {
        PaneHeader {
            scopeMenu
            secondaryControl
            Spacer(minLength: 4)
            // Only while a selection the reader made is on its way. A refresh of what is on screen
            // shows nothing: the totals blinking into a spinner on every file event read as the
            // panel being unsure of itself (ADR-183).
            if model.isLoading {
                ProgressView().controlSize(.small)
            } else if !model.files.isEmpty {
                Text("+\(model.totals.additions)").foregroundStyle(.green)
                    .font(.system(size: PaneMetrics.label, weight: .medium).monospacedDigit())
                Text("−\(model.totals.deletions)").foregroundStyle(.red)
                    .font(.system(size: PaneMetrics.label, weight: .medium).monospacedDigit())
            }
        }
    }

    private var scopeMenu: some View {
        Menu {
            Picker("Scope", selection: $model.scope) {
                ForEach(DiffPanelModel.Scope.allCases) { scope in
                    // With what each holds (ADR-188), so an empty scope is known before it is opened.
                    Label(scope.title + scopeCount(scope), systemImage: scope.symbol).tag(scope)
                }
            }
            .pickerStyle(.inline).labelsHidden()
        } label: {
            Label(model.scope.title, systemImage: model.scope.symbol)
        }
        .menuStyle(.borderlessButton).fixedSize()
        .help("What the diff is showing")
    }

    private func scopeCount(_ scope: DiffPanelModel.Scope) -> String {
        guard let stat = model.scopeStats[scope] else { return "" }
        return stat.isEmpty ? "  ·  no changes" : "  ·  \(Self.files(stat.files))"
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

    /// A popover rather than a `Menu` (ADR-171): each turn needs a second line — its counts and when it
    /// ran — to be told apart from "yes" and "lets do it", and a session's worth of turns has to scroll.
    private var turnMenu: some View {
        Button { showingTurns.toggle() } label: {
            HStack(spacing: 3) {
                Text(model.selectedTurn.map(turnLabel) ?? (model.turns.isEmpty ? "No turns" : "Latest changes"))
                    .lineLimit(1).truncationMode(.tail)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: 190, alignment: .leading)
        .help("Which turn to show")
        .popover(isPresented: $showingTurns, arrowEdge: .bottom) { turnChoices }
    }

    private var turnChoices: some View {
        let offered = showEmptyTurns ? model.turns : SessionSnapshots.withChanges(model.turns)
        let hidden = model.turns.count - SessionSnapshots.withChanges(model.turns).count
        return ScrollView {
            PopoverMenu(width: 340) {
                PopoverMenuRow(title: "Latest changes", subtitle: followingSubtitle, checked: model.selectedTurnId == nil) {
                    // Also what takes the panel to a newer turn it was holding back from (ADR-187).
                    model.showPendingTurn()
                } icon: { Image(systemName: "arrow.down.to.line") }
                if !offered.isEmpty { PopoverMenuDivider() }
                ForEach(offered) { turn in
                    PopoverMenuRow(title: turn.label, styledSubtitle: { turnSubtitle(turn, highlighted: $0) },
                                   checked: model.selectedTurnId == turn.id) {
                        model.selectedTurnId = turn.id
                    } icon: { Image(systemName: turnSymbol(turn)) }
                    .disabled(turn.isEmpty)
                }
                if hidden > 0 {
                    PopoverMenuDivider()
                    Toggle(isOn: $showEmptyTurns) {
                        Text(hidden == 1 ? "Show 1 turn that changed nothing" : "Show \(hidden) turns that changed nothing")
                    }
                    .toggleStyle(.checkbox).controlSize(.small)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                }
            }
        }
        .frame(maxHeight: 460)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var followingSubtitle: String {
        guard model.selectedTurnId == nil, let turn = model.selectedTurn else { return "The newest turn that changed a file" }
        return "Showing #\(turn.index)"
    }

    private func turnLabel(_ turn: TurnSnapshot) -> String {
        turn.isInFlight ? "\(turn.label) — running" : turn.label
    }

    /// `#12 · +40 −3 · 4 files · 2h ago`: the counts are what tell turns apart when the prompts don't.
    /// The counts take the header's green and red, except on the highlighted row's accent fill.
    private func turnSubtitle(_ turn: TurnSnapshot, highlighted: Bool) -> Text {
        let separator = Text(" · ")
        var line = Text("#\(turn.index)")
        if turn.isInFlight { line = line + separator + Text("running") }
        else if turn.isEmpty { line = line + separator + Text("no changes") }
        else if let stat = model.turnStats[turn.id], stat.isEmpty {
            // Its trees differ and none of it is its own work (ADR-185).
            line = line + separator + Text("only moved the checkout")
        } else if let stat = model.turnStats[turn.id] {
            let additions = Text("+\(stat.additions)"), deletions = Text("−\(stat.deletions)")
            line = line + separator
                + (highlighted ? additions : additions.foregroundStyle(.green)) + Text(" ")
                + (highlighted ? deletions : deletions.foregroundStyle(.red))
                + separator + Text(stat.files == 1 ? "1 file" : "\(stat.files) files")
        }
        return line + separator + Text(Self.relative.localizedString(for: turn.endedAt ?? turn.startedAt, relativeTo: .now))
    }

    private func turnSymbol(_ turn: TurnSnapshot) -> String {
        switch turn.origin {
        case .user: turn.isInFlight ? "ellipsis.bubble" : "text.bubble"
        case .backgroundTask: "terminal"
        case .subagent: "person.2"
        }
    }

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .abbreviated; return f
    }()

    private var commitMenu: some View {
        Menu {
            Button { model.selectedCommit = nil } label: {
                Text(model.branchBase == nil ? "Latest commit" : "All commits on the branch")
            }
            if !model.commits.isEmpty { Divider() }
            ForEach(model.commits) { commit in
                Button { model.selectedCommit = commit.sha } label: { Text("\(commit.shortSha)  \(commit.subject)") }
            }
        } label: {
            Text((model.selectedCommitSummary ?? (model.branchBase == nil ? model.commits.first : nil))
                    .map { "\($0.shortSha) \($0.subject)" } ?? branchLabel)
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

/// One line under the diff panel's header (ADR-187): something true about the diff on screen that
/// its lines cannot say, and at most one thing to do about it.
struct DiffNotice: Identifiable {
    let id: String
    var symbol: String
    var tint: Color
    var text: String
    var action: String?
    var perform: (() -> Void)?

    init(id: String, symbol: String, tint: Color, text: String, action: String? = nil, perform: (() -> Void)? = nil) {
        self.id = id
        self.symbol = symbol
        self.tint = tint
        self.text = text
        self.action = action
        self.perform = perform
    }
}

private struct DiffNoticeRow: View {
    let notice: DiffNotice

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: notice.symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(notice.tint)
                .frame(width: 13)
            Text(notice.text)
                .font(.system(size: 11))
                .foregroundStyle(.primary.opacity(0.85))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .help(notice.text)
            Spacer(minLength: 4)
            if let action = notice.action, let perform = notice.perform {
                Button(action, action: perform)
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.accent)
                    .fixedSize()
            }
        }
    }
}
