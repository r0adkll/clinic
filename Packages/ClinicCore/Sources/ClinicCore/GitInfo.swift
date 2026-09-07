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

    private static func run(_ args: [String], in directory: String) async -> String? {
        guard FileManager.default.fileExists(atPath: directory) else { return nil }
        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                p.arguments = ["git", "-C", directory] + args
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
