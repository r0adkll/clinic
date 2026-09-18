import SwiftUI
import ClinicCore

/// Git Pull as a sheet (ADR-165, replacing ADR-065's alert): it opens at once and spins while git
/// runs, then says what arrived — commits and line totals — or why nothing did, in words, with git's
/// own output one disclosure away and the next step offered as a button.
struct PullSheet: View {
    let target: Project
    @Environment(TabStore.self) private var tabs
    @Environment(\.dismiss) private var dismiss
    @State private var phase: Phase = .running
    @State private var branch: String?
    @State private var upstream: String?
    @State private var defaultBranch: String?
    @State private var showOutput = false
    @State private var task: Task<Void, Never>?

    enum Phase {
        case running
        case pulled(GitPullReport)
        case failed(GitPullError)
        case notRepository
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            content
            buttons
        }
        .padding(20)
        .frame(width: 480)
        .task { pull() }
        .onDisappear { task?.cancel() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            ProjectIcon(project: target, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title3.weight(.semibold)).lineLimit(1)
                if let branch {
                    HStack(spacing: 4) {
                        Text(target.name).font(.caption)
                        Text("·").foregroundStyle(.tertiary)
                        Image(systemName: "arrow.triangle.branch").imageScale(.small)
                        Text(branch)
                        if let upstream {
                            Image(systemName: "arrow.left").imageScale(.small).foregroundStyle(.tertiary)
                            Text(upstream)
                        }
                    }
                    .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
        }
    }

    private var title: String {
        switch phase {
        case .running: "Pulling \(target.name)…"
        case .pulled(let r) where r.isUpToDate: "Already up to date"
        case .pulled(let r): r.commitCount == 1 ? "Pulled 1 commit" : "Pulled \(r.commitCount) commits"
        case .failed(let e): Self.headline(e, defaultBranch: defaultBranch)
        case .notRepository: "Not a git repository"
        }
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        switch phase {
        case .running:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Fetching from \(remoteName) and fast-forwarding…").font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        case .pulled(let r) where r.isUpToDate:
            statusLine("checkmark.circle", tint: .accent, "\(r.branch) already has everything on \(r.upstream).")
        case .pulled(let r):
            pulled(r)
        case .failed(let e):
            failed(e)
        case .notRepository:
            statusLine("exclamationmark.triangle.fill", tint: .orange, "\(target.path) is not inside a git repository, so there is nothing to pull.")
        }
    }

    private func statusLine(_ symbol: String, tint: Color, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func pulled(_ r: GitPullReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down.circle").foregroundStyle(Color.accent)
                if let from = r.from, let to = r.to {
                    Text("\(String(from.prefix(7)))…\(String(to.prefix(7)))").font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                Spacer()
                if r.stat.files > 0 {
                    Text(r.stat.files == 1 ? "1 file" : "\(r.stat.files) files").foregroundStyle(.secondary)
                    Text("+\(r.stat.additions)").foregroundStyle(r.stat.additions > 0 ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                    Text("−\(r.stat.deletions)").foregroundStyle(r.stat.deletions > 0 ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                }
            }
            .font(.caption.monospacedDigit())
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(r.commits.enumerated()), id: \.element.sha) { i, c in
                        if i > 0 { Divider() }
                        commitRow(c)
                    }
                    if r.commitCount > r.commits.count {
                        Divider()
                        Text("and \(r.commitCount - r.commits.count) earlier").font(.caption).foregroundStyle(.secondary)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: 240)
            .fixedSize(horizontal: false, vertical: true)
            .background(.quinary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private func commitRow(_ c: GitCommit) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(c.shortSha).font(.caption.monospaced()).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(c.subject).font(.callout).lineLimit(1).truncationMode(.tail)
                (Text(c.author) + Text(" · ") + Text(c.date, format: .relative(presentation: .named)))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .help(c.subject)
    }

    private func failed(_ e: GitPullError) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            statusLine("exclamationmark.triangle.fill", tint: .orange, Self.explanation(e, defaultBranch: defaultBranch))
            let files = Self.files(e.failure)
            if !files.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(files.prefix(6), id: \.self) { Text($0).lineLimit(1).truncationMode(.middle) }
                    if files.count > 6 { Text("and \(files.count - 6) more").foregroundStyle(.secondary) }
                }
                .font(.caption.monospaced())
                .padding(.horizontal, 10).padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quinary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            if !e.output.isEmpty {
                DisclosureGroup("Git output", isExpanded: $showOutput) {
                    ScrollView {
                        Text(e.output).font(.caption.monospaced()).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    }
                    .frame(maxHeight: 160)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(.quinary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .font(.caption)
            }
        }
    }

    // MARK: Buttons

    private var buttons: some View {
        HStack {
            switch phase {
            case .failed(let e):
                Button("Open Shell Here") { tabs.newShell(in: target.path); dismiss() }
                    .help("Open a shell in \(target.name) to sort this out")
                if case .upstreamGone = e.failure, let defaultBranch, defaultBranch != e.branch {
                    Button("Check Out \(defaultBranch)") { checkoutAndPull(defaultBranch) }
                        .help("Switch \(target.name) to \(defaultBranch) and pull that instead")
                }
                Spacer()
                Button("Try Again") { pull() }
                Button("Close") { dismiss() }.keyboardShortcut(.defaultAction)
            case .running:
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                    .help("Stop watching; git carries on in the background")
            default:
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: Running

    private var remoteName: String {
        upstream.flatMap { $0.split(separator: "/", maxSplits: 1).first.map(String.init) } ?? "the remote"
    }

    private func pull() {
        task?.cancel()
        showOutput = false
        phase = .running
        task = Task {
            guard let repo = await GitRepository.discover(from: target.path) else { phase = .notRepository; return }
            if let s = try? await repo.status() { branch = s.branch; upstream = s.upstream }
            let result: Result<GitPullReport, GitPullError>
            do throws(GitPullError) { result = .success(try await repo.pullReport()) } catch { result = .failure(error) }
            guard !Task.isCancelled else { return }
            switch result {
            case .success(let r):
                branch = r.branch; upstream = r.upstream
                phase = .pulled(r)
            case .failure(let e):
                if let b = e.branch { branch = b }
                if let u = e.upstream { upstream = u }
                if case .upstreamGone = e.failure { defaultBranch = await repo.defaultBranch() }
                // Git's words are the only explanation when the reason is unrecognised.
                if case .other = e.failure { showOutput = true }
                phase = .failed(e)
            }
            task = nil
        }
    }

    private func checkoutAndPull(_ branch: String) {
        task?.cancel()
        phase = .running
        self.branch = branch; upstream = nil
        task = Task {
            do { try await GitRepository(root: target.path).checkout(branch) }
            catch {
                let e = error as? GitError
                phase = .failed(GitPullError(failure: .other, branch: branch, output: e?.stderr ?? "\(error)"))
                showOutput = true
                task = nil
                return
            }
            pull()
        }
    }

    // MARK: Words

    static func headline(_ e: GitPullError, defaultBranch: String?) -> String {
        switch e.failure {
        case .detachedHead: "Not on a branch"
        case .noUpstream(let b): "\(b) doesn’t track a remote branch"
        case .upstreamGone: "Its remote branch is gone"
        case .diverged: "\(e.branch ?? "The branch") has diverged"
        case .localChanges: "Uncommitted changes are in the way"
        case .untrackedFiles: "Untracked files are in the way"
        case .authentication: "The remote refused access"
        case .network: "Couldn’t reach the remote"
        case .other: "Git pull failed"
        }
    }

    static func explanation(_ e: GitPullError, defaultBranch: String?) -> String {
        let up = e.upstream ?? "its upstream"
        switch e.failure {
        case .detachedHead:
            return "HEAD is detached, so there is no branch to pull into. Check out a branch first."
        case .noUpstream(let b):
            return "Push it with git push -u, or point it at a remote branch with git branch --set-upstream-to=origin/\(b)."
        case .upstreamGone(let b, _):
            let next = defaultBranch.map { " Check out \($0) to carry on." } ?? ""
            return "\(b) tracks a branch that no longer exists on the remote, usually because its pull request was merged.\(next)"
        case .diverged(let ahead, let behind):
            let counts: String
            if let ahead, let behind {
                counts = "You have \(Self.commits(ahead)) that \(up) doesn’t, and it has \(Self.commits(behind)) you don’t. "
            } else { counts = "" }
            return counts + "Clinic only fast-forwards, so rebase or merge in a shell."
        case .localChanges:
            return "The pull would overwrite your edits to these files. Commit or stash them, then try again."
        case .untrackedFiles:
            return "The pull would write tracked files over these. Move or remove them, then try again."
        case .authentication:
            return "Clinic can’t answer a password or passphrase prompt. Check your SSH key or git credential helper, then try again."
        case .network:
            return "Check your connection or VPN, then try again."
        case .other:
            return "git stopped without pulling. Its output is below."
        }
    }

    static func files(_ f: GitPullFailure) -> [String] {
        switch f {
        case .localChanges(let files), .untrackedFiles(let files): files
        default: []
        }
    }

    private static func commits(_ n: Int) -> String { n == 1 ? "1 commit" : "\(n) commits" }
}
