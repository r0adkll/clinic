import SwiftUI
import ClinicCore

/// Right-column pull request page (ADR-053, ADR-087, ADR-091), drawn in its service's own visual
/// language (ADR-116).
///
/// Three fixed regions: the identity header, the status block with the actions, and a tab strip over
/// Conversation / Checks / Files. The status block stays pinned rather than living in a tab — ADR-087
/// exists because "is this mergeable" used to need a click. ADR-116 changes whose language each region
/// speaks, not the regions: the header reads like the forge's PR header, the status block is its merge
/// box, and the tabs and timeline take its idiom. Anything that types into the session stays in
/// Clinic's accent and sits outside the merge box, so "this talks to Claude" and "this talks to
/// GitHub" never look alike.
struct PRPage: View {
    @Environment(PRStore.self) private var prs
    @Environment(TabStore.self) private var tabs
    let tab: Tab
    let ref: PullRequestRef
    /// `-ClinicPRPaneOnLaunch conversation|checks|files` (ADR-038): a smoke run can open the panel on
    /// a given tab rather than driving a synthetic click into it.
    @State private var pane: CodeHost.Pane = CodeHost.Pane(rawValue: UserDefaults.standard.string(forKey: "ClinicPRPaneOnLaunch") ?? "") ?? .conversation
    @State private var files = DiffBrowser()
    @State private var confirm: PendingAction?
    /// Merge-box lines whose checks the reader has shown or hidden, against the default: a blocking line
    /// starts open, so a failing build is a glance away, not a click (ADR-087).
    @State private var toggledLines: Set<String> = []
    /// The reader pressed ⟳ and that read has not landed yet (ADR-127).
    @State private var isRefreshing = false

    struct PendingAction: Identifiable { let id = UUID(); let title: String; let message: String; let run: () async -> Void }

    private var host: CodeHost { ref.codeHost }
    private var art: ServiceArt { host.art }

    var body: some View {
        VStack(spacing: 0) {
            header
            content
        }
        // The pane is only built while it is the one on screen, so this is also "came to the front":
        // ADR-127 re-reads a pull request that went stale while the pane was away, and starts watching
        // its checkout's refs.
        .task(id: ref.id) { await prs.attach(ref) }
        .alert(confirm?.title ?? "", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } })) {
            Button("Cancel", role: .cancel) { confirm = nil }
            Button(confirm?.title ?? "OK") { if let c = confirm { Task { await c.run() } }; confirm = nil }
        } message: { Text(confirm?.message ?? "") }
    }

    @ViewBuilder
    private var content: some View {
        if let availability = prs.availability, !availability.isReady {
            Divider()
            GitHubUnavailableView(availability: availability) { await prs.refreshAvailability() }
        } else if let pr = prs.pullRequest(for: ref) {
            let status = PullRequestStatus(pr: pr, viewerLogin: prs.viewerLogin)
            mergeBox(pr, status)
            if pr.state == .open { sessionActions(pr, status) } else { Spacer().frame(height: 12) }
            panePicker(pr)
            switch pane {
            case .conversation: conversation(pr)
            case .checks: checks(pr)
            case .files: PRFilesView(ref: ref, browser: files)
            }
            if let error = prs.errors[ref.id] {
                Divider()
                Text(error).font(.caption).foregroundStyle(.red).lineLimit(2).padding(6)
            }
        } else if let error = prs.errors[ref.id] {
            Divider()
            ContentUnavailableView("Could not load \(host.abbreviation) \(host.reference(ref.number))",
                                   systemImage: "exclamationmark.triangle", description: Text(error))
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 9) {
            serviceStrip
            if let pr = prs.pullRequest(for: ref) {
                identity(pr)
            } else {
                Text(host.noun + " " + host.reference(ref.number)).font(.system(size: 15, weight: .semibold))
            }
        }
        .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 12)
    }

    /// Whose PR this is: the service's mark and the repository, with "Open on GitHub" wearing the mark
    /// rather than Safari's compass.
    private var serviceStrip: some View {
        HStack(spacing: 7) {
            ServiceMark(host: host, size: 15)
            (Text(ref.owner + " / ").foregroundStyle(.secondary) + Text(ref.name).fontWeight(.semibold))
                .font(.callout)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            // Clinic's accent, not the service's (ADR-116): being told about this pull request is a
            // thing Clinic does for you, not a thing GitHub knows about.
            if let pr = prs.pullRequest(for: ref), !pr.isSettled {
                WatchToggle(watching: prs.isWatched(ref), verdict: PullRequestWatch.verdict(for: pr)) {
                    prs.setWatched(ref, !prs.isWatched(ref))
                }
            }
            // Spinning for the reader's own press only. An automatic read every fifteen seconds
            // (ADR-127) would otherwise blink the header at them; the Checks tab says the panel is
            // watching in words instead.
            RefreshButton(loading: isRefreshing, fetchedAt: prs.pullRequest(for: ref)?.fetchedAt) {
                // The one gesture that means "everything, now": the rendered bodies are re-fetched
                // whether or not ADR-127 thinks they are due.
                Task { isRefreshing = true; await prs.refresh(ref, html: .force); isRefreshing = false }
            }
            Button { NSWorkspace.shared.open(ref.url) } label: {
                Label { Text(host.openTitle) } icon: { ServiceMark(host: host, size: 12) }
            }
            .controlSize(.small)
            .help(ref.url.absoluteString)
        }
    }

    private func identity(_ pr: PullRequest) -> some View {
        let reviewers = pr.reviewers
        return VStack(alignment: .leading, spacing: 8) {
            (Text(pr.title) + Text("  " + host.reference(ref.number)).foregroundStyle(.secondary).fontWeight(.regular))
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            FlowLayout(spacing: 5) {
                ServiceStatePill(state: pr.state, isDraft: pr.isDraft, host: host)
                Avatar(url: pr.author.avatarURL, login: pr.author.login, size: 16)
                Text(pr.author.login).fontWeight(.semibold)
                let parts = host.mergeSentence(state: pr.state, head: pr.headRefName, base: pr.baseRefName, commits: pr.commitCount)
                ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                    switch part {
                    case .text(let s): Text(s).foregroundStyle(.secondary)
                    case .branch(let name): BranchPill(name: name, host: host)
                    }
                }
            }
            .font(.callout)
            if !pr.labels.isEmpty || !reviewers.isEmpty || pr.additions + pr.deletions > 0 {
                HStack(alignment: .center, spacing: 10) {
                    if !pr.labels.isEmpty {
                        FlowLayout(spacing: 4) { ForEach(pr.labels, id: \.name) { LabelCapsule(label: $0) } }
                            .layoutPriority(1)
                    }
                    if !reviewers.isEmpty { ReviewerStack(reviewers: reviewers, art: art) }
                    Spacer(minLength: 0)
                    Diffstat(additions: pr.additions, deletions: pr.deletions, art: art)
                }
            }
        }
    }

    // MARK: Merge box

    /// ADR-087's status block, drawn as the service's merge box: the same `PullRequestStatus` lines in
    /// the same order, each on a disc of its tone, with the merge buttons in the box's footer.
    private func mergeBox(_ pr: PullRequest, _ status: PullRequestStatus) -> some View {
        let p = art.palette
        return VStack(spacing: 0) {
            ForEach(Array(status.lines.enumerated()), id: \.element.id) { i, line in
                if i > 0 { Rectangle().fill(p.border).frame(height: 1) }
                mergeRow(pr, line)
            }
            if pr.state == .open {
                Rectangle().fill(p.border).frame(height: 1)
                mergeFooter(pr, status)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(p.border))
        .padding(.horizontal, 12)
    }

    /// The checks a line stands for, when it stands for any: what failed, what is running, or on an
    /// all-green line, everything.
    private func checks(for line: PullRequestStatus.Line, in pr: PullRequest) -> [PullRequest.Check] {
        switch (line.id, line.tone) {
        case ("checks", .blocking): pr.checks.filter { $0.status == .failure }
        case ("checks", _): pr.checks
        case ("pending", _): pr.checks.filter { $0.status == .pending }
        default: []
        }
    }

    private func mergeRow(_ pr: PullRequest, _ line: PullRequestStatus.Line) -> some View {
        let listed = checks(for: line, in: pr)
        let expanded = !listed.isEmpty && ((line.tone == .blocking) != toggledLines.contains(line.id))
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(art.discFill(for: line, state: pr.state))
                    ServiceIcon(art.glyph(for: line, state: pr.state), size: 13).foregroundStyle(.white)
                }
                .frame(width: 26, height: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(line.text).font(.callout.weight(.semibold))
                    if let detail = line.detail, !expanded {
                        Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                Spacer(minLength: 4)
                if !listed.isEmpty {
                    Button(expanded ? "Hide" : "Show") {
                        if toggledLines.contains(line.id) { toggledLines.remove(line.id) } else { toggledLines.insert(line.id) }
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(art.palette.link)
                }
            }
            .padding(.horizontal, 11).padding(.vertical, 9)
            if expanded {
                VStack(spacing: 0) {
                    ForEach(listed.prefix(6)) { CheckRow(check: $0, art: art, inset: 47) }
                    if listed.count > 6 {
                        Button("\(listed.count - 6) more in \(host.title(.checks))") { pane = .checks }
                            .buttonStyle(.plain).font(.caption).foregroundStyle(art.palette.link)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, 47).padding(.vertical, 4)
                    }
                }
                .padding(.vertical, 3)
                .background(art.palette.muted)
                .overlay(alignment: .top) { Rectangle().fill(art.palette.border).frame(height: 1) }
            }
        }
    }

    private func mergeFooter(_ pr: PullRequest, _ status: PullRequestStatus) -> some View {
        HStack(spacing: 7) {
            if pr.isDraft {
                Button(host.readyTitle) {
                    confirm = PendingAction(title: host.readyTitle, message: "Mark \(host.reference(ref.number)) ready for review?") {
                        await prs.perform(ref) { try await $0.markReady(ref) }
                    }
                }
            } else {
                MergeSplitButton(host: host, method: prs.mergeMethod, enabled: status.canMerge) { method in
                    confirmMerge(pr, method)
                }
                .help(status.mergeBlockedReason ?? "Merge into \(pr.baseRefName)")
                if pr.autoMergeEnabled {
                    Button(host.disableAutoMergeTitle) { Task { await prs.perform(ref) { try await $0.disableAutoMerge(ref) } } }
                } else {
                    Button(host.autoMergeTitle) {
                        confirm = PendingAction(title: host.autoMergeTitle, message: "Merge \(host.reference(ref.number)) automatically when checks pass?") {
                            await prs.perform(ref) { try await $0.merge(ref, method: prs.mergeMethod, auto: true) }
                        }
                    }
                    .disabled(!status.canMerge)
                    .help(status.mergeBlockedReason ?? "Merge once the checks pass")
                }
            }
            Spacer(minLength: 0)
        }
        .controlSize(.small)
        .padding(.horizontal, 11).padding(.vertical, 9)
        .background(art.palette.muted)
    }

    private func confirmMerge(_ pr: PullRequest, _ method: GitHubService.MergeMethod) {
        confirm = PendingAction(title: host.mergeTitle(method),
                                message: "Merge \(host.reference(ref.number)) into \(pr.baseRefName) with \(host.mergeMethodTitle(method).lowercased())?") {
            await prs.perform(ref) { try await $0.merge(ref, method: method, auto: false) }
        }
    }

    // MARK: Session actions

    /// What Claude can do about this PR, in Clinic's accent and outside the merge box (ADR-116): the
    /// one suggested prompt from `PullRequestStatus`, and the full menu beside it with nothing disabled.
    private func sessionActions(_ pr: PullRequest, _ status: PullRequestStatus) -> some View {
        let name = "\(host.abbreviation) \(host.reference(ref.number)) (\(ref.url))"
        return HStack(spacing: 7) {
            if let action = status.action {
                Button { send(action.prompt) } label: {
                    Label(action.title, systemImage: action.symbol).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .help(tab.state == .idle ? "Types the prompt into this session" : "The session must be idle at its prompt")
            }
            Menu {
                Button("Address the CI failures") { send("The CI checks on \(name) are failing. Investigate the failures and fix them.") }
                Button("Resolve the conflicts") { send("\(name) has merge conflicts with \(pr.baseRefName). Rebase or merge \(pr.baseRefName) and resolve them.") }
                Button("Address the review comments") { send("Address the unresolved review comments on \(name).") }
                Button("Review this \(host.abbreviation)") { send("Review \(name) and summarize any problems.") }
            } label: {
                Label(status.action == nil ? "Send to session" : "Send", systemImage: "text.append")
            }
            .menuStyle(.button)
            .buttonStyle(.bordered)
            .fixedSize()
            .help(tab.state == .idle ? "Types a prompt into the session" : "The session must be idle at its prompt")
            if status.action == nil { Spacer(minLength: 0) }
        }
        .controlSize(.large)
        .disabled(tab.state != .idle)
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    private func send(_ prompt: String) {
        if tabs.sendSlashCommand(prompt, to: tab) { tabs.select(tab) }
    }

    // MARK: Panes

    /// The service's tab idiom: glyph, name and counter, with its selected-tab underline. Falls back to
    /// names only, then glyphs only, as the panel narrows (ADR-104's rule for the panel's own tabs).
    private func panePicker(_ pr: PullRequest) -> some View {
        HStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                paneTabs(pr, glyphs: true, titles: true)
                paneTabs(pr, glyphs: false, titles: true)
                paneTabs(pr, glyphs: true, titles: false)
            }
            Spacer(minLength: 6)
            if pane == .files, let d = prs.diffs[ref.id], !d.files.isEmpty {
                Diffstat(additions: d.files.reduce(0) { $0 + $1.additions },
                         deletions: d.files.reduce(0) { $0 + $1.deletions }, art: art, blocks: false)
            }
        }
        .padding(.horizontal, 8)
        .overlay(alignment: .bottom) { Rectangle().fill(art.palette.border).frame(height: 1) }
    }

    private func paneTabs(_ pr: PullRequest, glyphs: Bool, titles: Bool) -> some View {
        HStack(spacing: 2) {
            ForEach(CodeHost.Pane.allCases, id: \.self) { p in
                let selected = pane == p
                Button { pane = p } label: {
                    HStack(spacing: 6) {
                        if glyphs { ServiceIcon(art.paneGlyph(p), size: 13) }
                        if titles { Text(host.title(p)) }
                        counter(p, pr)
                    }
                    .font(.callout.weight(selected ? .semibold : .regular))
                    .foregroundStyle(selected ? .primary : .secondary)
                    .fixedSize()
                    .padding(.horizontal, 8).padding(.top, 8).padding(.bottom, 9)
                    .overlay(alignment: .bottom) {
                        if selected { Capsule().fill(art.palette.tabIndicator).frame(height: 2).padding(.horizontal, 4) }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(host.title(p))
            }
        }
    }

    /// Checks counts what is failing when anything is, then what is running, and only then the total:
    /// the number worth reading, in the colour of the worst check (ADR-091, ADR-116).
    @ViewBuilder
    private func counter(_ p: CodeHost.Pane, _ pr: PullRequest) -> some View {
        switch p {
        case .conversation where !pr.comments.isEmpty:
            ServiceCounter(count: pr.comments.count, fill: art.palette.counter)
        case .checks where !pr.checks.isEmpty:
            let failing = pr.checks.filter { $0.status == .failure }.count
            let pending = pr.checks.filter { $0.status == .pending }.count
            if failing > 0 {
                ServiceCounter(count: failing, fill: art.palette.closed, ink: .white)
            } else if pending > 0 {
                ServiceCounter(count: pending, fill: art.palette.attention, ink: .white)
            } else {
                ServiceCounter(count: pr.checks.count, fill: art.palette.counter)
            }
        case .files where pr.changedFiles > 0:
            ServiceCounter(count: pr.changedFiles, fill: art.palette.counter)
        default:
            EmptyView()
        }
    }

    // MARK: Conversation

    /// The service's timeline: comments in boxes with a header strip, reviews as events on the rail.
    private func conversation(_ pr: PullRequest) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                TimelineEntry(art: art, isFirst: true, isLast: pr.comments.isEmpty) {
                    Avatar(url: pr.author.avatarURL, login: pr.author.login, size: 24)
                } content: {
                    CommentBox(art: art, login: pr.author.login, verb: "opened", date: pr.createdAt,
                               roles: ["Author"], isAuthor: true, path: nil) {
                        if let html = pr.bodyHTML, !html.isEmpty {
                            GitHubHTMLView(html: html)
                        } else if pr.body.isEmpty {
                            Text("No description provided.").font(.callout).foregroundStyle(.secondary)
                        } else {
                            MarkdownText(pr.body)
                        }
                    }
                }
                ForEach(pr.comments) { c in
                    entry(c, in: pr, isLast: c.id == pr.comments.last?.id)
                }
            }
            .padding(.vertical, 12)
        }
    }

    @ViewBuilder
    private func entry(_ c: PullRequest.Comment, in pr: PullRequest, isLast: Bool) -> some View {
        let hasBody = !(c.bodyHTML ?? "").isEmpty || !c.body.isEmpty
        if c.kind == .review {
            TimelineEntry(art: art, isFirst: false, isLast: isLast && !hasBody) {
                ReviewDisc(state: c.reviewState, art: art)
            } content: {
                reviewSentence(c).padding(.top, 4)
            }
            if hasBody {
                TimelineEntry(art: art, isFirst: false, isLast: isLast) {
                    Avatar(url: c.author.avatarURL, login: c.author.login, size: 24)
                } content: {
                    CommentBox(art: art, login: c.author.login, verb: "left a review", date: c.createdAt,
                               roles: roles(c.author, pr), isAuthor: false, path: nil) { body(c) }
                }
            }
        } else {
            TimelineEntry(art: art, isFirst: false, isLast: isLast) {
                Avatar(url: c.author.avatarURL, login: c.author.login, size: 24)
            } content: {
                CommentBox(art: art, login: c.author.login, verb: "commented", date: c.createdAt,
                           roles: roles(c.author, pr), isAuthor: false,
                           path: c.path.map { $0 + (c.line.map { ":\($0)" } ?? "") }) { body(c) }
            }
        }
    }

    @ViewBuilder
    private func body(_ c: PullRequest.Comment) -> some View {
        if let html = c.bodyHTML, !html.isEmpty {
            GitHubHTMLView(html: html)
        } else {
            MarkdownText(c.body)
        }
    }

    private func roles(_ author: PullRequest.Author, _ pr: PullRequest) -> [String] {
        author.isBot ? ["bot"] : author.login == pr.author.login ? ["Author"] : []
    }

    private func reviewSentence(_ c: PullRequest.Comment) -> some View {
        let verb = switch c.reviewState {
        case "APPROVED": "approved these changes"
        case "CHANGES_REQUESTED": "requested changes"
        case "DISMISSED": "had a review dismissed"
        default: "reviewed"
        }
        return (Text(c.author.login).fontWeight(.semibold).foregroundStyle(.primary)
                + Text(" \(verb) · ") + Text(c.createdAt, format: .relative(presentation: .named)))
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    // MARK: Checks

    private func checks(_ pr: PullRequest) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                ChecksFreshness(pr: pr).padding(.horizontal, 12)
                ForEach(PRChecksGroup.group(pr.checks)) { group in
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 6) {
                            Text(group.name).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                            Text(group.summary).font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 12).padding(.bottom, 4)
                        ForEach(group.checks) { CheckRow(check: $0, art: art, inset: 12) }
                    }
                }
                if pr.checks.isEmpty {
                    ContentUnavailableView("No checks reported", systemImage: "checkmark.circle",
                                           description: Text("Nothing ran on this \(host.noun.lowercased())."))
                        .padding(.top, 24)
                }
            }
            .padding(.vertical, 10)
        }
    }
}

// MARK: - Pieces

/// The bell that turns *Watching* on (ADR-128): filled and in Clinic's accent while it is on, hollow
/// and secondary while it is off. It says what it will do, in the tense it will do it in — a run in
/// flight promises news about *this* run, a settled one promises news about the next.
private struct WatchToggle: View {
    let watching: Bool
    let verdict: PullRequestWatch.Verdict?
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            Image(systemName: watching ? "bell.fill" : "bell")
                .frame(width: 16, height: 16)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(watching ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
        .help(helpText)
        .accessibilityLabel(watching ? "Stop watching checks" : "Watch checks")
    }

    private var helpText: String {
        guard watching else {
            return verdict == nil ? "Watch · tell me how these checks end" : "Watch · tell me how the next checks end"
        }
        return verdict == nil ? "Watching · you will be told how these checks end"
                              : "Watching · you will be told how the next checks end"
    }
}

/// ⟳, spinning while a read is in flight, with what it last read in its tooltip. The panel refreshes
/// itself (ADR-127); this says so, and says when, so pressing it is a choice rather than a reflex.
private struct RefreshButton: View {
    let loading: Bool
    let fetchedAt: Date?
    let refresh: () -> Void

    var body: some View {
        Button(action: refresh) {
            ZStack {
                Image(systemName: "arrow.clockwise").opacity(loading ? 0 : 1)
                if loading { ProgressView().controlSize(.small).scaleEffect(0.7) }
            }
            .frame(width: 16, height: 16)
        }
        .buttonStyle(.borderless)
        .disabled(loading)
        .help(fetchedAt.map { "Refresh · updated \(PRFreshness.phrase(for: $0))" } ?? "Refresh")
    }
}

/// How long ago a pull request was read, in words. Its own type because both the ⟳ tooltip and the
/// Checks tab print it, and "just now" has to mean the same thing in both.
enum PRFreshness {
    static func phrase(for date: Date, now: Date = Date()) -> String {
        now.timeIntervalSince(date) < 10 ? "just now" : date.formatted(.relative(presentation: .named))
    }
}

/// What the Checks tab says about its own freshness (ADR-127). A rollup is a photograph of something
/// still happening, so it names its own age — and while a check is in flight, says that it is watching
/// rather than leaving the reader to press ⟳ to find out.
private struct ChecksFreshness: View {
    let pr: PullRequest

    var body: some View {
        // Five seconds is well inside the fastest cadence, so the age on screen is never a lie by more
        // than a tick. Nothing else in the pane redraws: `Text` is all this builds.
        TimelineView(.periodic(from: .now, by: 5)) { context in
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                Text(phrase(at: context.date))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
        }
    }

    private func phrase(at now: Date) -> String {
        let age = "Updated " + PRFreshness.phrase(for: pr.fetchedAt, now: now)
        // `NSApp.isActive`, not `true`: with Clinic in the background the store is on its slow cadence
        // (ADR-127), and a line claiming otherwise would be a lie the reader could see in a screenshot.
        guard PullRequestRefresh.interval(for: pr, isFront: true, appActive: NSApp.isActive) == PullRequestRefresh.watching
        else { return age }
        let every = Int(PullRequestRefresh.watching.seconds)
        return "Rechecking every \(every)s · " + age.lowercased()
    }
}

/// The service's merge button: its merge colour, white text, and a menu segment to pick the method for
/// this merge (as on github.com) while the Settings method stays the default. Drawn by hand because
/// macOS ignores `.borderedProminent` and `.tint` on a `Menu`.
private struct MergeSplitButton: View {
    let host: CodeHost
    let method: GitHubService.MergeMethod
    let enabled: Bool
    let merge: (GitHubService.MergeMethod) -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button { merge(method) } label: {
                Text(host.mergeTitle(method)).padding(.leading, 10).padding(.trailing, 9).frame(maxHeight: .infinity)
            }
            Rectangle().fill(.black.opacity(0.2)).frame(width: 1)
            Menu {
                ForEach(GitHubService.MergeMethod.allCases, id: \.self) { m in
                    Button(host.mergeMethodTitle(m)) { merge(m) }
                }
            } label: {
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).frame(width: 22).frame(maxHeight: .infinity)
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
        }
        .buttonStyle(.plain)
        .font(.callout.weight(.semibold))
        .foregroundStyle(.white)
        .frame(height: 22)
        .background(host.art.palette.mergeButton, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .fixedSize()
        .opacity(enabled ? 1 : 0.5)
        .disabled(!enabled)
    }
}

/// The service's counter pill, on a tab.
private struct ServiceCounter: View {
    let count: Int
    let fill: Color
    var ink: Color = .primary

    var body: some View {
        Text("\(count)")
            .font(.caption.monospacedDigit().weight(.medium))
            .foregroundStyle(ink)
            .padding(.horizontal, 6).padding(.vertical, 0.5)
            .frame(minWidth: 18)
            .background(fill, in: Capsule())
    }
}

/// GitHub's diffstat: the counts, then five squares split between them (ADR-116).
private struct Diffstat: View {
    let additions: Int
    let deletions: Int
    let art: ServiceArt
    var blocks = true

    var body: some View {
        let split = PullRequest.diffstatBlocks(additions: additions, deletions: deletions)
        HStack(spacing: 5) {
            Text("+\(additions)").foregroundStyle(art.palette.openInk)
            Text("−\(deletions)").foregroundStyle(art.palette.closedInk)
            if blocks && additions + deletions > 0 {
                HStack(spacing: 1) {
                    ForEach(0..<5, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(i < split.added ? art.palette.open : art.palette.closed)
                            .frame(width: 7, height: 7)
                    }
                }
            }
        }
        .font(.system(.caption, design: .monospaced))
        .fixedSize()
        .help("\(additions) additions, \(deletions) deletions")
    }
}

/// Reviewer avatars overlapping, each with a badge for the verdict that stands.
private struct ReviewerStack: View {
    let reviewers: [PullRequest.Reviewer]
    let art: ServiceArt

    var body: some View {
        HStack(spacing: 5) {
            ForEach(reviewers.prefix(5)) { r in
                Avatar(url: r.avatarURL, login: r.login, size: 18)
                    .overlay(alignment: .bottomTrailing) { badge(r.verdict).offset(x: 3, y: 3) }
                    .help("\(r.login) \(phrase(r.verdict))")
            }
            if reviewers.count > 5 {
                Text("+\(reviewers.count - 5)").font(.caption2).foregroundStyle(.secondary).padding(.leading, 2)
            }
        }
        .padding(.trailing, 3)
    }

    private func badge(_ v: PullRequest.Reviewer.Verdict) -> some View {
        let (glyph, fill): (String, Color) = switch v {
        case .approved: (art.check, art.palette.open)
        case .changesRequested: (art.changesRequested, art.palette.closed)
        case .commented: (art.comment, art.palette.draft)
        case .requested: (art.pending, art.palette.attention)
        }
        return ServiceIcon(glyph, size: 6.5)
            .foregroundStyle(.white)
            .frame(width: 11, height: 11)
            .background(fill, in: Circle())
            .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1).padding(-1))
    }

    private func phrase(_ v: PullRequest.Reviewer.Verdict) -> String {
        switch v {
        case .approved: "approved"
        case .changesRequested: "requested changes"
        case .commented: "commented"
        case .requested: "is asked to review"
        }
    }
}

/// One row of the conversation: a leading column on the rail, then the content.
///
/// The rail is drawn as the row's background, so it is exactly as tall as the row and consecutive
/// rows join into one line without either drawing it twice (ADR-091).
private struct TimelineEntry<Leading: View, Content: View>: View {
    let art: ServiceArt
    let isFirst: Bool
    let isLast: Bool
    @ViewBuilder var leading: Leading
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            leading.frame(width: 24)
            VStack(alignment: .leading, spacing: 0) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.bottom, isLast ? 0 : 14)
        .background(alignment: .topLeading) {
            Rectangle()
                .fill(art.palette.border)
                .frame(width: 2)
                .padding(.top, isFirst ? 12 : 0)
                .frame(maxHeight: isLast ? 12 : .infinity, alignment: .top)
                .padding(.leading, 11)
        }
        .padding(.horizontal, 12)
    }
}

/// A review's verdict as a disc on the rail.
private struct ReviewDisc: View {
    let state: String?
    let art: ServiceArt

    var body: some View {
        let (glyph, fill): (String, Color) = switch state {
        case "APPROVED": (art.check, art.palette.open)
        case "CHANGES_REQUESTED": (art.changesRequested, art.palette.closed)
        case "DISMISSED": (art.cross, art.palette.draft)
        default: (art.eye, art.palette.draft)
        }
        ServiceIcon(glyph, size: 12)
            .foregroundStyle(.white)
            .frame(width: 24, height: 24)
            .background(fill, in: Circle())
            .background(Circle().fill(Color(nsColor: .windowBackgroundColor)).padding(-3))
    }
}

/// A comment in the service's box: a header strip with the author, what they did and when, role pills,
/// an optional file strip for a review comment, then the body.
private struct CommentBox<Content: View>: View {
    let art: ServiceArt
    let login: String
    let verb: String
    let date: Date
    let roles: [String]
    /// The PR author's opening post is outlined in the link colour, as on github.com.
    let isAuthor: Bool
    let path: String?
    @ViewBuilder var content: Content

    var body: some View {
        let p = art.palette
        let edge = isAuthor ? p.link.opacity(0.45) : p.border
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                (Text(login).fontWeight(.semibold).foregroundStyle(.primary)
                 + Text(" \(verb) ") + Text(date, format: .relative(presentation: .named)))
                    .lineLimit(1)
                Spacer(minLength: 4)
                ForEach(roles, id: \.self) { role in
                    Text(role)
                        .font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 0.5)
                        .overlay(Capsule().strokeBorder(p.border))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background(isAuthor ? p.linkWash.opacity(0.6) : p.muted)
            Rectangle().fill(edge).frame(height: 1)
            if let path {
                HStack(spacing: 5) {
                    ServiceIcon(art.files, size: 11)
                    Text(path).lineLimit(1).truncationMode(.head)
                }
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 9).padding(.vertical, 5)
                Rectangle().fill(p.border).frame(height: 1)
            }
            VStack(alignment: .leading, spacing: 0) { content }
                .padding(.horizontal, 9).padding(.vertical, 8)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(edge))
    }
}

/// Service avatar, falling back to the initial while it loads or when there is no URL.
private struct Avatar: View {
    let url: URL?
    let login: String
    var size: CGFloat = 22

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
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Color.primary.opacity(0.12)))
    }

    private var placeholder: some View {
        ZStack {
            Color.primary.opacity(0.09)
            Text(login.prefix(1).uppercased()).font(.system(size: size * 0.45, weight: .semibold)).foregroundStyle(.secondary)
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
            let key = c.workflow.flatMap { $0.isEmpty ? nil : $0 } ?? "Other"
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

/// One check as the service lists it: its status, the mark of the CI service that ran it, its name,
/// and how long it took (ADR-116). Clicking opens the run.
private struct CheckRow: View {
    let check: PullRequest.Check
    let art: ServiceArt
    /// Leading inset, so rows under a merge-box line align with its text.
    var inset: CGFloat = 12
    @State private var hovering = false

    var body: some View {
        let provider = CheckProvider(check)
        HStack(spacing: 7) {
            ServiceIcon(art.checkGlyph(check.status), size: 13).foregroundStyle(art.checkInk(check.status))
            Group {
                if let glyph = ServiceArt.providerGlyph(provider) {
                    ServiceIcon(glyph, size: 12)
                } else {
                    Image(systemName: "circle.dotted").font(.system(size: 10))
                }
            }
            .foregroundStyle(.secondary)
            .frame(width: 13)
            .help(provider.name)
            Text(check.name).font(.subheadline).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            Text(detail).font(.caption2.monospacedDigit()).foregroundStyle(.tertiary).lineLimit(1)
            if check.detailsURL != nil {
                ServiceIcon(art.external, size: 11).foregroundStyle(.secondary).opacity(hovering ? 1 : 0)
            }
        }
        .padding(.leading, inset).padding(.trailing, 12).padding(.vertical, 4)
        .background(hovering && check.detailsURL != nil ? Color.primary.opacity(0.05) : .clear)
        .contentShape(Rectangle())
        .onTapGesture { if let url = check.detailsURL { NSWorkspace.shared.open(url) } }
        .onHover { hovering = $0 }
        .help(check.detailsURL.map { "Open the run: \($0.absoluteString)" } ?? check.name)
    }

    /// "failed · 2m 14s", "6m 02s", "running", as the status and a finished run's duration allow.
    private var detail: String {
        let time: String? = {
            guard let start = check.startedAt, let end = check.completedAt else { return nil }
            let seconds = Int(end.timeIntervalSince(start))
            guard seconds > 0 else { return nil }
            return seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(String(format: "%02d", seconds % 60))s"
        }()
        switch check.status {
        case .failure: return ["failed", time].compactMap { $0 }.joined(separator: " · ")
        case .pending: return "running"
        case .skipped: return "skipped"
        case .cancelled: return "cancelled"
        default: return time ?? ""
        }
    }
}

/// What to say when `gh` cannot answer. Splitting "not installed" from "not logged in" matters:
/// a GUI-launched Clinic searches a `PATH` the user's terminal does not have, so a perfectly
/// authenticated `gh` can still be invisible — and telling that user to log in is a dead end (ADR-086).
struct GitHubUnavailableView: View {
    let availability: GitHubService.Availability
    /// What Clinic was trying to read: "pull requests" or "issues" (ADR-113).
    var subject = "pull requests"
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
                        Text("Clinic runs `gh` to read \(subject), but it isn't on the PATH this app was launched with. Install it with `brew install gh`, or make sure your login shell exports its location.")
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

/// Footer chip for one PR (ADR-053): the service's state glyph with its attention dot, and the
/// service's reference — `#7`, `!482` (ADR-116).
struct PRChip: View {
    @Environment(PRStore.self) private var prs
    let ref: PullRequestRef
    let active: Bool
    /// The PR's panel tab exists but another pane is in front.
    var open = false
    let onTap: () -> Void

    var body: some View {
        let mark = prs.mark(for: ref)
        let host = ref.codeHost
        Button(action: onTap) {
            HStack(spacing: 5) {
                PRGlyph(host: host, mark: mark, size: PRStyle.glyphSize.chip)
                Text(host.reference(ref.number)).monospacedDigit()
            }
            .font(.callout)
            .lineLimit(1)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(active ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(open && !active ? Color.accentColor.opacity(0.35) : .clear))
            .foregroundStyle(active ? Color.accentColor : .primary)
        }
        .buttonStyle(.plain)
        .help(mark?.summary ?? "\(host.noun) \(host.reference(ref.number))")
        .contextMenu {
            Button(host.openTitle) { NSWorkspace.shared.open(ref.url) }
            Button("Copy URL") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(ref.url.absoluteString, forType: .string) }
            Button("Refresh") { Task { await prs.refresh(ref) } }
        }
        .task { prs.ensureLoaded([ref]) }
    }
}

/// Sidebar glyph for a session's PRs: the aggregate mark, in the service's glyph (ADR-116).
struct PRMarkView: View {
    @Environment(PRStore.self) private var prs
    let refs: [PullRequestRef]
    var body: some View {
        if let host = refs.first?.codeHost {
            let mark = prs.aggregateMark(for: refs)
            PRGlyph(host: host, mark: mark, size: PRStyle.glyphSize.sidebar)
                .help(mark?.summary ?? host.noun)
                .task { if mark == nil { prs.ensureLoaded(refs) } }
        }
    }
}

/// The glyph on a PR's panel tab: its state, with the attention dot (ADR-116).
struct PRTabGlyph: View {
    @Environment(PRStore.self) private var prs
    let ref: PullRequestRef
    let size: CGFloat

    var body: some View {
        PRGlyph(host: ref.codeHost, mark: prs.mark(for: ref), size: size)
    }
}

enum PRStyle {
    /// Point sizes for the PR glyph, per place it is drawn.
    ///
    /// Still explicit rather than inherited from a text style (ADR-089), but no longer compensating for
    /// `arrow.trianglehead.pull`'s narrow shape: the service glyphs of ADR-116 are drawn on a 16 pt grid
    /// and fill it, so each size only has to sit a point or so over its neighbouring text.
    enum glyphSize {
        /// Footer chip, beside a 12 pt `.callout` label.
        static let chip: CGFloat = 14
        /// Sidebar row, beside 10 pt secondary text.
        static let sidebar: CGFloat = 12
        /// Panel tab strip, beside the other pane glyphs at 11 pt.
        static let tab: CGFloat = 12
        /// The compact panel tab strip, where the glyph is the whole chip (ADR-104).
        static let tabCompact: CGFloat = 14
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
