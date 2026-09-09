import Foundation
import Observation
import ClinicCore
import os

/// State behind the MCP Servers screen (ADR-093). One instance for the app, so the list and the
/// project you were looking at survive switching to a session and back.
///
/// Nothing here writes `~/.claude.json` or a `.mcp.json`: reads come from `MCPServersConfig`,
/// changes are argv handed to `MCPService`, and each one is confirmed by the user first.
@MainActor
@Observable
final class MCPServersModel {
    /// A mutation waiting on the confirmation sheet.
    ///
    /// `operations` is a list rather than one command because editing a server is *two* commands —
    /// `claude mcp add` refuses to overwrite an existing name, so a change is remove-then-add. Both
    /// are shown before either runs.
    struct Pending: Identifiable {
        let id = UUID()
        var operations: [MCPService.Operation]
        var title: String
        var detail: String
        /// Past tense, for the footer once it has run.
        var success: String
        var isDestructive = false
        /// cwd for the commands: `--scope local` and `--scope project` act on the project the
        /// process is standing in.
        var projectPath: String?
        /// Puts the server back if a two-step edit removes it and then fails to re-add it.
        var rollback: MCPService.Operation?
        var commands: [String] { operations.map { MCPService.displayCommand($0) } }
    }

    private let service = MCPService()
    private let log = Logger(subsystem: "com.r0adkll.clinic", category: "mcp")

    /// The project whose two local scopes are shown beside the global ones. nil = none picked yet.
    var projectPath: String?
    var showAllProjects = false
    var query = ""
    var selectedId: String?
    /// The add/edit form, presented as a sheet. nil when the screen is just a list.
    var draft: MCPServerDraft?

    private(set) var entries: [MCPServerEntry] = []
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    /// nil until the first check; false means no `claude` on PATH.
    private(set) var cliAvailable: Bool?
    /// Live status per entry id, filled in on demand — `claude mcp get` is a health check, not a read.
    private(set) var health: [String: MCPHealth] = [:]
    private(set) var checkingHealth: Set<String> = []

    var pending: Pending?
    private(set) var runningCommand: String?
    var runError: String?
    var lastSucceeded: String?

    // MARK: Reading

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false; hasLoaded = true }
        let all = showAllProjects
        let path = projectPath
        entries = await Task.detached {
            all ? MCPServersConfig.load() : MCPServersConfig.load(projectPath: path)
        }.value
        if let selectedId, !entries.contains(where: { $0.id == selectedId }) { self.selectedId = nil }
        if cliAvailable == nil { cliAvailable = await service.isAvailable() }
    }

    /// Loads once per app run; the sidebar row should feel instant on later visits.
    func loadIfNeeded(defaultProject: String?) {
        if projectPath == nil { projectPath = defaultProject }
        guard !hasLoaded, !isLoading else { return }
        Task { await refresh() }
    }

    func selectProject(_ path: String?) {
        guard path != projectPath else { return }
        projectPath = path
        Task { await refresh() }
    }

    func setShowAllProjects(_ on: Bool) {
        guard on != showAllProjects else { return }
        showAllProjects = on
        Task { await refresh() }
    }

    // MARK: Derived lists

    func entries(in scope: MCPScope, projectPath path: String? = nil) -> [MCPServerEntry] {
        entries.filter { $0.scope == scope && (path == nil || $0.projectPath == path) && $0.matches(query) }
    }

    /// Projects with servers, for the "Show all projects" listing.
    var allProjectPaths: [String] {
        Array(Set(entries.compactMap(\.projectPath))).sorted()
    }

    var selected: MCPServerEntry? { selectedId.flatMap { id in entries.first { $0.id == id } } }

    /// Names already taken in a scope — checked before running, because `add` fails on a collision.
    func takenNames(in scope: MCPScope, projectPath path: String?) -> Set<String> {
        Set(entries.filter { $0.scope == scope && $0.projectPath == path }.map(\.name))
    }

    // MARK: Health

    func checkHealth(_ entry: MCPServerEntry, force: Bool = false) {
        guard cliAvailable != false else { return }
        guard force || health[entry.id] == nil, !checkingHealth.contains(entry.id) else { return }
        checkingHealth.insert(entry.id)
        Task {
            let h = await service.health(name: entry.name, in: entry.projectPath)
            checkingHealth.remove(entry.id)
            health[entry.id] = h
        }
    }

    // MARK: Composing a form

    func beginAdd(mode: MCPServerDraft.Mode = .form) {
        let d = MCPServerDraft(projectPath: projectPath)
        d.mode = mode
        draft = d
    }

    /// Edit re-reads the definition from disk — the list entry deliberately carries no secret values.
    func beginEdit(_ entry: MCPServerEntry) {
        guard let definition = MCPServersConfig.definition(name: entry.name, scope: entry.scope, projectPath: entry.projectPath) else {
            runError = "Could not read \(entry.name) from \(MCPServersConfig.fileURL(for: entry).path)."
            return
        }
        draft = MCPServerDraft(editing: entry, definition: definition)
    }

    func beginDuplicate(_ entry: MCPServerEntry) {
        guard let definition = MCPServersConfig.definition(name: entry.name, scope: entry.scope, projectPath: entry.projectPath) else {
            runError = "Could not read \(entry.name) from \(MCPServersConfig.fileURL(for: entry).path)."
            return
        }
        let d = MCPServerDraft(editing: entry, definition: definition)
        d.editing = nil
        d.name = entry.name + "-copy"
        draft = d
    }

    // MARK: Mutations — each one goes through the confirmation sheet

    /// Submits the form: one `add-json` for a new server, remove-then-add for a change.
    func submit(_ draft: MCPServerDraft) {
        guard let scope = draft.scope, let definition = draft.definition else { return }
        let path = scope.isProjectScoped ? draft.projectPath : nil
        let add = MCPService.Operation.add(name: draft.trimmedName, definition: definition, scope: scope)

        guard let original = draft.editing else {
            pending = Pending(operations: [add],
                              title: "Add \(draft.trimmedName)?",
                              detail: "\(scope.detail) Sessions you start afterwards will have it.",
                              success: "Added \(draft.trimmedName)",
                              projectPath: path)
            self.draft = nil
            return
        }

        // `claude mcp add` refuses to overwrite, so a change is a remove followed by an add — and if
        // the add fails the server has already gone, hence the rollback (ADR-093).
        let remove = MCPService.Operation.remove(name: original.name, scope: original.scope)
        let restore = MCPServersConfig.definition(name: original.name, scope: original.scope, projectPath: original.projectPath)
            .map { MCPService.Operation.add(name: original.name, definition: $0, scope: original.scope) }
        pending = Pending(operations: [remove, add],
                          title: "Save changes to \(original.name)?",
                          detail: "The Claude CLI has no in-place edit, so Clinic removes \(original.name) and adds it back with the new definition. If the second command fails, Clinic restores the original.",
                          success: "Updated \(draft.trimmedName)",
                          projectPath: path ?? original.projectPath,
                          rollback: restore)
        self.draft = nil
    }

    func remove(_ entry: MCPServerEntry) {
        pending = Pending(operations: [.remove(name: entry.name, scope: entry.scope)],
                          title: "Remove \(entry.name)?",
                          detail: entry.scope == .project
                              ? "Deletes it from \(MCPServersConfig.projectFileURL(for: entry.projectPath ?? "").path), which is committed to the repository."
                              : "Deletes it from ~/.claude.json. Sessions already running keep it until they end.",
                          success: "Removed \(entry.name)",
                          isDestructive: true,
                          projectPath: entry.projectPath)
    }

    func addFromSnippet(_ snippet: MCPSnippet, name: String, scope: MCPScope, projectPath path: String?) {
        pending = Pending(operations: [.add(name: name, definition: snippet.definition, scope: scope)],
                          title: "Add \(name)?",
                          detail: "\(scope.detail) Sessions you start afterwards will have it.",
                          success: "Added \(name)",
                          projectPath: scope.isProjectScoped ? path : nil)
    }

    func importFromClaudeDesktop() {
        pending = Pending(operations: [.importFromClaudeDesktop(scope: .user)],
                          title: "Import from Claude Desktop?",
                          detail: "Copies the MCP servers configured in Claude Desktop into your user scope. Existing servers with the same name are left alone.",
                          success: "Imported from Claude Desktop")
    }

    func logout(_ entry: MCPServerEntry) {
        pending = Pending(operations: [.logout(name: entry.name)],
                          title: "Log out of \(entry.name)?",
                          detail: "Clears the stored OAuth credentials. The server stays configured; sessions will ask you to log in again.",
                          success: "Logged out of \(entry.name)",
                          isDestructive: true,
                          projectPath: entry.projectPath)
    }

    func resetProjectChoices(for path: String) {
        pending = Pending(operations: [.resetProjectChoices],
                          title: "Reset approval choices?",
                          detail: "Clears every approved and rejected .mcp.json choice for this project at once — there is no per-server switch. The next session in \((path as NSString).lastPathComponent) will ask about each server again.",
                          success: "Reset approval choices",
                          isDestructive: true,
                          projectPath: path)
    }

    /// Runs the confirmed commands in order, rolling back a half-finished edit, then re-reads from disk.
    func runPending() {
        guard let pending else { return }
        self.pending = nil
        runError = nil
        lastSucceeded = nil
        Task {
            defer { runningCommand = nil }
            var completed = 0
            for op in pending.operations {
                runningCommand = MCPService.displayCommand(op)
                do {
                    try await service.perform(op, in: pending.projectPath)
                    completed += 1
                } catch {
                    let message = (error as? MCPError)?.message ?? error.localizedDescription
                    log.error("\(MCPService.displayCommand(op), privacy: .public) failed: \(message, privacy: .public)")
                    runError = await rollbackMessage(pending, failed: message, completed: completed)
                    await refresh()
                    return
                }
            }
            lastSucceeded = pending.success
            // The commands just changed what these servers are, so every cached verdict is stale.
            health = [:]
            await refresh()
            if let selected { checkHealth(selected, force: true) }
        }
    }

    /// A failed second step means the server is already gone; put it back and say what happened either way.
    /// The two decisions — whether to restore at all, and what to say — are `MCPEditRecovery`'s, so
    /// they are unit-tested rather than only reachable through the UI.
    private func rollbackMessage(_ pending: Pending, failed: String, completed: Int) async -> String {
        guard MCPEditRecovery.shouldRestore(completedSteps: completed, hasSnapshot: pending.rollback != nil),
              let rollback = pending.rollback else {
            return MCPEditRecovery.message(failure: failed, outcome: .nothingToUndo)
        }
        do {
            runningCommand = MCPService.displayCommand(rollback)
            try await service.perform(rollback, in: pending.projectPath)
            return MCPEditRecovery.message(failure: failed, outcome: .restored)
        } catch {
            let second = (error as? MCPError)?.message ?? error.localizedDescription
            return MCPEditRecovery.message(failure: failed,
                                           outcome: .restoreFailed(reason: second, command: MCPService.displayCommand(rollback)))
        }
    }
}

/// The add/edit form's state. A class so the sheet can bind to its fields directly.
///
/// `scope` starts nil on purpose: the CLI's default is `local`, which is one of the two scopes people
/// confuse, so Clinic makes the user say which one rather than inheriting it silently (ADR-093).
@MainActor
@Observable
final class MCPServerDraft: Identifiable {
    /// Which door the form is showing: fields, or the JSON an MCP server's README told you to paste.
    enum Mode: String, CaseIterable, Identifiable { case form, paste
        var id: String { rawValue }
        var label: String { self == .form ? "Form" : "Paste JSON" }
    }

    let id = UUID()
    var mode: Mode = .form
    /// nil for a new server; the entry being replaced for an edit.
    var editing: MCPServerEntry?
    var name = ""
    var scope: MCPScope?
    var projectPath: String?
    var transport = "stdio"
    var command = ""
    /// One argument per line — arguments contain spaces often enough that splitting on them lies.
    var argumentsText = ""
    var url = ""
    var env: [MCPKeyValue] = []
    var headers: [MCPKeyValue] = []
    /// The Paste JSON tab's text, kept so a failed parse can be corrected rather than retyped.
    var snippetText = ""

    init(projectPath: String?) {
        self.projectPath = projectPath
    }

    init(editing entry: MCPServerEntry, definition: MCPServerDefinition) {
        self.editing = entry
        self.name = entry.name
        self.scope = entry.scope
        self.projectPath = entry.projectPath
        self.transport = definition.type
        self.command = definition.command ?? ""
        self.argumentsText = definition.args.joined(separator: "\n")
        self.url = definition.url ?? ""
        self.env = definition.env.keys.sorted().map { MCPKeyValue(key: $0, value: definition.env[$0] ?? "") }
        self.headers = definition.headers.keys.sorted().map { MCPKeyValue(key: $0, value: definition.headers[$0] ?? "") }
    }

    var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }
    var isStdio: Bool { transport == "stdio" }

    var arguments: [String] {
        argumentsText.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// nil while the form is not yet valid.
    var definition: MCPServerDefinition? {
        guard MCPServersConfig.isValidName(trimmedName), scope != nil else { return nil }
        if isStdio {
            let c = command.trimmingCharacters(in: .whitespaces)
            guard !c.isEmpty else { return nil }
            return MCPServerDefinition(type: "stdio", command: c, args: arguments, env: MCPKeyValue.dictionary(env))
        }
        let u = url.trimmingCharacters(in: .whitespaces)
        guard let parsed = URL(string: u), parsed.scheme == "http" || parsed.scheme == "https" else { return nil }
        return MCPServerDefinition(type: transport, url: u, headers: MCPKeyValue.dictionary(headers))
    }

    /// Fills the form from a pasted snippet, keeping the scope the user already chose.
    func apply(_ snippet: MCPSnippet) {
        if !snippet.name.isEmpty { name = snippet.name }
        let d = snippet.definition
        transport = d.type
        command = d.command ?? ""
        argumentsText = d.args.joined(separator: "\n")
        url = d.url ?? ""
        env = d.env.keys.sorted().map { MCPKeyValue(key: $0, value: d.env[$0] ?? "") }
        headers = d.headers.keys.sorted().map { MCPKeyValue(key: $0, value: d.headers[$0] ?? "") }
    }
}

/// One env var or header row in the form.
struct MCPKeyValue: Identifiable, Hashable {
    var id = UUID()
    var key = ""
    var value = ""

    static func dictionary(_ pairs: [MCPKeyValue]) -> [String: String] {
        var out: [String: String] = [:]
        for p in pairs {
            let k = p.key.trimmingCharacters(in: .whitespaces)
            guard !k.isEmpty else { continue }
            out[k] = p.value
        }
        return out
    }
}
