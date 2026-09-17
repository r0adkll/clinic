import Foundation

/// The stack a GitHub pull request belongs to (ADR-163): an ordered chain where position 1 targets the
/// stack's base and each layer above targets the branch of the one below. Read by its own GraphQL call,
/// because `gh pr view --json` has no stack field.
public struct PullRequestStack: Hashable, Sendable {
    /// One layer, with just enough of its pull request to draw a row and to judge whether it holds up a
    /// merge of the layers above it.
    public struct Entry: Hashable, Sendable, Identifiable {
        /// The head commit's status check rollup, collapsed the way the mark reads it.
        public enum Checks: String, Hashable, Sendable { case passing, failing, pending, none }

        public var position: Int
        public var ref: PullRequestRef
        public var title: String
        public var state: PullRequest.State
        public var isDraft: Bool
        public var headRefName: String
        /// MERGEABLE / CONFLICTING / UNKNOWN
        public var mergeable: String
        /// APPROVED / CHANGES_REQUESTED / REVIEW_REQUIRED / ""
        public var reviewDecision: String
        public var checks: Checks
        public var id: String { ref.id }

        public init(position: Int, ref: PullRequestRef, title: String, state: PullRequest.State, isDraft: Bool = false,
                    headRefName: String = "", mergeable: String = "UNKNOWN", reviewDecision: String = "",
                    checks: Checks = .none) {
            self.position = position; self.ref = ref; self.title = title; self.state = state; self.isDraft = isDraft
            self.headRefName = headRefName; self.mergeable = mergeable; self.reviewDecision = reviewDecision
            self.checks = checks
        }

        public var isConflicting: Bool { mergeable == "CONFLICTING" }

        /// The same precedence as `PullRequestMark(pr:)`, over the fields a stack read carries, so a
        /// layer on the stack map wears the glyph and dot its own pane would. Unanswered comments are
        /// not in the read and never mark a layer.
        public var mark: PullRequestMark {
            let prefix = state == .open ? (isDraft ? "Draft" : "Open") : (state == .merged ? "Merged" : "Closed")
            guard state == .open else {
                return PullRequestMark(state: state, isDraft: isDraft, attention: .none,
                                       symbolName: state == .merged ? "arrow.trianglehead.merge" : "xmark.circle", summary: prefix)
            }
            let (attention, symbol, words): (PullRequestMark.Attention, String, String?) =
                if checks == .failing { (.checksFailing, "xmark.octagon", "checks failing") }
                else if isConflicting { (.conflicts, "exclamationmark.triangle", "merge conflicts") }
                else if reviewDecision == "CHANGES_REQUESTED" { (.changesRequested, "exclamationmark.bubble", "changes requested") }
                else if checks == .pending { (.checksPending, "clock", "checks pending") }
                else if reviewDecision == "APPROVED" { (.approved, "checkmark.circle", "approved") }
                else { (.none, PullRequestMark.symbol, nil) }
            return PullRequestMark(state: state, isDraft: isDraft, attention: attention, symbolName: symbol,
                                   summary: words.map { "\(prefix) · \($0)" } ?? prefix)
        }
    }

    /// Unique within the repository.
    public var number: Int
    /// Declared size; `entries` can be shorter if GitHub paginates past what was asked for.
    public var size: Int
    /// The branch the stack lands on — not the viewed pull request's own base, which is the layer below.
    public var baseRefName: String
    /// The viewed pull request's position; 1 is closest to the base.
    public var position: Int
    /// Ascending by position.
    public var entries: [Entry]

    public init(number: Int, size: Int, baseRefName: String, position: Int, entries: [Entry]) {
        self.number = number; self.size = size; self.baseRefName = baseRefName; self.position = position
        self.entries = entries.sorted { $0.position < $1.position }
    }

    /// Layers under the viewed one, bottom first.
    public var below: [Entry] { entries.filter { $0.position < position } }
    /// Layers over the viewed one, bottom first.
    public var above: [Entry] { entries.filter { $0.position > position } }
    /// What merging the viewed pull request takes with it: every open layer under it (ADR-163).
    public var landsWith: [Entry] { below.filter { $0.state == .open } }
    /// Still open layers anywhere in the stack. A stack whose every layer is merged or closed is history.
    public var isOpen: Bool { entries.contains { $0.state == .open } }

    // MARK: Reading

    /// The stack for one pull request. `entries(first:50)` covers every stack in practice; `size` still
    /// reports the real count if one ever runs longer.
    static let query = """
    query($owner:String!,$repo:String!,$number:Int!){
      repository(owner:$owner,name:$repo){
        pullRequest(number:$number){
          stackEntry{position}
          stack{
            number size baseRefName
            entries(first:50){nodes{position pullRequest{
              number url title state isDraft headRefName mergeable reviewDecision
              commits(last:1){nodes{commit{statusCheckRollup{state}}}}
            }}}
          }
        }
      }
    }
    """

    /// Parses the `query` response. Nil when the pull request is in no stack.
    public static func parse(_ data: Data) throws -> PullRequestStack? {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pr = ((obj["data"] as? [String: Any])?["repository"] as? [String: Any])?["pullRequest"] as? [String: Any] else {
            throw GitHubError(command: "api graphql", exitCode: 0, stderr: "unexpected GraphQL shape (no pullRequest)")
        }
        guard let stack = pr["stack"] as? [String: Any], let number = (stack["number"] as? NSNumber)?.intValue else { return nil }
        let position = ((pr["stackEntry"] as? [String: Any])?["position"] as? NSNumber)?.intValue ?? 0
        let nodes = (stack["entries"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []
        let entries: [Entry] = nodes.compactMap { node in
            guard let position = (node["position"] as? NSNumber)?.intValue,
                  let p = node["pullRequest"] as? [String: Any],
                  let s = p["url"] as? String, let url = URL(string: s), let ref = PullRequestRef(url: url) else { return nil }
            let state: PullRequest.State = switch (p["state"] as? String ?? "").uppercased() {
            case "MERGED": .merged
            case "CLOSED": .closed
            default: .open
            }
            let commit = (((p["commits"] as? [String: Any])?["nodes"] as? [[String: Any]])?.last?["commit"] as? [String: Any])
            let rollup = (commit?["statusCheckRollup"] as? [String: Any])?["state"] as? String
            return Entry(position: position, ref: ref, title: p["title"] as? String ?? "", state: state,
                         isDraft: p["isDraft"] as? Bool ?? false, headRefName: p["headRefName"] as? String ?? "",
                         mergeable: (p["mergeable"] as? String ?? "UNKNOWN").uppercased(),
                         reviewDecision: (p["reviewDecision"] as? String ?? "").uppercased(),
                         checks: checks(rollup))
        }
        return PullRequestStack(number: number, size: (stack["size"] as? NSNumber)?.intValue ?? entries.count,
                                baseRefName: stack["baseRefName"] as? String ?? "", position: position, entries: entries)
    }

    /// `StatusState`: SUCCESS / FAILURE / ERROR / PENDING / EXPECTED; null when the commit has no checks.
    static func checks(_ raw: String?) -> Entry.Checks {
        switch raw?.uppercased() {
        case "SUCCESS": .passing
        case "FAILURE", "ERROR": .failing
        case "PENDING", "EXPECTED": .pending
        default: .none
        }
    }

    /// A GraphQL schema error: the server has no such field, which is how a host from before stacks
    /// answers. Distinct from a failure worth retrying.
    static func isUnsupported(stderr: String, stdout: Data) -> Bool {
        stderr.contains("doesn't exist on type") || String(decoding: stdout, as: UTF8.self).contains("undefinedField")
    }

    // MARK: Ordering

    /// A session's pull requests with each stack's members in position order, the first member of a
    /// stack keeping its place in the list and the rest gathered up behind it. Anything not in a stack
    /// (or not read yet) stays where it was.
    public static func ordered(_ refs: [PullRequestRef], stacks: (PullRequestRef) -> PullRequestStack?) -> [PullRequestRef] {
        var result: [PullRequestRef] = []
        var placed = Set<String>()
        for ref in refs where !placed.contains(ref.id) {
            guard let stack = stacks(ref) else { result.append(ref); placed.insert(ref.id); continue }
            let key = "\(ref.host)/\(ref.repository)#\(stack.number)"
            let members = refs.filter { other in
                guard !placed.contains(other.id), let s = stacks(other) else { return false }
                return "\(other.host)/\(other.repository)#\(s.number)" == key
            }
            for member in members.sorted(by: { (stacks($0)?.position ?? 0) < (stacks($1)?.position ?? 0) }) {
                result.append(member); placed.insert(member.id)
            }
        }
        return result
    }
}

// MARK: - Asynchronous merge (ADR-163)

/// `PUT …/pulls/{n}/merge-async` and `GET …/merge-async/{uuid}` share one response shape.
public struct AsyncMergeResult: Equatable, Sendable {
    public enum Status: String, Sendable { case pending, merged, enqueued, failed }
    public var status: Status
    public var uuid: String?
    public var message: String?

    public init(status: Status, uuid: String? = nil, message: String? = nil) {
        self.status = status; self.uuid = uuid; self.message = message
    }

    /// Done: nothing left to poll for.
    public var isFinished: Bool { status != .pending }

    static func parse(_ data: Data) -> AsyncMergeResult? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = obj["status"] as? String, let status = Status(rawValue: raw.lowercased()) else { return nil }
        let details = obj["details"] as? [String: Any]
        return AsyncMergeResult(status: status, uuid: details?["uuid"] as? String, message: details?["message"] as? String)
    }
}
