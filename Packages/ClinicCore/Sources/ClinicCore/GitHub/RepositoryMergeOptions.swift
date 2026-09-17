import Foundation

/// The merge methods and auto-merge a repository allows (ADR-164), so the merge box offers what
/// github.com would rather than every method `gh` knows. Read once per repository by its own GraphQL
/// call; a viewer with read access sees the same answer as an admin.
public struct RepositoryMergeOptions: Hashable, Sendable {
    /// In `MergeMethod.allCases` order, which is GitHub's menu order. Never empty.
    public var methods: [GitHubService.MergeMethod]
    public var autoMergeAllowed: Bool
    /// The method GitHub's own button would show this viewer, when it is one the repository allows.
    public var viewerDefault: GitHubService.MergeMethod?

    public init(methods: [GitHubService.MergeMethod], autoMergeAllowed: Bool = true,
                viewerDefault: GitHubService.MergeMethod? = nil) {
        let allowed = GitHubService.MergeMethod.allCases.filter(methods.contains)
        // GitHub refuses to save a repository with no method allowed, so an empty answer is a read
        // that went wrong, and offering nothing would leave no way to merge at all.
        self.methods = allowed.isEmpty ? GitHubService.MergeMethod.allCases : allowed
        self.autoMergeAllowed = autoMergeAllowed
        self.viewerDefault = viewerDefault.flatMap { self.methods.contains($0) ? $0 : nil }
    }

    /// Before the repository has answered, or on a host that is not asked: everything, as before.
    public static let unrestricted = RepositoryMergeOptions(methods: GitHubService.MergeMethod.allCases)

    /// The method the merge button leads with: the one chosen in Settings when the repository allows
    /// it, else the repository's default for this viewer, else the first it allows.
    public func method(preferred: GitHubService.MergeMethod) -> GitHubService.MergeMethod {
        if methods.contains(preferred) { return preferred }
        return viewerDefault ?? methods[0]
    }

    // MARK: Reading

    static let query = """
    query($owner:String!,$repo:String!){
      repository(owner:$owner,name:$repo){
        mergeCommitAllowed squashMergeAllowed rebaseMergeAllowed autoMergeAllowed viewerDefaultMergeMethod
      }
    }
    """

    public static func parse(_ data: Data) throws -> RepositoryMergeOptions {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let repo = (obj["data"] as? [String: Any])?["repository"] as? [String: Any] else {
            throw GitHubError(command: "api graphql", exitCode: 0, stderr: "unexpected GraphQL shape (no repository)")
        }
        let flags: [(String, GitHubService.MergeMethod)] = [
            ("mergeCommitAllowed", .merge), ("squashMergeAllowed", .squash), ("rebaseMergeAllowed", .rebase),
        ]
        let methods = flags.compactMap { key, method in (repo[key] as? Bool ?? true) ? method : nil }
        let viewerDefault = (repo["viewerDefaultMergeMethod"] as? String).flatMap {
            GitHubService.MergeMethod(rawValue: $0.lowercased())
        }
        return RepositoryMergeOptions(methods: methods, autoMergeAllowed: repo["autoMergeAllowed"] as? Bool ?? true,
                                      viewerDefault: viewerDefault)
    }
}
