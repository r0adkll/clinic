import Foundation

/// Environment for tool subprocesses. GUI apps inherit a minimal PATH, so Homebrew, `/usr/local` and
/// `~/.local/bin` — where Claude Code's own installer puts `claude` — are prepended.
enum ProcessEnvironment {
    static var toolPaths: [String] {
        ["/opt/homebrew/bin", "/usr/local/bin", FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path]
    }

    static func withToolPaths(base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var env = base
        let tools = toolPaths
        let existing = (env["PATH"] ?? "/usr/bin:/bin").split(separator: ":").map(String.init)
        env["PATH"] = (tools + existing.filter { !tools.contains($0) }).joined(separator: ":")
        return env
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

    static func run(executable: String, arguments: [String], environment: [String: String]) async -> Result {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: runSync(executable: executable, arguments: arguments, environment: environment))
            }
        }
    }

    static func runSync(executable: String, arguments: [String], environment: [String: String]) -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = [executable] + arguments
        p.environment = environment

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
