import Foundation

/// A git remote someone typed or pasted, checked and normalised before it is handed to `git clone`
/// (ADR-168). Accepts `https://`, `http://`, `ssh://` and `git://` URLs, the scp-like
/// `git@host:owner/repo.git`, a bare `host/owner/repo`, a pasted `git clone <url>` line, and a browser
/// address such as `https://github.com/owner/repo/pull/12`, which is cut back to the repository.
///
/// Anything else is refused here rather than by git: a leading `-` would be read as an option, and
/// `ext::` and `file://` are transports that run a command or read this Mac, not remotes.
public struct GitRemoteURL: Sendable, Hashable {
    public enum Transport: String, Sendable, Hashable { case https, http, ssh, git }

    public enum ParseError: Error, Sendable, Hashable {
        case empty
        /// Not a URL and not `host:path`.
        case notARemote
        /// A scheme git could clone but Clinic will not: `file`, `ext`, `ftp`…
        case unsupportedScheme(String)
        /// A host with no repository path after it.
        case missingRepository
    }

    public var transport: Transport
    public var host: String
    public var user: String? = nil
    public var port: Int? = nil
    /// The repository's path on the host without a leading slash or `.git`: `owner/repo`.
    public var repositoryPath: String
    /// What `git clone` is given.
    public var cloneURL: String

    /// `owner/repo`'s last component: the folder git would name the clone.
    public var directoryName: String {
        let last = repositoryPath.split(separator: "/").last.map(String.init) ?? ""
        let cleaned = last.replacingOccurrences(of: ":", with: "-")
        return cleaned.isEmpty || cleaned == "." || cleaned == ".." ? "repository" : cleaned
    }

    /// `ssh -T git@github.com`: the one connection that lets a person accept a new host's key. Nil for
    /// other transports, and nil when the user or host holds anything a shell would read as more than
    /// a word, because this line is typed into a terminal for them.
    public var sshProbeCommand: String? {
        guard transport == .ssh else { return nil }
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        func isWord(_ s: String) -> Bool { !s.isEmpty && !s.hasPrefix("-") && s.unicodeScalars.allSatisfy(safe.contains) }
        guard isWord(host), user.map(isWord) ?? true else { return nil }
        return "ssh -T " + (port.map { "-p \($0) " } ?? "") + (user.map { "\($0)@" } ?? "") + host
    }

    /// `github.com/owner/repo`, for a header: no scheme, user or credentials.
    public var displayName: String { "\(host)/\(repositoryPath)" }

    public static func parse(_ input: String) -> Result<GitRemoteURL, ParseError> {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        // A line copied out of a README: `git clone git@github.com:o/r.git`, perhaps behind a `$ ` prompt.
        if s.hasPrefix("$ ") { s.removeFirst(2) }
        if s.lowercased().hasPrefix("git clone ") { s = String(s.dropFirst(10)).trimmingCharacters(in: .whitespaces) }
        if s.count >= 2, let q = s.first, q == "\"" || q == "'", s.last == q { s = String(s.dropFirst().dropLast()) }
        guard !s.isEmpty else { return .failure(.empty) }
        guard !s.hasPrefix("-"), !s.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) })
        else { return .failure(.notARemote) }

        if let r = s.range(of: "://") {
            return parseURL(s, scheme: s[..<r.lowerBound].lowercased())
        }
        // `transport::address` (`ext::sh -c …`) runs a command.
        if s.contains("::") { return .failure(.unsupportedScheme(String(s[..<s.range(of: "::")!.lowerBound]))) }
        if let colon = s.firstIndex(of: ":"), !s[..<colon].contains("/") {
            return parseScp(s, colon: colon)
        }
        // `github.com/owner/repo`: a host with a dot, then at least owner and repo.
        let parts = s.split(separator: "/", omittingEmptySubsequences: true)
        if parts.count >= 3, parts[0].contains("."), !parts[0].hasPrefix(".") {
            return parseURL("https://" + s, scheme: "https")
        }
        return .failure(.notARemote)
    }

    private static func parseURL(_ s: String, scheme: String) -> Result<GitRemoteURL, ParseError> {
        guard let transport = Transport(rawValue: scheme) else { return .failure(.unsupportedScheme(scheme)) }
        guard let c = URLComponents(string: s), let host = c.host?.lowercased(), !host.isEmpty, !host.hasPrefix("-") else { return .failure(.notARemote) }
        var parts = c.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if transport == .https || transport == .http {
            // A browser address carries more than the repository: `/owner/repo/tree/main/docs`,
            // `/group/sub/repo/-/merge_requests/4`. GitLab marks the end with `/-/`; GitHub and
            // Bitbucket repositories are always exactly two components deep.
            if let dash = parts.firstIndex(of: "-") { parts = Array(parts[..<dash]) }
            if ["github.com", "www.github.com", "bitbucket.org"].contains(host), parts.count > 2 { parts = Array(parts[..<2]) }
        }
        guard !parts.isEmpty else { return .failure(.missingRepository) }
        let gitPath = parts.joined(separator: "/")
        let repositoryPath = gitPath.hasSuffix(".git") ? String(gitPath.dropLast(4)) : gitPath
        guard !repositoryPath.isEmpty else { return .failure(.missingRepository) }

        var out = URLComponents()
        out.scheme = scheme
        out.user = c.user; out.password = c.password
        out.host = host; out.port = c.port
        out.path = "/" + gitPath
        guard let cloneURL = out.string else { return .failure(.notARemote) }
        return .success(GitRemoteURL(transport: transport, host: host, user: c.user, port: c.port, repositoryPath: repositoryPath, cloneURL: cloneURL))
    }

    /// `[user@]host:path`, ssh's own shorthand.
    private static func parseScp(_ s: String, colon: String.Index) -> Result<GitRemoteURL, ParseError> {
        let authority = s[..<colon]
        var path = String(s[s.index(after: colon)...])
        let host = (authority.split(separator: "@", maxSplits: 1).last.map(String.init) ?? "").lowercased()
        let user = authority.contains("@") ? String(authority.split(separator: "@", maxSplits: 1)[0]) : nil
        guard !host.isEmpty, !host.hasPrefix("-"), user?.hasPrefix("-") != true, user?.isEmpty != true else { return .failure(.notARemote) }
        while path.hasSuffix("/") { path.removeLast() }
        let trimmed = path.hasPrefix("/") ? String(path.drop(while: { $0 == "/" })) : path
        let repositoryPath = trimmed.hasSuffix(".git") ? String(trimmed.dropLast(4)) : trimmed
        guard !repositoryPath.isEmpty, !path.hasPrefix("-") else { return .failure(.missingRepository) }
        return .success(GitRemoteURL(transport: .ssh, host: host, user: user, repositoryPath: repositoryPath, cloneURL: "\(authority):\(path)"))
    }
}
