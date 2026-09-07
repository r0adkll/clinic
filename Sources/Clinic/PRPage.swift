import SwiftUI
import ClinicCore

/// Right-column pull request page (ADR-053).
struct PRPage: View {
    @Environment(PRStore.self) private var prs
    @Environment(TabStore.self) private var tabs
    let tab: Tab
    let ref: PullRequestRef
    @State private var section: Section = .overview
    @State private var confirm: PendingAction?

    enum Section: String, CaseIterable, Identifiable { case overview = "Overview", checks = "Checks", timeline = "Timeline", files = "Files"; var id: String { rawValue } }
    struct PendingAction: Identifiable { let id = UUID(); let title: String; let message: String; let run: () async -> Void }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if prs.available == false {
                ContentUnavailableView("GitHub CLI not available", systemImage: "terminal", description: Text("Install `gh` (brew install gh) and run `gh auth login`."))
            } else if let pr = prs.pullRequest(for: ref) {
                Picker("", selection: $section) { ForEach(Section.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().padding(8)
                switch section {
                case .overview: overview(pr)
                case .checks: checks(pr)
                case .timeline: timeline(pr)
                case .files: files
                }
            } else if let error = prs.errors[ref.id] {
                ContentUnavailableView("Could not load PR #" + String(ref.number), systemImage: "exclamationmark.triangle", description: Text(error))
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let error = prs.errors[ref.id], prs.pullRequest(for: ref) != nil { Divider(); Text(error).font(.caption).foregroundStyle(.red).lineLimit(2).padding(6) }
        }
        .task(id: ref.id) { if prs.pullRequest(for: ref) == nil { await prs.refresh(ref) } }
        .alert(confirm?.title ?? "", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } })) {
            Button("Cancel", role: .cancel) { confirm = nil }
            Button(confirm?.title ?? "OK") { if let c = confirm { Task { await c.run() } }; confirm = nil }
        } message: { Text(confirm?.message ?? "") }
    }

    // MARK: Header + actions

    private var header: some View {
        let pr = prs.pullRequest(for: ref)
        let mark = prs.mark(for: ref)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if let mark { Image(systemName: mark.symbolName).foregroundStyle(PRStyle.color(mark)) }
                Text(pr?.title ?? "Pull request #" + String(ref.number)).font(.headline).lineLimit(2)
                Spacer()
                Button { Task { await prs.refresh(ref) } } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless)
                Button { NSWorkspace.shared.open(ref.url) } label: { Image(systemName: "safari") }.buttonStyle(.borderless).help("Open on GitHub")
            }
            HStack(spacing: 8) {
                Text("#" + String(ref.number)).monospacedDigit()
                if let pr {
                    PRStateBadge(pr: pr)
                    Text("\(pr.author.login)").foregroundStyle(.secondary)
                    Text("\(pr.headRefName) → \(pr.baseRefName)").font(.system(.caption, design: .monospaced)).lineLimit(1)
                    Text("+\(pr.additions)").foregroundStyle(.green)
                    Text("−\(pr.deletions)").foregroundStyle(.red)
                }
                Spacer()
            }
            .font(.caption)
            if let pr { actions(pr) }
        }
        .padding(10)
        .background(.bar)
    }

    private func actions(_ pr: PullRequest) -> some View {
        HStack(spacing: 8) {
            if pr.state == .open {
                if pr.isDraft {
                    Button("Ready for review") { confirm = PendingAction(title: "Mark ready", message: "Mark #\(ref.number) ready for review?") { await prs.perform(ref) { try await $0.markReady(ref) } } }
                } else {
                    Button("Merge (\(prs.mergeMethod.rawValue))") { confirm = PendingAction(title: "Merge", message: "Merge #\(ref.number) into \(pr.baseRefName) with \(prs.mergeMethod.rawValue)?") { await prs.perform(ref) { try await $0.merge(ref, method: prs.mergeMethod, auto: false) } } }
                        .disabled(pr.mergeable == "CONFLICTING")
                    if pr.autoMergeEnabled {
                        Button("Disable auto-merge") { Task { await prs.perform(ref) { try await $0.disableAutoMerge(ref) } } }
                    } else {
                        Button("Auto-merge") { confirm = PendingAction(title: "Auto-merge", message: "Merge #\(ref.number) automatically when checks pass?") { await prs.perform(ref) { try await $0.merge(ref, method: prs.mergeMethod, auto: true) } } }
                    }
                }
                Menu("Send to session") {
                    let mark = prs.mark(for: ref)
                    Button("Address the CI failures") { send("The CI checks on PR #\(ref.number) (\(ref.url)) are failing. Investigate the failures and fix them.") }
                        .disabled(mark?.attention != .checksFailing)
                    Button("Resolve the conflicts") { send("PR #\(ref.number) (\(ref.url)) has merge conflicts with \(pr.baseRefName). Rebase or merge \(pr.baseRefName) and resolve them.") }
                        .disabled(mark?.attention != .conflicts)
                    Button("Address the review comments") { send("Address the unresolved review comments on PR #\(ref.number) (\(ref.url)).") }
                        .disabled(mark?.attention != .unansweredComments && mark?.attention != .changesRequested)
                    Button("Review this PR") { send("Review PR #\(ref.number) (\(ref.url)) and summarize any problems.") }
                }
                .disabled(tab.state != .idle)
                .help(tab.state == .idle ? "Types a prompt into the session" : "The session must be idle at its prompt")
            }
            Spacer()
        }
        .controlSize(.small)
    }

    private func send(_ prompt: String) {
        guard tab.state == .idle else { return }
        tab.surface.sendLine(prompt)
        tabs.select(tab)
    }

    // MARK: Sections

    private func overview(_ pr: PullRequest) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if pr.body.isEmpty { Text("No description.").foregroundStyle(.secondary) } else { MarkdownText(pr.body) }
                Divider()
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    GridRow { Text("Mergeable").foregroundStyle(.secondary); Text(pr.mergeable.lowercased()) }
                    GridRow { Text("Merge state").foregroundStyle(.secondary); Text(pr.mergeStateStatus.lowercased()) }
                    GridRow { Text("Review").foregroundStyle(.secondary); Text(pr.reviewDecision.isEmpty ? "—" : pr.reviewDecision.lowercased().replacingOccurrences(of: "_", with: " ")) }
                    GridRow { Text("Updated").foregroundStyle(.secondary); Text(pr.updatedAt, format: .relative(presentation: .named)) }
                }
                .font(.caption)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func checks(_ pr: PullRequest) -> some View {
        List(pr.checks) { c in
            HStack(spacing: 8) {
                Image(systemName: PRStyle.checkSymbol(c.status)).foregroundStyle(PRStyle.checkColor(c.status))
                VStack(alignment: .leading, spacing: 1) {
                    Text(c.name).lineLimit(1)
                    if let w = c.workflow { Text(w).font(.caption2).foregroundStyle(.tertiary) }
                }
                Spacer()
                if let url = c.detailsURL { Button { NSWorkspace.shared.open(url) } label: { Image(systemName: "arrow.up.right.square") }.buttonStyle(.borderless) }
            }
        }
        .listStyle(.inset)
        .overlay { if pr.checks.isEmpty { Text("No checks").foregroundStyle(.tertiary) } }
    }

    private func timeline(_ pr: PullRequest) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(pr.comments) { c in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Image(systemName: c.kind == .comment ? "bubble.left" : "eye").foregroundStyle(.secondary)
                            Text(c.author.login).font(.caption.weight(.semibold))
                            if let s = c.reviewState, !s.isEmpty { Text(s.lowercased().replacingOccurrences(of: "_", with: " ")).font(.caption2).padding(.horizontal, 5).padding(.vertical, 1).background(.quaternary, in: Capsule()) }
                            if let p = c.path { Text(p + (c.line.map { ":\($0)" } ?? "")).font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1) }
                            Spacer()
                            Text(c.createdAt, format: .relative(presentation: .named)).font(.caption2).foregroundStyle(.tertiary)
                        }
                        if !c.body.isEmpty { MarkdownText(c.body) }
                    }
                    .padding(10)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                }
                if pr.comments.isEmpty { Text("No comments or reviews yet.").foregroundStyle(.secondary).padding(12) }
            }
            .padding(10)
        }
    }

    @ViewBuilder
    private var files: some View {
        if let diff = prs.diffs[ref.id] {
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(diff.files) { f in DiffView(file: f).frame(minHeight: 60, maxHeight: 600) }
                }
                .padding(8)
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity).task { await prs.loadDiff(ref) }
        }
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
    let onTap: () -> Void

    var body: some View {
        let mark = prs.mark(for: ref)
        Button(action: onTap) {
            HStack(spacing: 3) {
                Image(systemName: mark?.symbolName ?? "arrow.triangle.pull")
                Text("#" + String(ref.number)).monospacedDigit()
            }
            .foregroundStyle(mark.map(PRStyle.color) ?? .secondary)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(active ? Color.accentColor.opacity(0.15) : Color.clear, in: Capsule())
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
            Image(systemName: "arrow.triangle.pull").font(.caption).foregroundStyle(.tertiary).task { prs.ensureLoaded(refs) }
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
