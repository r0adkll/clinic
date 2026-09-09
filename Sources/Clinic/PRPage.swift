import SwiftUI
import ClinicCore

/// Right-column pull request page (ADR-053, ADR-087, restructured by ADR-091).
///
/// Three fixed regions: an identity header, the `PullRequestStatus` block with the actions, and a
/// tab strip over Conversation / Checks / Files. The status block stays pinned rather than living in
/// a tab — ADR-087 exists because "is this mergeable" used to need a click, and putting it back
/// behind one would undo that. Checks and Files each get a whole pane instead of a collapsible strip,
/// because both are browsing surfaces: a CI matrix and a file tree want room, not a disclosure arrow.
struct PRPage: View {
    @Environment(PRStore.self) private var prs
    @Environment(TabStore.self) private var tabs
    let tab: Tab
    let ref: PullRequestRef
    @State private var pane: Pane = .conversation
    @State private var files = PRFilesModel()
    @State private var confirm: PendingAction?

    enum Pane: String, CaseIterable, Identifiable {
        case conversation, checks, files
        var id: String { rawValue }
        var title: String {
            switch self {
            case .conversation: "Conversation"
            case .checks: "Checks"
            case .files: "Files"
            }
        }
    }

    struct PendingAction: Identifiable { let id = UUID(); let title: String; let message: String; let run: () async -> Void }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .task(id: ref.id) { if prs.pullRequest(for: ref) == nil { await prs.refresh(ref) } }
        .alert(confirm?.title ?? "", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } })) {
            Button("Cancel", role: .cancel) { confirm = nil }
            Button(confirm?.title ?? "OK") { if let c = confirm { Task { await c.run() } }; confirm = nil }
        } message: { Text(confirm?.message ?? "") }
    }

    @ViewBuilder
    private var content: some View {
        if let availability = prs.availability, !availability.isReady {
            GitHubUnavailableView(availability: availability) { await prs.refreshAvailability() }
        } else if let pr = prs.pullRequest(for: ref) {
            let status = PullRequestStatus(pr: pr, viewerLogin: prs.viewerLogin)
            statusBlock(pr, status)
            Divider()
            panePicker(pr)
            Divider()
            switch pane {
            case .conversation: conversation(pr)
            case .checks: checks(pr)
            case .files: PRFilesView(ref: ref, model: files)
            }
            if let error = prs.errors[ref.id] {
                Divider()
                Text(error).font(.caption).foregroundStyle(.red).lineLimit(2).padding(6)
            }
        } else if let error = prs.errors[ref.id] {
            ContentUnavailableView("Could not load PR #" + String(ref.number), systemImage: "exclamationmark.triangle", description: Text(error))
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Header

    private var header: some View {
        let pr = prs.pullRequest(for: ref)
        let mark = prs.mark(for: ref)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                if let mark {
                    Image(systemName: mark.symbolName)
                        .font(.system(size: PRStyle.glyphSize.header))
                        .foregroundStyle(PRStyle.color(mark))
                }
                Text(pr?.title ?? "Pull request #" + String(ref.number)).font(.headline).lineLimit(2)
                Spacer(minLength: 8)
                Button { Task { await prs.refresh(ref) } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Refresh")
                Button { NSWorkspace.shared.open(ref.url) } label: { Image(systemName: "safari") }
                    .buttonStyle(.borderless).help("Open on GitHub")
            }
            HStack(spacing: 6) {
                if let pr { PRStateBadge(pr: pr) }
                Text("#" + String(ref.number)).monospacedDigit()
                if let pr {
                    Text("·")
                    Text(pr.author.login)
                    Text("·")
                    Text("\(pr.headRefName) → \(pr.baseRefName)")
                        .font(.system(.caption, design: .monospaced)).lineLimit(1).truncationMode(.head)
                }
                Spacer(minLength: 0)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(.bar)
    }

    // MARK: Status + actions

    private func statusBlock(_ pr: PullRequest, _ status: PullRequestStatus) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(status.lines) { line in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: line.symbol)
                            .foregroundStyle(PRStyle.tint(line.tone))
                            .font(.system(size: PRStyle.glyphSize.statusLine))
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(line.text).font(.subheadline.weight(line.tone == .blocking ? .semibold : .regular))
                            if let detail = line.detail {
                                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            actions(pr, status)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func actions(_ pr: PullRequest, _ status: PullRequestStatus) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            if pr.state == .open {
                if let action = status.action {
                    Button { send(action.prompt) } label: {
                        Label(action.title, systemImage: action.symbol).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(tab.state != .idle)
                    .help(tab.state == .idle ? "Types the prompt into this session" : "The session must be idle at its prompt")
                }
                HStack(spacing: 7) {
                    if pr.isDraft {
                        Button("Ready for review") {
                            confirm = PendingAction(title: "Mark ready", message: "Mark #\(ref.number) ready for review?") {
                                await prs.perform(ref) { try await $0.markReady(ref) }
                            }
                        }
                    } else {
                        Button("Merge (\(prs.mergeMethod.rawValue))") {
                            confirm = PendingAction(title: "Merge", message: "Merge #\(ref.number) into \(pr.baseRefName) with \(prs.mergeMethod.rawValue)?") {
                                await prs.perform(ref) { try await $0.merge(ref, method: prs.mergeMethod, auto: false) }
                            }
                        }
                        .disabled(!status.canMerge)
                        .help(status.mergeBlockedReason ?? "Merge into \(pr.baseRefName)")
                        if pr.autoMergeEnabled {
                            Button("Disable auto-merge") { Task { await prs.perform(ref) { try await $0.disableAutoMerge(ref) } } }
                        } else {
                            Button("Auto-merge") {
                                confirm = PendingAction(title: "Auto-merge", message: "Merge #\(ref.number) automatically when checks pass?") {
                                    await prs.perform(ref) { try await $0.merge(ref, method: prs.mergeMethod, auto: true) }
                                }
                            }
                            .disabled(!status.canMerge)
                            .help(status.mergeBlockedReason ?? "Merge once the checks pass")
                        }
                    }
                    Spacer(minLength: 0)
                    Menu {
                        Button("Address the CI failures") { send("The CI checks on PR #\(ref.number) (\(ref.url)) are failing. Investigate the failures and fix them.") }
                        Button("Resolve the conflicts") { send("PR #\(ref.number) (\(ref.url)) has merge conflicts with \(pr.baseRefName). Rebase or merge \(pr.baseRefName) and resolve them.") }
                        Button("Address the review comments") { send("Address the unresolved review comments on PR #\(ref.number) (\(ref.url)).") }
                        Button("Review this PR") { send("Review PR #\(ref.number) (\(ref.url)) and summarize any problems.") }
                    } label: {
                        Label("Send to session", systemImage: "text.append")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .disabled(tab.state != .idle)
                    .help(tab.state == .idle ? "Types a prompt into the session" : "The session must be idle at its prompt")
                }
                .controlSize(.small)
            }
        }
    }

    private func send(_ prompt: String) {
        if tabs.sendSlashCommand(prompt, to: tab) { tabs.select(tab) }
    }

    // MARK: Panes

    /// Counts live on the tabs so the reader can see where the activity is without switching.
    private func panePicker(_ pr: PullRequest) -> some View {
        HStack(spacing: 2) {
            ForEach(Pane.allCases) { p in
                Button { pane = p } label: {
                    HStack(spacing: 5) {
                        Text(p.title).font(.callout.weight(pane == p ? .semibold : .regular))
                        switch p {
                        case .conversation where !pr.comments.isEmpty:
                            CountBadge(count: pr.comments.count, tone: .neutral)
                        case .checks where !pr.checks.isEmpty:
                            CountBadge(count: pr.checks.count,
                                       tone: pr.checks.contains { $0.status == .failure } ? .blocking
                                           : pr.checks.contains { $0.status == .pending } ? .waiting : .good)
                        case .files where pr.changedFiles > 0:
                            CountBadge(count: pr.changedFiles, tone: .neutral)
                        default:
                            EmptyView()
                        }
                    }
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(pane == p ? Color.primary.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
            if pane == .files, let d = prs.diffs[ref.id], !d.files.isEmpty {
                let adds = d.files.reduce(0) { $0 + $1.additions }
                let dels = d.files.reduce(0) { $0 + $1.deletions }
                Text("+\(adds)").font(.caption.monospacedDigit()).foregroundStyle(.green)
                Text("−\(dels)").font(.caption.monospacedDigit()).foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
    }

    // MARK: Conversation

    private func conversation(_ pr: PullRequest) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                descriptionCard(pr)
                ForEach(pr.comments) { c in commentRow(c) }
                if pr.comments.isEmpty {
                    Text("No comments or reviews yet.")
                        .font(.callout).foregroundStyle(.secondary)
                        .padding(.horizontal, 12).padding(.vertical, 16)
                }
            }
            .padding(.vertical, 10)
        }
    }

    private func descriptionCard(_ pr: PullRequest) -> some View {
        TimelineRow(avatar: pr.author.avatarURL, login: pr.author.login, symbol: nil,
                    date: pr.createdAt, badge: nil, isFirst: true, isLast: pr.comments.isEmpty) {
            if let html = pr.bodyHTML, !html.isEmpty {
                GitHubHTMLView(html: html)
            } else if pr.body.isEmpty {
                Text("No description.").font(.callout).foregroundStyle(.secondary)
            } else {
                MarkdownText(pr.body)
            }
        }
    }

    private func commentRow(_ c: PullRequest.Comment) -> some View {
        TimelineRow(avatar: c.author.avatarURL, login: c.author.login,
                    symbol: c.kind == .comment ? nil : "eye",
                    date: c.createdAt,
                    badge: c.reviewState.flatMap { $0.isEmpty ? nil : $0.lowercased().replacingOccurrences(of: "_", with: " ") },
                    isFirst: false, isLast: c.id == lastCommentID) {
            if let path = c.path {
                Text(path + (c.line.map { ":\($0)" } ?? ""))
                    .font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
            }
            if let html = c.bodyHTML, !html.isEmpty {
                GitHubHTMLView(html: html)
            } else if !c.body.isEmpty {
                MarkdownText(c.body)
            }
        }
    }

    private var lastCommentID: String? { prs.pullRequest(for: ref)?.comments.last?.id }

    // MARK: Checks

    private func checks(_ pr: PullRequest) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(PRChecksGroup.group(pr.checks)) { group in
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 6) {
                            Text(group.name).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                            Text(group.summary).font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 12).padding(.bottom, 4)
                        ForEach(group.checks) { CheckRow(check: $0) }
                    }
                }
                if pr.checks.isEmpty {
                    ContentUnavailableView("No checks reported", systemImage: "checkmark.circle",
                                           description: Text("Nothing ran on this pull request."))
                        .padding(.top, 24)
                }
            }
            .padding(.vertical, 10)
        }
    }
}

/// A small count pill on a tab.
private struct CountBadge: View {
    let count: Int
    let tone: PullRequestStatus.Tone

    var body: some View {
        Text("\(count)")
            .font(.caption2.monospacedDigit().weight(.medium))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(tone == .neutral ? Color.primary.opacity(0.09) : PRStyle.tint(tone).opacity(0.18), in: Capsule())
            .foregroundStyle(tone == .neutral ? Color.secondary : PRStyle.tint(tone))
    }
}

/// One entry in the conversation: avatar on a continuous rail, header line, then the body.
///
/// The rail is what makes a thread read as a thread. Detached rounded cards gave every comment the
/// same weight and no sense of order, which is exactly what a PR conversation is *about* (ADR-091).
private struct TimelineRow<Content: View>: View {
    let avatar: URL?
    let login: String
    let symbol: String?
    let date: Date
    let badge: String?
    let isFirst: Bool
    let isLast: Bool
    @ViewBuilder var content: Content

    private static var railX: CGFloat { 12 + 11 }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            ZStack(alignment: .top) {
                // The rail runs the full height of the row and is clipped at the ends of the thread,
                // so consecutive rows join into one line without drawing it twice.
                Rectangle()
                    .fill(Color.primary.opacity(0.12))
                    .frame(width: 1)
                    .padding(.top, isFirst ? 22 : 0)
                    .frame(maxHeight: isLast ? 22 : .infinity, alignment: .top)
                Avatar(url: avatar, login: login, symbol: symbol)
            }
            .frame(width: 22)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(login).font(.caption.weight(.semibold))
                    if let badge {
                        Text(badge)
                            .font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                    Spacer(minLength: 0)
                    Text(date, format: .relative(presentation: .named))
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                content
            }
            .padding(.bottom, isLast ? 0 : 16)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// GitHub avatar, falling back to the initial while it loads or when there is no URL.
private struct Avatar: View {
    let url: URL?
    let login: String
    let symbol: String?

    var body: some View {
        Group {
            if let url {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    placeholder
                }
            } else {
                placeholder
            }
        }
        .frame(width: 22, height: 22)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Color.primary.opacity(0.12)))
        .overlay(alignment: .bottomTrailing) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 7, weight: .bold))
                    .padding(2)
                    .background(.background, in: Circle())
                    .offset(x: 3, y: 3)
            }
        }
    }

    private var placeholder: some View {
        ZStack {
            Color.primary.opacity(0.09)
            Text(login.prefix(1).uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
        }
    }
}

/// Checks grouped by the workflow that produced them, which is how CI is actually read: a failure
/// belongs to a workflow, and "3 of 5 in Build" is more use than five unrelated rows (ADR-091).
struct PRChecksGroup: Identifiable {
    let name: String
    let checks: [PullRequest.Check]
    var id: String { name }

    var summary: String {
        let failed = checks.filter { $0.status == .failure }.count
        let pending = checks.filter { $0.status == .pending }.count
        if failed > 0 { return "\(failed) failed" }
        if pending > 0 { return "\(pending) running" }
        return "\(checks.count) passed"
    }

    static func group(_ checks: [PullRequest.Check]) -> [PRChecksGroup] {
        var order: [String] = []
        var byName: [String: [PullRequest.Check]] = [:]
        for c in checks {
            let key = c.workflow ?? "Other"
            if byName[key] == nil { order.append(key) }
            byName[key, default: []].append(c)
        }
        // Workflows with a failure first: the reason you opened this tab is at the top.
        return order.map { PRChecksGroup(name: $0, checks: byName[$0] ?? []) }
            .sorted { a, b in
                let af = a.checks.contains { $0.status == .failure }, bf = b.checks.contains { $0.status == .failure }
                return af == bf ? false : af
            }
    }
}

private struct CheckRow: View {
    let check: PullRequest.Check
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(PRStyle.checkColor(check.status))
                .frame(width: 2)
                .opacity(check.status == .success ? 0.5 : 1)
            Image(systemName: PRStyle.checkSymbol(check.status))
                .foregroundStyle(PRStyle.checkColor(check.status))
                .font(.caption)
            VStack(alignment: .leading, spacing: 1) {
                Text(check.name).font(.subheadline).lineLimit(1)
                if let duration { Text(duration).font(.caption2).foregroundStyle(.tertiary) }
            }
            Spacer(minLength: 0)
            if let url = check.detailsURL {
                Button { NSWorkspace.shared.open(url) } label: {
                    Image(systemName: "arrow.up.right.square")
                }
                .buttonStyle(.borderless)
                .opacity(hovering ? 1 : 0.45)
                .help("Open the run on GitHub")
            }
        }
        .padding(.trailing, 12).padding(.vertical, 4)
        .background(hovering ? Color.primary.opacity(0.05) : .clear)
        .onHover { hovering = $0 }
    }

    /// Elapsed time, only once a run has actually finished.
    private var duration: String? {
        guard let start = check.startedAt, let end = check.completedAt else { return nil }
        let seconds = Int(end.timeIntervalSince(start))
        guard seconds > 0 else { return nil }
        return seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(seconds % 60)s"
    }
}

/// What to say when `gh` cannot answer. Splitting "not installed" from "not logged in" matters:
/// a GUI-launched Clinic searches a `PATH` the user's terminal does not have, so a perfectly
/// authenticated `gh` can still be invisible — and telling that user to log in is a dead end (ADR-086).
struct GitHubUnavailableView: View {
    let availability: GitHubService.Availability
    let retry: () async -> Void
    @State private var busy = false

    var body: some View {
        VStack(spacing: 12) {
            switch availability {
            case .ready:
                EmptyView()
            case .notInstalled(let path):
                ContentUnavailableView {
                    Label("Can't find the gh CLI", systemImage: "terminal")
                } description: {
                    VStack(spacing: 8) {
                        Text("Clinic runs `gh` to read pull requests, but it isn't on the PATH this app was launched with. Install it with `brew install gh`, or make sure your login shell exports its location.")
                        DisclosureGroup("Searched PATH") {
                            Text(path.replacingOccurrences(of: ":", with: "\n"))
                                .font(.system(.caption2, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .font(.caption)
                    }
                    .frame(maxWidth: 420)
                }
            case .notAuthenticated(let message):
                ContentUnavailableView {
                    Label("gh isn't logged in", systemImage: "person.crop.circle.badge.exclamationmark")
                } description: {
                    VStack(spacing: 8) {
                        Text("Run `gh auth login` in a terminal, then retry.")
                        if !message.isEmpty {
                            Text(message)
                                .font(.system(.caption2, design: .monospaced))
                                .textSelection(.enabled)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: 420)
                }
            }
            Button(busy ? "Checking…" : "Retry") {
                busy = true
                Task { await retry(); busy = false }
            }
            .disabled(busy)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct PRStateBadge: View {
    let pr: PullRequest
    var body: some View {
        let (text, color): (String, Color) = pr.state == .merged ? ("Merged", .purple) : pr.state == .closed ? ("Closed", .red) : pr.isDraft ? ("Draft", .secondary) : ("Open", .green)
        Text(text).font(.caption2.weight(.semibold)).foregroundStyle(color).padding(.horizontal, 6).padding(.vertical, 1).background(color.opacity(0.15), in: Capsule())
    }
}

/// Footer chip for one PR (ADR-053).
struct PRChip: View {
    @Environment(PRStore.self) private var prs
    let ref: PullRequestRef
    let active: Bool
    /// The PR's panel tab exists but another pane is in front.
    var open = false
    let onTap: () -> Void

    var body: some View {
        let mark = prs.mark(for: ref)
        Button(action: onTap) {
            HStack(spacing: 4) {
                Image(systemName: mark?.symbolName ?? PullRequestMark.symbol)
                    .font(.system(size: PRStyle.glyphSize.chip))
                Text("PR #" + String(ref.number)).monospacedDigit()
            }
            .font(.callout)
            .lineLimit(1)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(active ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(open && !active ? Color.accentColor.opacity(0.35) : .clear))
            .foregroundStyle(mark.map(PRStyle.color) ?? .primary)
        }
        .buttonStyle(.plain)
        .help(mark?.summary ?? "Pull request #" + String(ref.number))
        .contextMenu {
            Button("Open on GitHub") { NSWorkspace.shared.open(ref.url) }
            Button("Copy URL") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(ref.url.absoluteString, forType: .string) }
            Button("Refresh") { Task { await prs.refresh(ref) } }
        }
        .task { prs.ensureLoaded([ref]) }
    }
}

/// Sidebar glyph for a session's PRs (aggregate).
struct PRMarkView: View {
    @Environment(PRStore.self) private var prs
    let refs: [PullRequestRef]
    var body: some View {
        if let mark = prs.aggregateMark(for: refs) {
            Image(systemName: mark.symbolName).font(.system(size: PRStyle.glyphSize.sidebar))
                .foregroundStyle(PRStyle.color(mark)).help(mark.summary)
        } else if !refs.isEmpty {
            Image(systemName: PullRequestMark.symbol).font(.system(size: PRStyle.glyphSize.sidebar))
                .foregroundStyle(.tertiary).task { prs.ensureLoaded(refs) }
        }
    }
}

enum PRStyle {
    /// Point sizes for the PR glyph, per place it is drawn (ADR-089).
    ///
    /// Deliberately explicit rather than inherited from a text style. `arrow.trianglehead.pull` is a
    /// tall, narrow shape, so at the same point size as the boxy glyphs beside it (`terminal`,
    /// `doc.text.magnifyingglass`) it reads noticeably smaller — and its solid arrowhead, the whole
    /// reason for preferring it to the old chevron, does not resolve until a couple of points above
    /// the surrounding text. Each value is ~2 pt over its neighbour: macOS gives `.callout` 12 pt,
    /// `.caption` 10 pt and `.headline` 13 pt.
    enum glyphSize {
        /// Footer chip, beside a 12 pt `.callout` label.
        static let chip: CGFloat = 14
        /// Sidebar row, beside 10 pt secondary text.
        static let sidebar: CGFloat = 12
        /// Panel header, beside the 13 pt `.headline` title.
        static let header: CGFloat = 15
        /// Leading glyph on a status line, beside 11 pt `.subheadline`.
        static let statusLine: CGFloat = 13
        /// Panel tab strip, beside the other pane glyphs at 10 pt.
        static let tab: CGFloat = 12
    }

    static func color(_ mark: PullRequestMark) -> Color {
        switch mark.state {
        case .merged: return .purple
        case .closed: return .red
        case .open:
            switch mark.attention {
            case .checksFailing, .conflicts, .changesRequested: return .red
            case .unansweredComments: return .orange
            case .checksPending: return .yellow
            case .approved: return .green
            case .none: return mark.isDraft ? .secondary : .green
            }
        }
    }
    static func checkSymbol(_ s: PullRequest.Check.Status) -> String {
        switch s { case .success: "checkmark.circle.fill"; case .failure: "xmark.circle.fill"; case .pending: "clock"; case .skipped, .neutral: "minus.circle"; case .cancelled: "slash.circle"; case .unknown: "questionmark.circle" }
    }
    static func checkColor(_ s: PullRequest.Check.Status) -> Color {
        switch s { case .success: .green; case .failure: .red; case .pending: .yellow; default: .secondary }
    }
    /// Ink for a status line's tone (ADR-087). `waiting` is orange rather than yellow: yellow on the
    /// panel's `.bar` background is close to unreadable at caption size.
    static func tint(_ tone: PullRequestStatus.Tone) -> Color {
        switch tone { case .blocking: .red; case .waiting: .orange; case .good: .green; case .neutral: .secondary }
    }
}

/// Markdown body rendering: headings, fenced code, quotes and paragraphs as blocks; inline styles via AttributedString.
/// Tables, alerts, <details> and images are left as text (ADR-053 "not now").
struct MarkdownText: View {
    let markdown: String
    init(_ markdown: String) { self.markdown = markdown }

    enum Block: Identifiable { case heading(Int, String), code(String), quote(String), paragraph(String); var id: String { "\(self)" } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(Self.blocks(markdown).enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let level, let text):
                    inline(text).font(level <= 1 ? .title3.bold() : level == 2 ? .headline : .subheadline.bold()).padding(.top, 4)
                case .code(let code):
                    ScrollView(.horizontal) { Text(code).font(.system(.caption, design: .monospaced)).textSelection(.enabled).padding(8) }
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                case .quote(let text):
                    HStack(alignment: .top, spacing: 8) { RoundedRectangle(cornerRadius: 1).fill(.tertiary).frame(width: 3); inline(text).foregroundStyle(.secondary) }
                case .paragraph(let text):
                    inline(text)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func inline(_ text: String) -> Text {
        if let a = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) { return Text(a) }
        return Text(text)
    }

    static func blocks(_ md: String) -> [Block] {
        var out: [Block] = []; var para: [String] = []; var code: [String]? = nil
        func flush() { if !para.isEmpty { out.append(.paragraph(para.joined(separator: "\n"))); para = [] } }
        for raw in md.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if let c = code { if line.hasPrefix("```") { out.append(.code(c.joined(separator: "\n"))); code = nil } else { code!.append(line) }; continue }
            if line.hasPrefix("```") { flush(); code = []; continue }
            if line.trimmingCharacters(in: .whitespaces).isEmpty { flush(); continue }
            let hashes = line.prefix { $0 == "#" }.count
            if hashes > 0 && hashes <= 6 && line.dropFirst(hashes).first == " " { flush(); out.append(.heading(hashes, String(line.dropFirst(hashes + 1)))); continue }
            if line.hasPrefix("> ") { flush(); out.append(.quote(String(line.dropFirst(2)))); continue }
            para.append(line)
        }
        if let c = code { out.append(.code(c.joined(separator: "\n"))) }
        flush()
        return out
    }
}
