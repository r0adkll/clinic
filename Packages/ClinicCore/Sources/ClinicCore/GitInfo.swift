import Foundation

/// Read-only git facts for the footer. Runs `git` as a subprocess off the main actor.
public enum GitInfo {
    /// Current branch name, "HEAD" when detached, nil when not a repository or git is unavailable.
    public static func branch(at directory: String) async -> String? {
        // symbolic-ref works before the first commit; rev-parse covers detached HEAD.
        if let b = await run(["symbolic-ref", "--short", "-q", "HEAD"], in: directory) { return b }
        return await run(["rev-parse", "--abbrev-ref", "HEAD"], in: directory)
    }

    /// Repository top level for a directory (worktrees report their own top level).
    public static func topLevel(at directory: String) async -> String? {
        await run(["rev-parse", "--show-toplevel"], in: directory)
    }

    /// `origin` remote as a browsable https URL (handles ssh `git@host:owner/repo.git` and https forms).
    public static func remoteWebURL(at directory: String) async -> URL? {
        guard let raw = await run(["remote", "get-url", "origin"], in: directory) else { return nil }
        return webURL(fromRemote: raw)
    }

    public static func webURL(fromRemote raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasSuffix(".git") { s.removeLast(4) }
        if s.hasPrefix("git@"), let colon = s.firstIndex(of: ":") {
            let host = s[s.index(s.startIndex, offsetBy: 4)..<colon]
            let path = s[s.index(after: colon)...]
            return URL(string: "https://\(host)/\(path)")
        }
        if s.hasPrefix("ssh://") {
            s = s.replacingOccurrences(of: "ssh://", with: "https://")
            if let at = s.firstIndex(of: "@") { s.removeSubrange(s.index(s.startIndex, offsetBy: 8)...at) }
            return URL(string: s)
        }
        if s.hasPrefix("http://") || s.hasPrefix("https://") { return URL(string: s) }
        return nil
    }

    private static func run(_ args: [String], in directory: String) async -> String? {
        guard FileManager.default.fileExists(atPath: directory) else { return nil }
        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                p.arguments = ["git", "-C", directory] + args
                p.environment = ProcessEnvironment.withToolPaths()
                let out = Pipe()
                p.standardOutput = out
                p.standardError = FileHandle.nullDevice
                do { try p.run() } catch { cont.resume(returning: nil); return }
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                guard p.terminationStatus == 0 else { cont.resume(returning: nil); return }
                let s = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                cont.resume(returning: s.isEmpty ? nil : s)
            }
        }
    }
}
