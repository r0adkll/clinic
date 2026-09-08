import Foundation

/// Generates a project icon with headless `claude -p` and writes it to `<project>/.clinic/icon.svg` (ADR-076).
public enum ProjectIconGenerator {
    /// Path of the generated file, relative to the project. One of ADR-050's lookup candidates.
    public static let relativePath = ".clinic/icon.svg"
    public static let model = "sonnet"
    /// A run this long has gone wrong; the sheet can cancel earlier.
    public static let timeout: TimeInterval = 180
    /// Anything larger is not an icon.
    static let sizeLimit = 64 * 1024

    public enum Failure: Error, Sendable, Equatable {
        case launchFailed(String)
        case cancelled
        case timedOut
        case cli(String)
        case noSVG(String)
        case unsafeSVG(String)

        public var message: String {
            switch self {
            case .launchFailed(let s): "Could not run claude: \(s)"
            case .cancelled: "Cancelled."
            case .timedOut: "claude did not answer within \(Int(ProjectIconGenerator.timeout)) seconds."
            case .cli(let s): s.isEmpty ? "claude exited with an error." : s
            case .noSVG: "claude did not return an SVG."
            case .unsafeSVG(let why): "The generated SVG was rejected: \(why)."
            }
        }
    }

    // MARK: - Command

    public static func prompt(hint: String?) -> String {
        var p = """
        Design a project icon for this repository. Read README.md, CLAUDE.md or any package manifest in the \
        working directory to learn what the project is, then output ONE self-contained SVG icon and nothing else.

        Rules: viewBox="0 0 64 64"; a filled rounded-square badge (rx 14) covering the whole canvas as the \
        background; one simple flat symbol on top, still legible at 22x22 points; at most four colours, chosen \
        to read on both light and dark window backgrounds; no text unless a single monogram letter; no <script>, \
        <foreignObject>, <image>, href/xlink:href, DOCTYPE or entity declarations, no CSS classes and no comments.
        """
        if let hint = hint?.trimmingCharacters(in: .whitespacesAndNewlines), !hint.isEmpty {
            p += "\n\nThe user asks for: \(hint)"
        }
        p += "\n\nReply with the raw <svg> element only: no prose, no code fence."
        return p
    }

    /// The prompt goes first so a later variadic option cannot swallow it (same trap as `ClaudeLaunch.arguments`).
    public static func arguments(prompt: String, model: String = model) -> [String] {
        [prompt, "-p",
         "--model", model,
         "--allowedTools", "Read,Glob,Grep",
         "--permission-mode", "dontAsk",
         "--no-session-persistence",
         "--strict-mcp-config"]
    }

    // MARK: - Parsing and validation

    /// Pulls the `<svg>…</svg>` element out of a reply, fenced or bare.
    public static func extractSVG(from output: String) -> String? {
        guard let start = output.range(of: "<svg", options: .caseInsensitive),
              let end = output.range(of: "</svg>", options: [.caseInsensitive, .backwards], range: start.lowerBound..<output.endIndex)
        else { return nil }
        let svg = String(output[start.lowerBound..<end.upperBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        return svg.isEmpty ? nil : svg
    }

    /// Rejects anything that is more than a drawing. Returns nil when the SVG is acceptable.
    public static func rejectionReason(for svg: String) -> String? {
        if svg.utf8.count > sizeLimit { return "it is larger than 64 KB" }
        let lower = svg.lowercased()
        let banned: [(String, String)] = [
            ("<script", "it contains a script"),
            ("<foreignobject", "it contains a foreignObject"),
            ("<image", "it embeds an image"),
            ("<!doctype", "it declares a DOCTYPE"),
            ("<!entity", "it declares an entity"),
            ("href", "it links to something outside the file"),
            ("javascript:", "it contains a javascript: URL"),
        ]
        for (needle, why) in banned where lower.contains(needle) { return why }
        // Any event handler attribute (onload=, onclick=, …).
        if lower.range(of: "\\son[a-z]+\\s*=", options: .regularExpression) != nil { return "it carries an event handler" }
        return nil
    }

    /// `extractSVG` + `rejectionReason` + namespace repair, as the one call the UI needs.
    public static func svg(fromCLIOutput output: String) throws -> String {
        guard let svg = extractSVG(from: output) else { throw Failure.noSVG(output) }
        if let why = rejectionReason(for: svg) { throw Failure.unsafeSVG(why) }
        return withNamespace(svg)
    }

    /// AppKit renders a namespace-less SVG, but a file on disk should still be valid SVG for everything else.
    static func withNamespace(_ svg: String) -> String {
        guard !svg.contains("xmlns=") else { return svg }
        return svg.replacingOccurrences(of: "<svg", with: "<svg xmlns=\"http://www.w3.org/2000/svg\"",
                                        options: [.caseInsensitive, .anchored])
    }

    // MARK: - Files

    public static func iconURL(projectPath: String) -> URL {
        URL(fileURLWithPath: projectPath, isDirectory: true).appendingPathComponent(relativePath)
    }

    public static func hasGeneratedIcon(projectPath: String) -> Bool {
        FileManager.default.fileExists(atPath: iconURL(projectPath: projectPath).path)
    }

    /// Writes `.clinic/icon.svg`, creating `.clinic/` if needed. Nothing else in the repo is touched.
    @discardableResult
    public static func save(_ svg: String, projectPath: String) throws -> URL {
        let url = iconURL(projectPath: projectPath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(svg.utf8).write(to: url, options: .atomic)
        return url
    }

    /// Removes the generated icon (leaves `.clinic/` in place; it is Clinic's namespace).
    public static func removeGeneratedIcon(projectPath: String) throws {
        let url = iconURL(projectPath: projectPath)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    // MARK: - Running

    /// Runs headless `claude` in the project directory and returns the validated SVG source.
    public static func generate(projectPath: String, hint: String? = nil, model: String = model,
                                executable: String = "claude") async throws -> String {
        let argv = [executable] + arguments(prompt: prompt(hint: hint), model: model)
        let output = try await run(argv, cwd: projectPath)
        return try svg(fromCLIOutput: output)
    }

    static func run(_ argv: [String], cwd: String) async throws -> String {
        let box = ProcessBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    let p = Process()
                    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                    p.arguments = argv
                    p.currentDirectoryURL = URL(fileURLWithPath: cwd, isDirectory: true)
                    var env = ProcessEnvironment.withToolPaths()
                    // Never inherit the session that launched Clinic; this run is its own thing.
                    for key in env.keys where key == "CLAUDECODE" || key.hasPrefix("CLAUDE_CODE_") || key == "CLAUDE_PID" || key == "CLAUDE_EFFORT" { env[key] = nil }
                    env["NO_COLOR"] = "1"
                    p.environment = env
                    let out = Pipe(), err = Pipe()
                    p.standardOutput = out
                    p.standardError = err
                    p.standardInput = FileHandle.nullDevice
                    do { try p.run() } catch {
                        cont.resume(throwing: Failure.launchFailed(error.localizedDescription)); return
                    }
                    if box.adopt(p) == false { p.terminate(); cont.resume(throwing: Failure.cancelled); return }

                    let deadline = DispatchWorkItem { box.expire() }
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)

                    // Drain both pipes concurrently so a chatty stderr cannot deadlock stdout.
                    let group = DispatchGroup()
                    var stdout = Data(), stderr = Data()
                    for (pipe, sink) in [(out, { stdout = $0 }), (err, { stderr = $0 })] as [(Pipe, (Data) -> Void)] {
                        group.enter()
                        DispatchQueue.global(qos: .userInitiated).async { sink(pipe.fileHandleForReading.readDataToEndOfFile()); group.leave() }
                    }
                    p.waitUntilExit()
                    group.wait()
                    deadline.cancel()

                    switch box.finish() {
                    case .cancelled: cont.resume(throwing: Failure.cancelled)
                    case .timedOut: cont.resume(throwing: Failure.timedOut)
                    case .ran:
                        if p.terminationStatus == 0 {
                            cont.resume(returning: String(decoding: stdout, as: UTF8.self))
                        } else {
                            let text = String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                            cont.resume(throwing: Failure.cli(text.isEmpty ? String(decoding: stdout, as: UTF8.self) : text))
                        }
                    }
                }
            }
        } onCancel: {
            box.cancel()
        }
    }
}

/// Holds the running process so cancellation and the timeout can kill it from another thread.
final class ProcessBox: @unchecked Sendable {
    enum Outcome { case ran, cancelled, timedOut }
    private let lock = NSLock()
    private var process: Process?
    private var outcome: Outcome = .ran
    private var settled = false

    /// Returns false when the task was already cancelled before the process started.
    func adopt(_ p: Process) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if settled { return false }
        process = p
        return true
    }

    func cancel() { kill(.cancelled) }
    func expire() { kill(.timedOut) }

    private func kill(_ reason: Outcome) {
        lock.lock()
        guard !settled else { lock.unlock(); return }
        settled = true
        outcome = reason
        let p = process
        lock.unlock()
        if let p, p.isRunning { p.terminate() }
    }

    func finish() -> Outcome {
        lock.lock(); defer { lock.unlock() }
        settled = true
        return outcome
    }
}
