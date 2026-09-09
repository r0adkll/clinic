import Foundation

/// Environment for tool subprocesses.
///
/// A GUI app launched from Finder or the Dock inherits launchd's bare `/usr/bin:/bin:/usr/sbin:/sbin`,
/// so none of the CLIs Clinic shells out to — `gh`, `claude`, `git` — are on `PATH` by default. Two
/// layers fix that (ADR-086): a hardcoded prepend of the prefixes we know, and, behind it, `PATH` as
/// the user's own login shell builds it.
public enum ProcessEnvironment {
    /// Prefixes prepended unconditionally: both Homebrew roots and `~/.local/bin`, where Claude Code's
    /// installer puts `claude` (ADR-084). Cheap, and right whenever they exist.
    static var toolPaths: [String] {
        ["/opt/homebrew/bin", "/usr/local/bin", FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path]
    }

    /// `PATH` as the user's login shell builds it, resolved once per launch. This is the layer that
    /// finds tools under a package manager Clinic has never heard of — nix, mise, asdf, pkgx.
    /// Empty when there is no usable `SHELL`, when the shell fails, or when it takes too long.
    static let loginShellPath: [String] = readLoginShellPath()

    /// Resolve the login shell's `PATH` up front, off the main thread, so the first `git` call of the
    /// session does not pay for it.
    public static func prewarm() {
        DispatchQueue.global(qos: .utility).async { _ = loginShellPath }
    }

    static func withToolPaths(base: [String: String] = ProcessInfo.processInfo.environment,
                              login: [String] = loginShellPath) -> [String: String] {
        var env = base
        let inherited = (env["PATH"] ?? "/usr/bin:/bin").split(separator: ":").map(String.init)
        var seen = Set<String>()
        // Ordering: the prefixes we vouch for, then what we inherited, then whatever else the login
        // shell knows about. Inherited wins over the login shell so a deliberately narrowed `PATH`
        // (tests, a wrapper script) still shadows the user's everyday one.
        env["PATH"] = (toolPaths + inherited + login).filter { seen.insert($0).inserted }.joined(separator: ":")
        return env
    }

    /// Whether a CLI exists on the `PATH` Clinic would hand a subprocess.
    ///
    /// Filesystem only — no subprocess, so the Automations gallery can grey out every template that
    /// needs a missing tool without spawning one process per tile (ADR-095, reusing ADR-086's PATH).
    public static func hasTool(_ name: String) -> Bool {
        guard !name.isEmpty, !name.contains("/") else {
            return FileManager.default.isExecutableFile(atPath: name)
        }
        let path = withToolPaths()["PATH"] ?? ""
        for dir in path.split(separator: ":") where !dir.isEmpty {
            if FileManager.default.isExecutableFile(atPath: dir + "/" + name) { return true }
        }
        return false
    }

    /// `$SHELL -l -c 'printenv PATH'`. `printenv` rather than `echo $PATH` because fish stores `PATH`
    /// as a list and would print it space-separated. Login (not interactive) keeps this to profile
    /// files: an interactive shell can block on a prompt, and the hardcoded prefixes cover the rc-file
    /// case that misses.
    static func readLoginShellPath(shell: String? = ProcessInfo.processInfo.environment["SHELL"],
                                   timeout: TimeInterval = 3) -> [String] {
        guard let shell, !shell.isEmpty, FileManager.default.isExecutableFile(atPath: shell) else { return [] }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        p.arguments = ["-l", "-c", "/usr/bin/printenv PATH"]
        p.environment = ProcessInfo.processInfo.environment
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return [] }

        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var data = Data()
        DispatchQueue.global(qos: .utility).async {
            data = out.fileHandleForReading.readDataToEndOfFile()
            done.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            return []
        }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return [] }
        return parsePath(String(decoding: data, as: UTF8.self))
    }

    /// Last line of the shell's output, split on `:`. Profiles that print banners are tolerated.
    static func parsePath(_ raw: String) -> [String] {
        let line = raw.split(separator: "\n").last.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        return line.split(separator: ":").map(String.init).filter { $0.hasPrefix("/") }
    }
}

/// Runs `/usr/bin/env <tool> …` off the main actor and collects both streams.
///
/// Shared by every CLI wrapper in ClinicCore (`gh`, `claude plugin`) for one reason worth not
/// copy-pasting: both pipes are drained concurrently, so a chatty stderr cannot deadlock stdout.
enum ToolProcess {
    struct Result: Sendable {
        var status: Int32
        var stdout: Data
        var stderr: String
        var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
    }

    /// `currentDirectory` matters for tools that read the *project* out of their cwd rather than an
    /// argument — `claude mcp add --scope local|project` writes into whichever project it is standing
    /// in, so without this Clinic could only ever configure its own working directory (ADR-093).
    static func run(executable: String, arguments: [String], environment: [String: String],
                    currentDirectory: URL? = nil) async -> Result {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: runSync(executable: executable, arguments: arguments,
                                               environment: environment, currentDirectory: currentDirectory))
            }
        }
    }

    static func runSync(executable: String, arguments: [String], environment: [String: String],
                        currentDirectory: URL? = nil) -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = [executable] + arguments
        p.environment = environment
        // A directory that has since been deleted makes `Process.run` throw rather than fall back,
        // so an unreachable cwd degrades to the app's own instead of failing the command.
        if let currentDirectory, FileManager.default.fileExists(atPath: currentDirectory.path) {
            p.currentDirectoryURL = currentDirectory
        }

        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice

        do { try p.run() } catch {
            return Result(status: -1, stdout: Data(), stderr: "could not launch \(executable): \(error.localizedDescription)")
        }

        let group = DispatchGroup()
        nonisolated(unsafe) var outData = Data()
        nonisolated(unsafe) var errData = Data()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async { outData = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async { errData = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.wait()
        p.waitUntilExit()
        return Result(status: p.terminationStatus, stdout: outData, stderr: String(decoding: errData, as: UTF8.self))
    }
}
