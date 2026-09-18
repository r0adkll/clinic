import Foundation
import Darwin

/// Who owns the sockets in an Application Support directory (ADR-167).
///
/// Both servers used to `unlink` and rebind their path on start, so a second Clinic on the same
/// directory (a Debug build beside the installed app) took the first one's hooks and MCP calls, and
/// took the path away again when it quit. The first instance to arrive keeps the plain names; any
/// other gets names carrying its pid, for its sockets and for the settings files that name them.
public enum SocketClaim {
    /// True when something accepts connections at `path`. The hook server never writes to a client, so
    /// connecting and closing costs the listener nothing. Do not point this at the MCP socket: that
    /// server answers every connection, and answering one that has gone is a `SIGPIPE`.
    public static func isLive(_ path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            path.withCString { strncpy(UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self), $0, 103) }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        return withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) } } == 0
    }

    /// `""` when nobody is listening on the directory's plain hook socket, `"-<pid>"` otherwise.
    public static func instanceSuffix(appSupport: URL, pid: Int32 = getpid()) -> String {
        isLive(HookServer.defaultSocketPath(appSupport: appSupport)) ? "-\(pid)" : ""
    }

    /// The pid a suffixed file was named for: `hook-123.sock`, `mcp-123.sock`, `hooks-123.json`,
    /// `hooks-123-worktree-head.json`. Nil for the plain names, which belong to the first instance.
    public static func pid(inFileName name: String) -> Int32? {
        for stem in ["hook-", "mcp-", "hooks-"] where name.hasPrefix(stem) {
            let digits = name.dropFirst(stem.count).prefix(while: \.isNumber)
            let rest = name.dropFirst(stem.count + digits.count)
            if !digits.isEmpty, rest.hasPrefix(".") || rest.hasPrefix("-"), let pid = Int32(digits) { return pid }
        }
        return nil
    }

    /// Removes what instances that are gone left behind. A crash skips `stop()`.
    public static func sweepStale(in directory: URL, isAlive: (Int32) -> Bool = { kill($0, 0) == 0 || errno == EPERM }) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names {
            guard let pid = pid(inFileName: name), !isAlive(pid) else { continue }
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }
}
