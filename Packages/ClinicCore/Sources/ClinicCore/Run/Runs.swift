import CryptoKit
import Foundation

/// A run's identity (ADR-122): one configuration in one checkout. A worktree session and the project
/// root can each run Desktop at the same time, and they are two runs.
public struct RunKey: Hashable, Sendable, CustomStringConvertible {
    public let checkout: String
    public let configId: String
    public init(checkout: String, configId: String) { self.checkout = checkout; self.configId = configId }
    public var description: String { "\(configId)@\(checkout)" }
}

/// Where runs happen and which file describes them (ADR-122).
public enum RunCheckout {
    private static let marker = "/.claude/worktrees/"

    /// The checkout a tab working in `cwd` runs in: `<project>/.claude/worktrees/<name>` for a
    /// worktree session, otherwise the project root, even when `cwd` is a subdirectory of it.
    public static func root(forCwd cwd: String, projectPath: String) -> String {
        let prefix = projectPath + marker
        guard cwd.hasPrefix(prefix) else { return projectPath }
        let rest = cwd.dropFirst(prefix.count)
        guard let name = rest.split(separator: "/", omittingEmptySubsequences: true).first else { return projectPath }
        return prefix + name
    }

    /// The worktree's name for a worktree checkout, nil for the project root.
    public static func worktreeName(checkout: String, projectPath: String) -> String? {
        let prefix = projectPath + marker
        guard checkout.hasPrefix(prefix) else { return nil }
        let name = String(checkout.dropFirst(prefix.count))
        return name.isEmpty ? nil : name
    }

    /// The `run.json` governing a checkout: the checkout's own when it has one (a branch that changed
    /// it), otherwise the project root's, so an untracked file still reaches worktrees.
    public static func fileURL(checkout: String, projectPath: String,
                               exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> URL {
        let own = URL(fileURLWithPath: checkout).appendingPathComponent(RunConfigurationFile.relativePath)
        if checkout != projectPath, exists(own.path) { return own }
        return URL(fileURLWithPath: projectPath).appendingPathComponent(RunConfigurationFile.relativePath)
    }

    /// The directory a configuration's command runs in: `directory` relative to the checkout (an
    /// absolute one is taken as written), or the checkout itself.
    public static func workingDirectory(for config: RunConfiguration, checkout: String) -> String {
        guard let dir = config.directory?.trimmingCharacters(in: .whitespaces), !dir.isEmpty, dir != "." else { return checkout }
        if dir.hasPrefix("/") { return dir }
        if dir.hasPrefix("~/") { return FileManager.default.homeDirectoryForCurrentUser.path + dir.dropFirst(1) }
        return URL(fileURLWithPath: checkout).appendingPathComponent(dir).standardizedFileURL.path
    }
}

/// How a run's surface is launched (ADR-122): the user's shell, login and interactive so rc files set
/// the environment builds need (`JAVA_HOME`, `ANDROID_HOME`), running the one command as the
/// surface's own child. The child's exit is the run's end.
///
/// Its exit *code* cannot come from libghostty: on macOS every surface command runs under
/// `/usr/bin/login`, which exits 0 whatever its child did (checked by hand, 2026-09-11), so
/// `show_child_exited` always says 0. A small `/bin/sh` wrapper writes the code to `statusFile`
/// before it exits instead. It traps SIGINT with a no-op handler rather than ignoring it: an ignored
/// signal would be inherited by the command, which could then never be interrupted, while a handler
/// resets to the default across `exec`, so Ctrl-C still stops the command and the wrapper survives
/// long enough to record 130.
public enum RunLaunch {
    /// libghostty runs a surface's `command` through `/bin/sh -c` (under `login`), so this is one
    /// quoted shell line: `sh -c <wrapper> <shell> <command> <statusFile>`.
    public static func surfaceCommand(shell: String, command: String, statusFile: String) -> String {
        let wrapper = #"trap true INT; "$0" -l -i -c "$1"; s=$?; printf %s "$s" > "$2"; exit $s"#
        return ["/bin/sh", "-c", wrapper, shell, command, statusFile].map(ClaudeLaunch.shellQuote).joined(separator: " ")
    }

    /// The code the wrapper recorded; nil when it never got to (killed outright, or the file is gone).
    public static func recordedExitCode(at statusFile: String) -> Int32? {
        guard let text = try? String(contentsOfFile: statusFile, encoding: .utf8) else { return nil }
        return Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// `$SHELL`, falling back to the account's login shell, then zsh.
    public static var userShell: String {
        if let s = ProcessInfo.processInfo.environment["SHELL"], !s.isEmpty { return s }
        if let pw = getpwuid(getuid()), let sh = pw.pointee.pw_shell { let s = String(cString: sh); if !s.isEmpty { return s } }
        return "/bin/zsh"
    }

    /// The child's extra environment: Clinic's marker, the configuration's id, then its own `env`.
    public static func environment(for config: RunConfiguration) -> [String: String] {
        var env = ["CLINIC": "1", "CLINIC_RUN": config.id]
        for (k, v) in config.env ?? [:] { env[k] = v }
        return env
    }
}

/// Where a run stands (ADR-122). Motion carries `running`; the others are outcomes (ADR-096).
public enum RunStatus: Equatable, Sendable {
    case running(since: Date)
    case succeeded(duration: TimeInterval)
    case failed(exitCode: Int32?, duration: TimeInterval)
    case stopped(duration: TimeInterval)

    /// A stop the user asked for is *Stopped* whatever code the process died with (130, 143…).
    public static func finished(exitCode: Int32?, stoppedByUser: Bool, duration: TimeInterval) -> RunStatus {
        if stoppedByUser { return .stopped(duration: duration) }
        if exitCode == 0 { return .succeeded(duration: duration) }
        return .failed(exitCode: exitCode, duration: duration)
    }

    public var isRunning: Bool { if case .running = self { return true } else { return false } }
    public var isFailure: Bool { if case .failed = self { return true } else { return false } }

    /// `0:42`, `12:05`, `1:02:09`: a running clock.
    public static func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        let (h, m, sec) = (s / 3600, (s % 3600) / 60, s % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    /// `38 s`, `2 min 4 s`, `1 h 3 min`: a finished run's length.
    public static func duration(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded()))
        if s < 60 { return "\(s) s" }
        if s < 3600 { return s % 60 == 0 ? "\(s / 60) min" : "\(s / 60) min \(s % 60) s" }
        return (s % 3600) / 60 == 0 ? "\(s / 3600) h" : "\(s / 3600) h \((s % 3600) / 60) min"
    }
}

/// The trust rule (ADR-122): Claude's `run` tool executes a command only after the user has run it
/// from the UI or saved it in the editor. The fingerprint covers everything that decides what runs.
public enum RunTrust {
    public static func fingerprint(_ config: RunConfiguration) -> String {
        let env = (config.env ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\u{1F}")
        let material = [config.command ?? "", normalized(config.directory), env].joined(separator: "\u{1E}")
        return SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// `nil`, empty, `.` and `./` all mean the checkout itself; `a/` is `a`.
    private static func normalized(_ directory: String?) -> String {
        var d = (directory ?? "").trimmingCharacters(in: .whitespaces)
        while d.count > 1, d.hasSuffix("/") { d.removeLast() }
        return d.isEmpty || d == "." ? "." : d
    }

    /// Every shell command a configuration would start, compounds expanded.
    public static func fingerprints(for config: RunConfiguration, in file: RunConfigurationFile) -> [String] {
        file.members(of: config).map(fingerprint)
    }
}

/// The prompts runs hand to Claude (ADR-122).
public enum RunPrompts {
    /// *Set Up with Claude…*: an editable first prompt for a session in the project root.
    public static let setUp = """
    Set up run configurations for this project.

    Read the build: Gradle modules and flavors, Xcode projects and schemes, package.json, Makefiles, \
    scripts, READMEs and any IDE run configurations (.run/, .idea/runConfigurations/, .vscode/tasks.json). \
    Then write .clinic/run.json with one configuration for each thing I would want to launch: each app \
    on each platform, dev servers, useful scripts.

    The file's format:
    {
      "version": 1,
      "default": "<id of the one to select first>",
      "configurations": [
        { "id": "desktop", "name": "Desktop", "icon": "<SF Symbol name>",
          "command": "<one shell command line, run from the project root>",
          "directory": "<optional, relative to the root>", "env": { "OPTIONAL": "value" },
          "device": "<android or ios, only for things that install onto a device>",
          "rerunAfterTurn": false },
        { "id": "dev", "name": "Server + Web", "compound": ["server", "web"] }
      ]
    }

    A command runs in my login shell as the terminal's own process, and it is finished when it \
    exits, so an app that needs installing and launching should do both.

    Icons: `icon` is an SF Symbol name that exists on macOS (`hammer`, `iphone`, `globe`, \
    `testtube.2`, `server.rack`, `ladybug`…). Clinic draws a play glyph for a name it doesn't have, \
    and I can pick another from its symbol browser.

    Devices: give anything that installs onto an Android phone or emulator `"device": "android"`, \
    and anything that runs in the iOS Simulator `"device": "ios"`. Don't boot emulators or pick \
    devices in the command: Clinic lets me choose the device, boots it if it isn't running, and runs \
    the command with ANDROID_SERIAL (which Gradle's install tasks and adb already respect) or \
    SIMULATOR_UDID set. So an Android run is `./gradlew :app:installDebug && adb shell monkey -p \
    <applicationId> 1`, and an iOS run builds with `-destination "id=$SIMULATOR_UDID"`, then runs \
    `xcrun simctl install "$SIMULATOR_UDID" <path to .app>` and `xcrun simctl launch \
    "$SIMULATOR_UDID" <bundle id>`.

    Check that each task or target exists without starting long builds, and don't commit the file.
    """

    /// *Fix with Claude*: the failed command, its exit code and the tail of its output.
    public static func fix(name: String, command: String, exitCode: Int32?, output: String, lines: Int = 200) -> String {
        let tail = tail(output, lines: lines)
        let code = exitCode.map { "exit code \($0)" } ?? "an unknown exit code"
        let count = tail.isEmpty ? 0 : tail.split(separator: "\n", omittingEmptySubsequences: false).count
        let heading = count == 1 ? "The last line of its output:" : count == 0 ? "It printed nothing." : "The last \(count) lines of its output:"
        return """
        The run configuration “\(name)” failed with \(code).

        Command: `\(command)`

        \(heading)
        ```
        \(tail)
        ```

        Find the cause and fix it.
        """
    }

    /// The last `lines` lines, trailing blank lines dropped first (a finished surface pads to the screen).
    public static func tail(_ text: String, lines: Int) -> String {
        var all = text.components(separatedBy: "\n").map { $0.replacingOccurrences(of: "\r", with: "") }
        while let last = all.last, last.trimmingCharacters(in: .whitespaces).isEmpty { all.removeLast() }
        return all.suffix(max(0, lines)).joined(separator: "\n")
    }
}
