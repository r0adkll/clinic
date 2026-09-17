import Foundation

/// "What is the state of this PR, and what should I do about it" in plain language (ADR-087).
///
/// The panel used to make the reader assemble this themselves out of a coloured glyph, a tab they had
/// to click, and a grid of raw GraphQL enums (`BLOCKED`, `UNSTABLE`, `DIRTY`). All of that judgement
/// lives here instead, as pure data over a `PullRequest`, so it is a unit test rather than a screenshot.
public struct PullRequestStatus: Equatable, Sendable {
    /// How a line reads, not what colour it is — the view maps tone to ink.
    public enum Tone: String, Sendable, Comparable {
        /// Stops the merge. Wants a decision now.
        case blocking
        /// Will resolve itself, or is waiting on someone else.
        case waiting
        /// Settled and fine.
        case good
        /// Context, no verdict.
        case neutral

        /// Blocking sorts first; `neutral` last.
        var rank: Int {
            switch self { case .blocking: 0; case .waiting: 1; case .good: 2; case .neutral: 3 }
        }
        public static func < (a: Tone, b: Tone) -> Bool { a.rank < b.rank }
    }

    public struct Line: Equatable, Sendable, Identifiable {
        public var id: String
        public var tone: Tone
        public var symbol: String
        /// "2 checks failing"
        public var text: String
        /// "build (macOS) · test (unit)" — names, not a second sentence.
        public var detail: String?

        public init(id: String, tone: Tone, symbol: String, text: String, detail: String? = nil) {
            self.id = id; self.tone = tone; self.symbol = symbol; self.text = text; self.detail = detail
        }
    }

    /// The one prompt worth offering, chosen by the same precedence as `PullRequestMark.Attention`.
    /// Nil when the PR needs nothing from Claude.
    public struct Action: Equatable, Sendable {
        public var title: String
        public var symbol: String
        public var prompt: String
        public init(title: String, symbol: String, prompt: String) {
            self.title = title; self.symbol = symbol; self.prompt = prompt
        }
    }

    public var lines: [Line]
    public var action: Action?
    /// A merge button would do something. False for drafts, conflicts, and anything not open.
    public var canMerge: Bool
    /// Why the merge button is off, when it is. Nil when `canMerge`.
    public var mergeBlockedReason: String?
    /// Enabling auto-merge would be accepted. Also false in a stack, where GitHub does not offer it (ADR-163).
    public var canAutoMerge: Bool
    /// Why auto-merge is off, when it is.
    public var autoMergeBlockedReason: String?

    public init(lines: [Line], action: Action?, canMerge: Bool, mergeBlockedReason: String?,
                canAutoMerge: Bool? = nil, autoMergeBlockedReason: String? = nil) {
        self.lines = lines; self.action = action; self.canMerge = canMerge; self.mergeBlockedReason = mergeBlockedReason
        self.canAutoMerge = canAutoMerge ?? canMerge
        self.autoMergeBlockedReason = autoMergeBlockedReason ?? mergeBlockedReason
    }

    /// - Parameter stack: the stack the pull request is in, when one has been read (ADR-163). Its layers
    ///   below this one merge with it, so what holds them up holds this merge up too.
    public init(pr: PullRequest, viewerLogin: String?, stack: PullRequestStack? = nil) {
        let ref = pr.ref
        guard pr.state == .open else {
            let merged = pr.state == .merged
            lines = [Line(id: "state", tone: .neutral, symbol: merged ? "arrow.trianglehead.merge" : "xmark.circle",
                          text: merged ? "Merged into \(pr.baseRefName)" : "Closed without merging",
                          detail: pr.headRefName.isEmpty ? nil : "from \(pr.headRefName)")]
            action = nil
            canMerge = false
            mergeBlockedReason = merged ? "Already merged" : "Closed"
            canAutoMerge = false
            autoMergeBlockedReason = mergeBlockedReason
            return
        }

        var lines: [Line] = []
        let failing = pr.checks.filter { $0.status == .failure }
        let pending = pr.checks.filter { $0.status == .pending }
        let conflicting = pr.mergeable == "CONFLICTING" || pr.mergeStateStatus == "DIRTY"
        let unanswered = Self.unansweredComments(pr: pr, viewerLogin: viewerLogin)

        if !failing.isEmpty {
            lines.append(Line(id: "checks", tone: .blocking, symbol: "xmark.octagon.fill",
                              text: Self.count(failing.count, "check") + " failing",
                              detail: Self.names(failing)))
        }
        if !pending.isEmpty {
            lines.append(Line(id: "pending", tone: .waiting, symbol: "clock",
                              text: Self.count(pending.count, "check") + " still running",
                              detail: Self.names(pending)))
        }
        if failing.isEmpty && pending.isEmpty && !pr.checks.isEmpty {
            lines.append(Line(id: "checks", tone: .good, symbol: "checkmark.circle.fill",
                              text: "All " + Self.count(pr.checks.count, "check") + " passed"))
        }
        if conflicting {
            lines.append(Line(id: "merge", tone: .blocking, symbol: "arrow.trianglehead.branch",
                              text: "Conflicts with \(pr.baseRefName)", detail: "Rebase or merge \(pr.baseRefName) to resolve"))
        } else if pr.mergeStateStatus == "BEHIND" {
            lines.append(Line(id: "merge", tone: .waiting, symbol: "arrow.down.circle",
                              text: "Behind \(pr.baseRefName)", detail: "Update the branch before merging"))
        } else if pr.mergeable == "MERGEABLE" {
            lines.append(Line(id: "merge", tone: .good, symbol: "arrow.trianglehead.merge",
                              text: "No conflicts with \(pr.baseRefName)"))
        }
        switch pr.reviewDecision {
        case "CHANGES_REQUESTED":
            lines.append(Line(id: "review", tone: .blocking, symbol: "exclamationmark.bubble.fill",
                              text: "Changes requested", detail: Self.reviewers(pr, state: "CHANGES_REQUESTED")))
        case "APPROVED":
            let who = Self.reviewers(pr, state: "APPROVED")
            lines.append(Line(id: "review", tone: .good, symbol: "checkmark.seal.fill",
                              text: who.map { "Approved by \($0)" } ?? "Approved"))
        case "REVIEW_REQUIRED":
            lines.append(Line(id: "review", tone: .waiting, symbol: "person.crop.circle.badge.clock",
                              text: "Waiting on review"))
        default:
            break
        }
        if unanswered > 0 {
            lines.append(Line(id: "comments", tone: .waiting, symbol: "bubble.left.fill",
                              text: Self.count(unanswered, "unanswered comment"),
                              detail: pr.comments.last.map { "latest from \($0.author.login)" }))
        }
        // The layers that would land with this one (ADR-163). GitHub requires them approved and green;
        // only a draft or a conflict under this one is certain to stop the merge, so only those turn the
        // button off. Failing checks and requested changes read as blocking, as they do on the PR itself.
        let lower = stack?.landsWith ?? []
        let lowerDrafts = lower.filter(\.isDraft)
        let lowerConflicts = lower.filter(\.isConflicting)
        let lowerFailing = lower.filter { $0.checks == .failing }
        let lowerChanges = lower.filter { $0.reviewDecision == "CHANGES_REQUESTED" }
        if !lowerDrafts.isEmpty {
            lines.append(Line(id: "stack-draft", tone: .blocking, symbol: "pencil.line",
                              text: Self.below(lowerDrafts, "is still a draft", "are still drafts"),
                              detail: "Layers below merge with this one"))
        }
        if !lowerConflicts.isEmpty {
            lines.append(Line(id: "stack-conflicts", tone: .blocking, symbol: "arrow.trianglehead.branch",
                              text: Self.below(lowerConflicts, "has conflicts", "have conflicts"),
                              detail: "Layers below merge with this one"))
        }
        if !lowerFailing.isEmpty {
            lines.append(Line(id: "stack-checks", tone: .blocking, symbol: "xmark.octagon.fill",
                              text: "Checks failing on " + Self.references(lowerFailing) + " below"))
        }
        if !lowerChanges.isEmpty {
            lines.append(Line(id: "stack-review", tone: .blocking, symbol: "exclamationmark.bubble.fill",
                              text: "Changes requested on " + Self.references(lowerChanges) + " below"))
        }
        if pr.autoMergeEnabled {
            lines.append(Line(id: "auto", tone: .neutral, symbol: "wand.and.stars",
                              text: "Auto-merge is on", detail: "Merges itself once everything passes"))
        }

        // Blocking first, then waiting, then settled — but stable within a tone, so the reading order
        // inside a group stays checks → merge → review → comments.
        var ordered = lines.enumerated().sorted {
            $0.element.tone.rank != $1.element.tone.rank ? $0.element.tone.rank < $1.element.tone.rank : $0.offset < $1.offset
        }.map(\.element)
        // Draft is pinned above the sort. It is the fact that frames every line under it — "all checks
        // passed" reads very differently on a draft — so it cannot sit at the bottom with the footnotes.
        if pr.isDraft {
            ordered.insert(Line(id: "draft", tone: .neutral, symbol: "pencil.line",
                                text: "Draft", detail: "Not open for review yet"), at: 0)
        }
        // Pinned under Draft for the same reason: which layer this is changes what merging it means.
        if let stack {
            let detail = if !lower.isEmpty { "Merging also lands " + Self.references(lower) }
                else if stack.position <= 1 { "Bottom of the stack" }
                else { "Every layer below has merged" }
            ordered.insert(Line(id: "stack", tone: .neutral, symbol: "square.stack.3d.up",
                                text: "Layer \(stack.position) of \(stack.size) in a stack onto \(stack.baseRefName)",
                                detail: detail), at: pr.isDraft ? 1 : 0)
        }
        self.lines = ordered

        // Same precedence as the mark, so the panel's headline action and the sidebar glyph never disagree.
        if !failing.isEmpty {
            action = Action(title: "Fix the failing checks", symbol: "hammer",
                            prompt: "The CI checks on PR #\(ref.number) (\(ref.url)) are failing: \(Self.names(failing) ?? ""). Investigate the failures and fix them.")
        } else if conflicting {
            action = Action(title: "Resolve the conflicts", symbol: "arrow.trianglehead.branch",
                            prompt: "PR #\(ref.number) (\(ref.url)) has merge conflicts with \(pr.baseRefName). Rebase or merge \(pr.baseRefName) and resolve them.")
        } else if pr.reviewDecision == "CHANGES_REQUESTED" || unanswered > 0 {
            action = Action(title: "Address the review comments", symbol: "bubble.left.and.text.bubble.right",
                            prompt: "Address the unresolved review comments on PR #\(ref.number) (\(ref.url)).")
        } else if pr.isDraft {
            action = Action(title: "Review this PR", symbol: "magnifyingglass",
                            prompt: "Review PR #\(ref.number) (\(ref.url)) and summarize any problems.")
        } else {
            action = nil
        }

        canMerge = !pr.isDraft && !conflicting && lowerDrafts.isEmpty && lowerConflicts.isEmpty
        mergeBlockedReason = pr.isDraft ? "Still a draft"
            : conflicting ? "Conflicts with \(pr.baseRefName)"
            : !lowerDrafts.isEmpty ? Self.below(lowerDrafts, "is still a draft", "are still drafts")
            : !lowerConflicts.isEmpty ? Self.below(lowerConflicts, "has conflicts", "have conflicts")
            : nil
        canAutoMerge = canMerge && stack == nil
        autoMergeBlockedReason = mergeBlockedReason ?? (stack != nil ? "Auto-merge isn't available for stacked pull requests" : nil)
    }

    /// "#1, #2 and #3", then "+N more" past three.
    static func references(_ entries: [PullRequestStack.Entry]) -> String {
        let refs = entries.map { "#\($0.ref.number)" }
        guard refs.count > 1 else { return refs.first ?? "" }
        if refs.count > 3 { return refs.prefix(3).joined(separator: ", ") + " +\(refs.count - 3) more" }
        return refs.dropLast().joined(separator: ", ") + " and " + refs.last!
    }

    /// "#1 below has conflicts" / "#1 and #2 below have conflicts".
    static func below(_ entries: [PullRequestStack.Entry], _ one: String, _ many: String) -> String {
        references(entries) + " below " + (entries.count == 1 ? one : many)
    }

    /// Comments from someone other than the viewer, posted after the viewer last said anything. The one
    /// implementation of the rule: `PullRequestMark` calls this too, so the panel's status block and
    /// the sidebar glyph cannot disagree about what is outstanding.
    ///
    /// An *approving* review is excluded. It is somebody else's newer comment by the letter of the rule,
    /// but nothing is being asked of the author — counting it made an approved PR read as both
    /// "Approved by X" and "1 unanswered comment" at the same time (ADR-087).
    public static func unansweredComments(pr: PullRequest, viewerLogin: String?) -> Int {
        let viewer = viewerLogin ?? pr.author.login
        var lastViewerActivity = pr.comments.filter { $0.author.login == viewer }.map(\.createdAt).max()
        if viewer == pr.author.login { lastViewerActivity = max(lastViewerActivity ?? .distantPast, pr.createdAt) }
        return pr.comments.filter { c in
            c.author.login != viewer && !c.author.isBot && c.createdAt > (lastViewerActivity ?? .distantPast)
                && !(c.kind == .review && c.reviewState == "APPROVED")
        }.count
    }

    /// "2 checks" / "1 check".
    static func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }

    /// At most three names, then "+N more"; a long CI matrix must not push the actions off screen.
    static func names(_ checks: [PullRequest.Check]) -> String? {
        guard !checks.isEmpty else { return nil }
        let shown = checks.prefix(3).map(\.name)
        let rest = checks.count - shown.count
        return shown.joined(separator: " · ") + (rest > 0 ? " · +\(rest) more" : "")
    }

    /// Distinct logins that left a review in `state`, most recent first.
    static func reviewers(_ pr: PullRequest, state: String) -> String? {
        var seen = Set<String>()
        let logins = pr.comments.reversed()
            .filter { $0.kind == .review && $0.reviewState == state }
            .map(\.author.login)
            .filter { seen.insert($0).inserted }
        guard !logins.isEmpty else { return nil }
        return logins.prefix(3).joined(separator: ", ") + (logins.count > 3 ? " +\(logins.count - 3)" : "")
    }
}
