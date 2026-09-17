import SwiftUI
import ClinicCore

/// How the sidebar draws a session (ADR-156). Compact is the one-line row of ADR-040/ADR-077; a card
/// adds where the session is, what it is doing, and what it has running.
enum SessionRowStyle: String, CaseIterable, Identifiable {
    case compact, cards, automatic

    static let defaultsKey = "ClinicSessionRowStyle"
    static let `default`: SessionRowStyle = .automatic

    var id: String { rawValue }
    var title: String {
        switch self {
        case .compact: "Compact"
        case .cards: "Cards"
        case .automatic: "Automatic"
        }
    }
    var symbol: String {
        switch self {
        case .compact: "list.bullet"
        case .cards: "rectangle.grid.1x2"
        case .automatic: "rectangle.stack"
        }
    }
    var help: String {
        switch self {
        case .compact: "One line per session"
        case .cards: "A card for every session"
        case .automatic: "Cards for sessions with something live, one line for the rest"
        }
    }
}

/// One row under a card: something the session started that is still worth seeing (ADR-156).
struct SessionCardChild: Identifiable {
    enum Status: Equatable {
        /// Wants the reader: a Grill round, a spawned session waiting.
        case needsYou
        case failed
        case running(since: Date?)
        case finished
        /// Neither running nor finished, like an open pull request with nothing pending.
        case quiet

        /// Needs you first, then what broke, then what is running (ADR-156).
        var rank: Int {
            switch self {
            case .needsYou: 0
            case .failed: 1
            case .running: 2
            case .quiet: 3
            case .finished: 4
            }
        }
    }

    enum Icon {
        case symbol(String)
        case pullRequest(PullRequestRef, PullRequestMark?)
    }

    let id: String
    let icon: Icon
    let label: String
    var detail: String?
    let status: Status
    let help: String
    let action: @MainActor () -> Void
}

/// Everything a card shows beyond the compact row, gathered from the stores that know it.
@MainActor
struct SessionCardContent {
    var children: [SessionCardChild] = []
    /// "2 agents · 1 shell finished": transcript children that ended since the last prompt.
    var finishedSummary: String?
    /// Something under the card wants the reader, so the header glyph does too.
    var needsYou = false

    /// True when a card has something live to show, which is what Automatic promotes on.
    var isLive: Bool { children.contains { $0.status != .quiet && $0.status != .finished } }

    static func make(summary: SessionSummary, tab: Tab?, activity: SessionActivity?,
                     sessions: SessionStore, tabs: TabStore, prs: PRStore) -> SessionCardContent {
        var content = SessionCardContent()
        var rows: [SessionCardChild] = []
        let id = summary.id

        // Subagents, background shells and monitors, from the transcript.
        if let activity {
            for child in activity.children where child.outcome != .completed && child.outcome != .stopped {
                rows.append(transcriptRow(child, summary: summary, sessions: sessions, tabs: tabs))
            }
            let done = activity.children.filter { $0.outcome == .completed || $0.outcome == .stopped }
            content.finishedSummary = finishedSummary(done)
        }

        // Grill rounds waiting for answers (ADR-142).
        for round in sessions.openGrillRounds(for: id) {
            let answered = round.answeredCount, total = round.questions.count
            rows.append(SessionCardChild(
                id: "grill-\(round.id)", icon: .symbol("flame"),
                label: round.topic ?? (total == 1 ? "A question" : "\(total) questions"),
                detail: answered > 0 ? "\(answered) of \(total) answered" : nil,
                status: .needsYou, help: "Answer in the Grill pane",
                action: { tabs.reveal(sessionId: id); if let tab = tabs.tab(for: id) { tabs.toggleGrill(tab) } }))
        }

        // Runs in the session's checkout (ADR-122). A run belongs to the checkout, so every session
        // working there shows it.
        let projectPath = tab?.projectPath ?? ProjectGrouping.projectPath(forCwd: summary.lastCwd ?? summary.cwd ?? "")
        let checkout = tab.flatMap { tabs.runs.checkout(for: $0) }
            ?? (projectPath.isEmpty || SessionStore.isChats(projectPath) ? nil
                : RunCheckout.root(forCwd: summary.lastCwd ?? summary.cwd ?? projectPath, projectPath: projectPath))
        if let checkout {
            for run in tabs.runs.runs(inCheckout: checkout) {
                let status: SessionCardChild.Status
                switch run.status {
                case .running(let since): status = .running(since: run.preparing == nil ? since : nil)
                // A failure is news while the session is open; on a closed one it would never go away.
                case .failed where tab != nil: status = .failed
                default: continue
                }
                let key = run.key
                rows.append(SessionCardChild(
                    id: "run-\(key)", icon: .symbol(SFSymbolCatalog.resolved(run.config.icon ?? "play.fill")),
                    label: run.name, detail: run.preparing ?? run.device?.name, status: status,
                    help: "Show the run's output",
                    action: {
                        tabs.reveal(sessionId: id)
                        if let tab = tabs.tab(for: id) { tabs.openRunPane(key, in: tab, front: true) }
                    }))
            }
        }

        // Open pull requests (ADR-087). Merged and closed ones stay in the header's badge.
        for ref in prs.ordered(summary.pullRequests) {
            let mark = prs.mark(for: ref)
            guard mark == nil || mark?.state == .open else { continue }
            let status: SessionCardChild.Status = switch mark?.attention {
            case .checksFailing: .failed
            case .checksPending: .running(since: nil)
            default: .quiet
            }
            var detail = mark?.summary
            if let d = detail, d.hasPrefix("Open · ") { detail = String(d.dropFirst("Open · ".count)) }
            else if detail == "Open" { detail = nil }
            rows.append(SessionCardChild(
                id: "pr-\(ref.id)", icon: .pullRequest(ref, mark), label: ref.codeHost.reference(ref.number),
                detail: detail, status: status, help: mark?.summary ?? ref.codeHost.noun,
                action: { tabs.reveal(sessionId: id, pullRequest: ref) }))
        }

        // A panel terminal with a job in the foreground (ADR-079).
        if let tab, let surface = tab.panel.pane(.terminal)?.terminal, let job = surface.foregroundJobName {
            rows.append(SessionCardChild(
                id: "terminal-\(tab.id)", icon: .symbol("terminal"), label: job, detail: "Terminal",
                status: .running(since: nil), help: "Show the terminal pane",
                action: { tabs.select(tab); tabs.showPane(.terminal, in: tab) }))
        }

        // Sessions this one started with `start_session`, while they are open.
        for (childId, parent) in sessions.state.spawnedBy where parent == id {
            guard let childTab = tabs.tab(for: childId), childTab.state != .exited, !childTab.childExited else { continue }
            let name = sessions.sessions[childId].map(sessions.displayName(for:)) ?? childTab.title
            let status: SessionCardChild.Status = switch childTab.state {
            case .working, .launching: .running(since: nil)
            case .waitingForInput, .waitingForPermission: .needsYou
            default: .quiet
            }
            rows.append(SessionCardChild(
                id: "session-\(childId)", icon: .symbol("arrow.turn.down.right"), label: name, detail: "Session",
                status: status, help: "Go to the session it started",
                action: { tabs.reveal(sessionId: childId) }))
        }

        content.children = rows.enumerated()
            .sorted { ($0.element.status.rank, $0.offset) < ($1.element.status.rank, $1.offset) }
            .map(\.element)
        content.needsYou = rows.contains { $0.status == .needsYou }
        return content
    }

    private static func transcriptRow(_ child: SessionActivity.Child, summary: SessionSummary,
                                      sessions: SessionStore, tabs: TabStore) -> SessionCardChild {
        let status: SessionCardChild.Status = child.outcome == .failed ? .failed : .running(since: child.startedAt)
        switch child.kind {
        case .agent:
            let transcript = child.taskId.map { Self.subagentTranscript(agentId: $0, session: summary) }
            return SessionCardChild(
                id: child.id, icon: .symbol("sparkles"), label: child.label, detail: child.detail, status: status,
                help: transcript == nil ? "Subagent" : "Replay this subagent's transcript",
                action: {
                    guard let path = transcript, FileManager.default.fileExists(atPath: path) else {
                        tabs.reveal(sessionId: summary.id); return
                    }
                    var s = SessionSummary(id: SessionID("agent-\(child.taskId ?? child.id)"), transcriptPath: path,
                                           cwd: summary.lastCwd ?? summary.cwd)
                    s.customTitle = "\(child.label) · \(sessions.displayName(for: summary))"
                    tabs.openReplay(s)
                })
        case .shell, .monitor:
            let file = child.outputFile
            return SessionCardChild(
                id: child.id, icon: .symbol(child.kind == .shell ? "apple.terminal" : "waveform.path.ecg"),
                label: child.label, detail: child.kind == .monitor ? "Monitor" : nil, status: status,
                help: file == nil ? "Background task" : "Open its output",
                action: {
                    guard let file, FileManager.default.fileExists(atPath: file) else { tabs.reveal(sessionId: summary.id); return }
                    FileWindowController.show(path: file, root: (file as NSString).deletingLastPathComponent)
                })
        }
    }

    /// `<transcript without .jsonl>/subagents/agent-<id>.jsonl`, where the CLI keeps a subagent's own turns.
    static func subagentTranscript(agentId: String, session: SessionSummary) -> String {
        ((session.transcriptPath as NSString).deletingPathExtension as NSString)
            .appendingPathComponent("subagents/agent-\(agentId).jsonl")
    }

    static func finishedSummary(_ done: [SessionActivity.Child]) -> String? {
        guard !done.isEmpty else { return nil }
        let parts: [(SessionActivity.Child.Kind, String, String)] = [(.agent, "agent", "agents"), (.shell, "shell", "shells"), (.monitor, "monitor", "monitors")]
        let counted = parts.compactMap { kind, one, many -> String? in
            let n = done.filter { $0.kind == kind }.count
            return n == 0 ? nil : "\(n) \(n == 1 ? one : many)"
        }
        return counted.joined(separator: " · ") + " finished"
    }
}

/// A session drawn as a card (ADR-156): the compact row's glyph, title and badges, then where it is,
/// what it is doing, and what it has running. Every zone is dropped when it has nothing to say.
struct SessionCard: View {
    @Environment(SessionStore.self) private var sessions
    @Environment(TabStore.self) private var tabs
    @Environment(BackgroundAgentsService.self) private var background
    let summary: SessionSummary
    let tab: Tab?
    let activity: SessionActivity?
    let content: SessionCardContent
    var showPath = false
    var isSelected = false
    var checked: Bool? = nil
    var onToggle: () -> Void = {}
    @State private var hovering = false
    @State private var expanded = false

    /// Rows shown before the rest fold into "+N more".
    private static let visibleChildren = 4

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if let checked {
                Button(action: onToggle) {
                    Image(systemName: checked ? "checkmark.circle.fill" : "circle").foregroundStyle(checked ? Color.accent : Color.secondary)
                }.buttonStyle(.plain)
            }
            VStack(alignment: .leading, spacing: 3) {
                header
                meta
                nowLine
                children
            }
        }
        .padding(.vertical, 5)
        .opacity(sessions.isArchived(summary.id) ? 0.5 : 1)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .sidebarRowHover(hovering)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            SessionLeadingGlyph(summary: summary, tab: tab, needsYou: content.needsYou)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            Text(sessions.displayName(for: summary))
                .fontWeight(.medium)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            if hovering {
                SessionHoverActions(summary: summary, tab: tab)
            } else {
                HStack(spacing: 4) {
                    SessionBadges(summary: summary)
                    Text(Self.shortAge(summary.activityDate))
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
        }
    }

    // MARK: Where and how

    @ViewBuilder
    private var meta: some View {
        let branch = tab?.gitBranch ?? summary.gitBranch
        let live = tab != nil
        // The status line is the CLI's own account (ADR-157); the transcript stands in where there is none.
        let report = tab?.statusLine
        let model = report?.modelDisplayName ?? activity?.modelName ?? (activity?.model ?? summary.model).map(ModelName.display)
        let facts = live ? [model, report?.effort ?? tab?.effort].compactMap { $0 } : []
        let percent = live ? report?.contextUsedPercentage : nil
        let tokens = live && percent == nil ? activity?.contextTokens : nil
        let path = showPath ? (summary.lastCwd ?? summary.cwd).map(TabFooter.abbreviate) : nil
        let place = branch != nil || path != nil
        if place || !facts.isEmpty || percent != nil || tokens != nil {
            // Where gives way before how: a long branch truncates in the middle rather than pushing the
            // model, effort and context off the edge (ADR-158).
            HStack(spacing: 4) {
                if let branch {
                    Image(systemName: "arrow.triangle.branch").imageScale(.small)
                    Text(branch).lineLimit(1).truncationMode(.middle)
                }
                if let path {
                    if branch != nil { Text("·") }
                    Text(path).lineLimit(1).truncationMode(.head)
                }
                ForEach(Array(facts.enumerated()), id: \.offset) { i, fact in
                    if place || i > 0 { Text("·").layoutPriority(1) }
                    Text(fact).lineLimit(1).layoutPriority(1)
                }
                if let percent {
                    if place || !facts.isEmpty { Text("·").layoutPriority(2) }
                    ContextGauge(percent: percent, windowSize: report?.contextWindowSize).fixedSize().layoutPriority(2)
                } else if let tokens {
                    if place || !facts.isEmpty { Text("·").layoutPriority(2) }
                    Text(Self.tokens(tokens)).lineLimit(1).fixedSize().layoutPriority(2)
                        .help("\(tokens.formatted()) tokens in context")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.leading, Self.textInset)
        }
    }

    // MARK: Now

    @ViewBuilder
    private var nowLine: some View {
        if let now {
            now.text
                .font(.subheadline)
                .foregroundStyle(now.urgent && !isSelected ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
                .lineLimit(2)
                .padding(.leading, Self.textInset)
        }
    }

    private var now: (text: Text, urgent: Bool)? {
        let tool = activity?.currentTool
        switch tab?.state {
        case .working:
            guard let tool else { return nil }
            return (Text(tool.name).fontWeight(.semibold) + Text(" " + Self.target(tool)), false)
        case .waitingForPermission:
            guard let tool else { return (Text("Needs your permission"), true) }
            return (Text("Allow ") + Text(tool.name).fontWeight(.semibold) + Text(" " + Self.target(tool) + "?"), true)
        case .waitingForInput:
            return (Text("Waiting for your input"), true)
        default:
            if tab == nil, let agent = background.runningAgent(for: summary.id), let waiting = agent.waitingFor {
                return (Text(waiting), agent.needsAttention)
            }
            return (activity?.recap ?? summary.recap).map { (Text($0), false) }
        }
    }

    // MARK: Children

    @ViewBuilder
    private var children: some View {
        let rows = content.children
        if !rows.isEmpty || content.finishedSummary != nil {
            let folds = rows.count > Self.visibleChildren && !expanded
            let shown = folds ? Array(rows.prefix(Self.visibleChildren - 1)) : rows
            VStack(alignment: .leading, spacing: 1) {
                ForEach(shown) { SessionCardChildRow(child: $0, isSelected: isSelected) }
                if folds {
                    SessionCardFooterRow(symbol: "ellipsis", text: "\(rows.count - shown.count) more") { expanded = true }
                }
                if let finished = content.finishedSummary {
                    SessionCardFooterRow(symbol: "checkmark", text: finished, action: nil)
                }
            }
            .padding(.leading, Self.textInset)
            // A hairline under the glyph column hangs the children off the session. A background, not a
            // sibling: as a sibling the bare `Rectangle` was greedy, taking whatever height the list row
            // offered — extra space under the last child, and a now line squeezed to one line (ADR-158).
            .background(alignment: .leading) {
                Rectangle().fill(.quaternary).frame(width: 1).padding(.leading, SessionLeadingGlyph.size / 2)
            }
            .padding(.top, 2)
        }
    }

    // MARK: Formatting

    /// The glyph column plus the gap: where the title starts, so every zone lines up under it.
    static let textInset: CGFloat = SessionLeadingGlyph.size + 8

    /// "now", "4m", "3h", "2d", "5w": the header has room for a few characters, not a phrase.
    static func shortAge(_ date: Date, now: Date = Date()) -> String {
        let s = max(0, now.timeIntervalSince(date))
        switch s {
        case ..<60: return "now"
        case ..<3600: return "\(Int(s / 60))m"
        case ..<86_400: return "\(Int(s / 3600))h"
        case ..<(86_400 * 7): return "\(Int(s / 86_400))d"
        default: return "\(Int(s / (86_400 * 7)))w"
        }
    }

    /// "84k tokens": the transcript's count, when no status line has said how big the window is.
    static func tokens(_ n: Int) -> String {
        n >= 1000 ? "\((n + 500) / 1000)k tokens" : "\(n) tokens"
    }

    /// A file tool's file name, otherwise the tool's own summary.
    static func target(_ tool: SessionActivity.Tool) -> String {
        if ["Read", "Write", "Edit", "MultiEdit", "NotebookEdit"].contains(tool.name), tool.summary.hasPrefix("/") {
            return (tool.summary as NSString).lastPathComponent
        }
        return tool.summary
    }
}

struct SessionCardChildRow: View {
    let child: SessionCardChild
    let isSelected: Bool
    @State private var hovering = false

    var body: some View {
        Button(action: child.action) {
            HStack(spacing: 6) {
                icon.frame(width: 14)
                (Text(child.label) + Text(child.detail.map { " · \($0)" } ?? "").foregroundColor(.secondary))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                trailing
            }
            .font(.subheadline)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(hovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(child.help)
        .onHover { hovering = $0 }
    }

    @ViewBuilder
    private var icon: some View {
        switch child.icon {
        case .symbol(let name):
            Image(systemName: name).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
        case .pullRequest(let ref, let mark):
            PRGlyph(host: ref.codeHost, mark: mark, size: 11)
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch child.status {
        case .needsYou:
            PulsingDot(color: .orange).frame(width: 7, height: 7)
        case .failed:
            HStack(spacing: 3) {
                Text("failed")
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
            }
            .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(Color.red))
            .font(.caption)
        case .running(let since):
            HStack(spacing: 4) {
                if let since {
                    Text(since, style: .timer).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                SpinningArc(tint: AnyShapeStyle(HierarchicalShapeStyle.secondary), size: 8)
                    .frame(width: 8, height: 8)
            }
        case .finished:
            Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
        case .quiet:
            EmptyView()
        }
    }
}

/// "+2 more" and "2 agents finished": quieter rows at the foot of a card's children.
private struct SessionCardFooterRow: View {
    let symbol: String
    let text: String
    let action: (() -> Void)?
    @State private var hovering = false

    var body: some View {
        let row = HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 9, weight: .semibold)).frame(width: 14)
            Text(text).lineLimit(1)
            Spacer(minLength: 0)
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        if let action {
            Button(action: action) {
                row.background(hovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 5))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
        } else {
            row
        }
    }
}

/// Decides, per session, between the card and the compact row, and builds the card's content
/// (ADR-156). Automatic gives a card to a session that is open, running detached, or has anything
/// under it still going; Cards gives every session one.
struct SessionCardSlot: View {
    @Environment(SessionStore.self) private var sessions
    @Environment(TabStore.self) private var tabs
    @Environment(PRStore.self) private var prs
    @Environment(SessionActivityStore.self) private var activities
    @Environment(BackgroundAgentsService.self) private var background
    let summary: SessionSummary
    let tab: Tab?
    let style: SessionRowStyle
    var showPath = false
    var isSelected = false
    var checked: Bool? = nil
    var onToggle: () -> Void = {}

    var body: some View {
        // A terminal's foreground job changes without an event to observe, so a card with a terminal
        // pane looks again every few seconds.
        if tab?.panel.pane(.terminal)?.terminal != nil {
            TimelineView(.periodic(from: .now, by: 3)) { _ in slot }
        } else {
            slot
        }
    }

    @ViewBuilder
    private var slot: some View {
        let activity = activities.activity(for: summary.id)
        let content = SessionCardContent.make(summary: summary, tab: tab, activity: activity,
                                              sessions: sessions, tabs: tabs, prs: prs)
        let live = tab != nil || background.runningAgent(for: summary.id) != nil || content.isLive
        if style == .cards || live {
            SessionCard(summary: summary, tab: tab, activity: activity, content: content, showPath: showPath,
                        isSelected: isSelected, checked: checked, onToggle: onToggle)
        } else {
            SessionRow(summary: summary, tab: tab, showPath: showPath, checked: checked, onToggle: onToggle)
        }
    }
}

/// The sidebar toolbar's row-style choice (ADR-156), drawn like its `ToolbarIcon` neighbours.
struct SessionRowStyleMenu: View {
    @Binding var style: String
    @State private var hovering = false

    private var current: SessionRowStyle { SessionRowStyle(rawValue: style) ?? .default }

    var body: some View {
        Menu {
            Picker("Session Rows", selection: $style) {
                ForEach(SessionRowStyle.allCases) { s in
                    Label(s.title, systemImage: s.symbol).tag(s.rawValue)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: current.symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(hovering ? AnyShapeStyle(HierarchicalShapeStyle.primary) : AnyShapeStyle(.secondary))
                .frame(width: 28, height: 24)
                .background(hovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Session rows: \(current.title) — \(current.help)")
        .accessibilityLabel("Session rows")
        .onHover { hovering = $0 }
    }
}

/// How full the context window is, as the mockup drew it: a short bar and the percentage (ADR-158).
/// Secondary like the rest of the meta line; on a selected row it follows the row's label colour.
struct ContextGauge: View {
    let percent: Double
    var windowSize: Int?

    static let width: CGFloat = 26

    var body: some View {
        let p = max(0, min(100, percent))
        // Rounded down, so a nearly full window never reads 100% early.
        let shown = Int(p.rounded(.down))
        HStack(spacing: 3) {
            Capsule()
                .fill(.quaternary)
                .frame(width: Self.width, height: 4)
                .overlay(alignment: .leading) {
                    Capsule().fill(.secondary).frame(width: max(2, Self.width * p / 100), height: 4)
                }
            Text("\(shown)%").monospacedDigit()
        }
        .help(windowSize.map { "\(shown)% of the \(($0 + 500) / 1000)k context window used" } ?? "\(shown)% of the context window used")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Context \(shown)% used")
    }
}
