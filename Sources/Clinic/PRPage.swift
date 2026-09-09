import SwiftUI
import ClinicCore

/// Right-column pull request page (ADR-053, redesigned by ADR-087).
///
/// One scrolling column rather than four tabs. It opens with `PullRequestStatus` — the plain-language
/// answer to "what is blocking this" — then the action that fixes it, then the reference material in
/// collapsible sections. The old layout made you click a tab to learn anything and spelled the verdict
/// out as raw GraphQL enums at the bottom of the first one.
struct PRPage: View {
    @Environment(PRStore.self) private var prs
    @Environment(TabStore.self) private var tabs
    let tab: Tab
    let ref: PullRequestRef
    @State private var expanded: Set<Section> = []
    @State private var didSeedExpansion = false
    @State private var confirm: PendingAction?

    enum Section: String, CaseIterable, Identifiable {
        case description, checks, conversation, files
        var id: String { rawValue }
        var title: String {
            switch self {
            case .description: "Description"
            case .checks: "Checks"
            case .conversation: "Conversation"
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
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    statusBlock(pr, status)
                    Divider()
                    sections(pr, status)
                }
            }
            .onAppear { seedExpansion(status) }
            .onChange(of: status.lines.map(\.id)) { seedExpansion(status) }
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

    /// Description is always open; a section the status block calls out as blocking opens with it, so a
    /// failing build is one scroll away rather than one click.
    private func seedExpansion(_ status: PullRequestStatus) {
        guard !didSeedExpansion else { return }
        didSeedExpansion = true
        var open: Set<Section> = [.description]
        for line in status.lines where line.tone == .blocking {
            switch line.id {
            case "checks": open.insert(.checks)
            case "review", "comments": open.insert(.conversation)
            default: break
            }
        }
        expanded = open
    }

    // MARK: Header

    private var header: some View {
        let pr = prs.pullRequest(for: ref)
        let mark = prs.mark(for: ref)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let mark { Image(systemName: mark.symbolName).foregroundStyle(PRStyle.color(mark)) }
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
                    Text("\(pr.headRefName) → \(pr.baseRefName)").font(.system(.caption, design: .monospaced)).lineLimit(1).truncationMode(.head)
                }
                Spacer(minLength: 0)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(.bar)
    }

    // MARK: Status + actions

    private func statusBlock(_ pr: PullRequest, _ status: PullRequestStatus) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(status.lines) { line in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: line.symbol)
                            .foregroundStyle(PRStyle.tint(line.tone))
                            .font(.caption)
                            .frame(width: 14)
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
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func actions(_ pr: PullRequest, _ status: PullRequestStatus) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if pr.state == .open {
                if let action = status.action {
                    Button {
                        send(action.prompt)
                    } label: {
                        Label(action.title, systemImage: action.symbol).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(tab.state != .idle)
                    .help(tab.state == .idle ? "Types the prompt into this session" : "The session must be idle at its prompt")
                }
                HStack(spacing: 8) {
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
                        // Every prompt stays available here, suggestion or not — the headline button is a
                        // shortcut for the likely one, not a restriction on what you may ask.
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

    // MARK: Sections

    @ViewBuilder
    private func sections(_ pr: PullRequest, _ status: PullRequestStatus) -> some View {
        section(.description, count: nil) {
            if pr.body.isEmpty {
                Text("No description.").foregroundStyle(.secondary)
            } else {
                MarkdownText(pr.body)
            }
        }
        section(.checks, count: pr.checks.count) {
            if pr.checks.isEmpty {
                Text("No checks reported.").foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(pr.checks) { c in checkRow(c) }
                }
            }
        }
        section(.conversation, count: pr.comments.count) {
            if pr.comments.isEmpty {
                Text("No comments or reviews yet.").foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(pr.comments) { c in commentCard(c) }
                }
            }
        }
        section(.files, count: pr.changedFiles, trailing: "+\(pr.additions) −\(pr.deletions)") {
            if let diff = prs.diffs[ref.id] {
                LazyVStack(spacing: 12) {
                    ForEach(diff.files) { f in DiffView(file: f).frame(minHeight: 60, maxHeight: 600) }
                }
            } else {
                // `gh pr diff` is the one section that costs a second round trip, so it is fetched when
                // the section is first opened rather than with the rest of the page.
                ProgressView().frame(maxWidth: .infinity).task { await prs.loadDiff(ref) }
            }
        }
    }

    private func section<Content: View>(_ id: Section, count: Int?, trailing: String? = nil,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            Button {
                if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded.contains(id) ? 90 : 0))
                    Text(id.title).font(.subheadline.weight(.medium))
                    if let count { Text("\(count)").font(.caption).monospacedDigit().foregroundStyle(.secondary) }
                    Spacer(minLength: 0)
                    if let trailing { Text(trailing).font(.caption).monospacedDigit().foregroundStyle(.secondary) }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded.contains(id) {
                content()
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
        }
    }

    private func checkRow(_ c: PullRequest.Check) -> some View {
        HStack(spacing: 8) {
            Image(systemName: PRStyle.checkSymbol(c.status)).foregroundStyle(PRStyle.checkColor(c.status)).font(.caption)
            VStack(alignment: .leading, spacing: 1) {
                Text(c.name).font(.subheadline).lineLimit(1)
                if let w = c.workflow { Text(w).font(.caption2).foregroundStyle(.tertiary) }
            }
            Spacer(minLength: 0)
            if let url = c.detailsURL {
                Button { NSWorkspace.shared.open(url) } label: { Image(systemName: "arrow.up.right.square") }
                    .buttonStyle(.borderless).help("Open the run on GitHub")
            }
        }
        .padding(.vertical, 3)
    }

    private func commentCard(_ c: PullRequest.Comment) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: c.kind == .comment ? "bubble.left" : "eye").foregroundStyle(.secondary)
                Text(c.author.login).font(.caption.weight(.semibold))
                if let s = c.reviewState, !s.isEmpty {
                    Text(s.lowercased().replacingOccurrences(of: "_", with: " "))
                        .font(.caption2).padding(.horizontal, 5).padding(.vertical, 1).background(.quaternary, in: Capsule())
                }
                if let p = c.path {
                    Text(p + (c.line.map { ":\($0)" } ?? ""))
                        .font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Text(c.createdAt, format: .relative(presentation: .named)).font(.caption2).foregroundStyle(.tertiary)
            }
            if !c.body.isEmpty { MarkdownText(c.body) }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
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
            Image(systemName: mark.symbolName).font(.caption).foregroundStyle(PRStyle.color(mark)).help(mark.summary)
        } else if !refs.isEmpty {
            Image(systemName: PullRequestMark.symbol).font(.caption).foregroundStyle(.tertiary).task { prs.ensureLoaded(refs) }
        }
    }
}

enum PRStyle {
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
