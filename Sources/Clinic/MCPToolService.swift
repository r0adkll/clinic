import AppKit
import os
import ClinicCore

/// Answers the MCP shim's tools/list and tools/call for a session (ADR-056). All handlers run on the main actor.
@MainActor
final class MCPToolService {
    private static let log = Logger(subsystem: "com.r0adkll.clinic", category: "mcp")
    let server: MCPServer
    let configDirectory: URL
    private weak var tabs: TabStore?
    private weak var sessions: SessionStore?
    private weak var history: NotificationStore?
    private weak var notifications: NotificationService?
    private weak var prs: PRStore?

    init(appSupport: URL = ClinicPaths.appSupport) {
        server = MCPServer(socketPath: MCPServer.defaultSocketPath(appSupport: appSupport))
        configDirectory = appSupport.appendingPathComponent("Clinic/mcp", isDirectory: true)
    }

    func start(tabs: TabStore, sessions: SessionStore, history: NotificationStore, notifications: NotificationService, prs: PRStore) {
        self.tabs = tabs; self.sessions = sessions; self.history = history; self.notifications = notifications; self.prs = prs
        server.handler = { [weak self] req in
            await MainActor.run { MCPServer.Response(self?.handle(req) ?? ["error": ["code": -32603, "message": "Clinic is shutting down"]]) }
        }
        do { try server.start(); Self.log.info("mcp server listening at \(self.server.socketPath, privacy: .public)") }
        catch { Self.log.error("mcp server failed: \(error, privacy: .public)") }
    }

    func stop() { server.stop() }

    static func isEnabled(_ spec: MCPToolSpec) -> Bool {
        UserDefaults.standard.object(forKey: "ClinicTool_" + spec.name) as? Bool ?? spec.defaultEnabled
    }

    var enabledTools: [MCPToolSpec] { MCPToolSpec.all.filter(Self.isEnabled) }

    /// Writes the per-session config file and returns its path (ADR-056).
    func configPath(for id: SessionID) -> String? {
        do {
            try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
            let url = configDirectory.appendingPathComponent("\(id.rawValue).json")
            try MCPConfig.json(helperPath: HookService.helperPath, socketPath: server.socketPath, sessionId: id).write(to: url, options: .atomic)
            return url.path
        } catch {
            Self.log.error("mcp config: \(error, privacy: .public)")
            return nil
        }
    }

    // MARK: Dispatch

    private func handle(_ req: MCPServer.Request) -> [String: Any] {
        switch req.method {
        case "tools/list":
            Self.log.info("tools/list from session \(req.sessionId.rawValue, privacy: .public)")
            return ["result": ["tools": enabledTools.map(\.listEntry)]]
        case "tools/call":
            guard let name = req.toolName, let spec = MCPToolSpec.all.first(where: { $0.name == name }) else {
                return MCPToolSpec.textResult("Unknown tool", isError: true)
            }
            guard Self.isEnabled(spec) else { return MCPToolSpec.textResult("The user has disabled \(name) in Clinic.", isError: true) }
            guard let tab = tabs?.tab(for: req.sessionId) else { return MCPToolSpec.textResult("Session is not open in Clinic.", isError: true) }
            Self.log.info("tool \(name, privacy: .public) for \(req.sessionId.rawValue, privacy: .public)")
            return call(name, args: req.arguments, tab: tab, sessionId: req.sessionId)
        default:
            return ["error": ["code": -32601, "message": "Unsupported method \(req.method)"]]
        }
    }

    private func call(_ name: String, args: [String: Any], tab: Tab, sessionId: SessionID) -> [String: Any] {
        switch name {
        case "set_session_title":
            let title = (args["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return MCPToolSpec.textResult("title is required", isError: true) }
            sessions?.rename(sessionId, to: title)
            tab.title = title
            return MCPToolSpec.textResult("Title set to “\(title)”.")

        case "notify_user":
            let message = args["message"] as? String ?? ""
            let title = args["title"] as? String ?? tab.title
            let lookingAtIt = tabs?.isFrontAndSelected(tab) ?? false
            tabs?.notify(tab, sessionId: sessionId, title: title, body: message, kind: .needsInput)
            return MCPToolSpec.textResult(lookingAtIt ? "The user is looking at this session; the message was added to their history without a notification." : "Notification delivered.")

        case "show_image":
            let path = (args["path"] as? String ?? "")
            guard path.hasPrefix("/"), FileManager.default.fileExists(atPath: path), NSImage(contentsOfFile: path) != nil else {
                return MCPToolSpec.textResult("Not a readable image file: \(path)", isError: true)
            }
            let caption = args["caption"] as? String
            sessions?.update { s in s.attachments[sessionId, default: []].append(ClinicState.Attachment(path: path, caption: caption)) }
            tab.rightPane = .attachments
            return MCPToolSpec.textResult("Image shown in Clinic's attachments panel.")

        case "read_terminal":
            let lines = max(1, min(500, args["lines"] as? Int ?? 60))
            guard let text = tab.surface.visibleText else { return MCPToolSpec.textResult("Terminal text unavailable.", isError: true) }
            let tail = text.split(separator: "\n", omittingEmptySubsequences: false).suffix(lines).joined(separator: "\n")
            return MCPToolSpec.textResult(tail)

        case "run_in_terminal":
            let command = (args["command"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !command.isEmpty else { return MCPToolSpec.textResult("command is required", isError: true) }
            if tab.panelSurface == nil || !tab.panelVisible { tabs?.togglePanel(tab) }
            guard let panel = tab.panelSurface else { return MCPToolSpec.textResult("Could not open the shell panel.", isError: true) }
            panel.sendLine(command)
            return MCPToolSpec.textResult("Command typed into the user's shell panel: \(command)")

        case "attach_pr":
            guard let urlString = args["url"] as? String, let url = URL(string: urlString), let ref = PullRequestRef(url: url) else {
                return MCPToolSpec.textResult("url must be a GitHub pull request URL", isError: true)
            }
            sessions?.attachPullRequest(ref, to: sessionId)
            prs?.ensureLoaded([ref])
            return MCPToolSpec.textResult("Attached PR #\(ref.number).")

        case "start_session":
            let prompt = (args["prompt"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !prompt.isEmpty else { return MCPToolSpec.textResult("prompt is required", isError: true) }
            let directory = (args["directory"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? tab.pwd ?? tab.projectPath
            let model = args["model"] as? String
            let keep = tabs?.selectedTabId
            tabs?.newSession(projectPath: directory, model: model, worktree: false, prompt: prompt)
            if let keep { tabs?.selectedTabId = keep }
            return MCPToolSpec.textResult("Started a sibling session in \(directory) as a background tab.")

        default:
            return MCPToolSpec.textResult("Unknown tool \(name)", isError: true)
        }
    }
}
