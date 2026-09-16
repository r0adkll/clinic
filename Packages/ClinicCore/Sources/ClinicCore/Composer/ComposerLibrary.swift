import Foundation

/// A project's unsent composer as it is kept on disk (ADR-160): what was typed and how the launch was
/// set up. Model and effort are the resolved values the launch would carry, nil meaning the CLI's own.
public struct ComposerDraft: Codable, Sendable, Equatable {
    public var prompt: String
    public var model: String?
    public var effort: String?
    public var worktree: Bool
    public var worktreeName: String
    public var worktreeBase: WorktreeBase?
    public var workItem: WorkItemRef?
    public var updatedAt: Date

    public init(prompt: String = "", model: String? = nil, effort: String? = nil, worktree: Bool = false, worktreeName: String = "",
                worktreeBase: WorktreeBase? = nil, workItem: WorkItemRef? = nil, updatedAt: Date = Date()) {
        self.prompt = prompt; self.model = model; self.effort = effort; self.worktree = worktree
        self.worktreeName = worktreeName; self.worktreeBase = worktreeBase; self.workItem = workItem; self.updatedAt = updatedAt
    }

    /// Nothing a person would miss: no text, no branch name, no task. Picker settings alone are not a
    /// draft — the next composer starts from the project's remembered model and worktree anyway.
    public var isBlank: Bool {
        prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && worktreeName.trimmingCharacters(in: .whitespaces).isEmpty
            && workItem == nil
    }

    /// Compares content, not when it was written, so re-recording an unchanged draft is not a write.
    public static func == (a: ComposerDraft, b: ComposerDraft) -> Bool {
        a.prompt == b.prompt && a.model == b.model && a.effort == b.effort && a.worktree == b.worktree
            && a.worktreeName == b.worktreeName && a.worktreeBase == b.worktreeBase && a.workItem == b.workItem
    }
}

/// A prompt kept to start sessions from again (ADR-160). `projectPath` nil offers it in every project.
public struct SavedPrompt: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var text: String
    /// What its pill says instead of the start of the text (ADR-161). Nil or blank: the text.
    public var title: String?
    public var projectPath: String?
    public var savedAt: Date

    public init(id: UUID = UUID(), text: String, title: String? = nil, projectPath: String?, savedAt: Date = Date()) {
        self.id = id; self.text = text; self.title = title; self.projectPath = projectPath; self.savedAt = savedAt
    }

    /// The title, when it has one worth showing.
    public var displayTitle: String? {
        let t = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return t.isEmpty ? nil : t
    }

    /// Emptied in the editor. Kept while it is being edited, never offered as a pill.
    public var isBlank: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

/// Composer drafts by project path, and saved prompts. Pure; `ComposerLibraryStore` keeps it on disk.
public struct ComposerLibrary: Codable, Sendable, Equatable {
    public var drafts: [String: ComposerDraft] = [:]
    /// Newest first.
    public var savedPrompts: [SavedPrompt] = []

    public init() {}

    // MARK: Drafts

    /// Records a project's draft, or forgets it once it is blank.
    public mutating func setDraft(_ draft: ComposerDraft?, for projectPath: String) {
        guard let draft, !draft.isBlank else { drafts[projectPath] = nil; return }
        if drafts[projectPath] == draft { return }
        drafts[projectPath] = draft
    }

    // MARK: Saved prompts

    /// What a project's composer offers: its own saved prompts, then those for every project, each in
    /// the order the user left them (newest first until they are moved).
    public func savedPrompts(for projectPath: String) -> [SavedPrompt] {
        savedPrompts.filter { $0.projectPath == projectPath } + savedPrompts.filter { $0.projectPath == nil }
    }

    /// The saved prompt a project's composer would offer with this text, if any.
    public func savedPrompt(matching text: String, in projectPath: String) -> SavedPrompt? {
        let key = Self.key(text)
        guard !key.isEmpty else { return nil }
        return savedPrompts(for: projectPath).first { Self.key($0.text) == key }
    }

    /// Saves `text` for one project, or for all when `projectPath` is nil. Text a project already
    /// offers moves that prompt to the front instead of adding a second copy; saving for all projects
    /// takes in every project's copy of it.
    @discardableResult
    public mutating func savePrompt(_ text: String, projectPath: String?, at date: Date = Date()) -> SavedPrompt? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let key = Self.key(trimmed)
        let existing = projectPath.map { savedPrompt(matching: trimmed, in: $0) } ?? savedPrompts.first { Self.key($0.text) == key }
        var prompt = existing ?? SavedPrompt(text: trimmed, projectPath: projectPath, savedAt: date)
        prompt.savedAt = date
        if projectPath == nil {
            prompt.projectPath = nil
            savedPrompts.removeAll { Self.key($0.text) == key }
        } else if let existing {
            savedPrompts.removeAll { $0.id == existing.id }
        }
        savedPrompts.insert(prompt, at: 0)
        return prompt
    }

    public mutating func deletePrompt(_ id: UUID) { savedPrompts.removeAll { $0.id == id } }

    /// Moves a saved prompt between one project and every project.
    public mutating func setScope(of id: UUID, projectPath: String?) {
        guard let i = savedPrompts.firstIndex(where: { $0.id == id }) else { return }
        savedPrompts[i].projectPath = projectPath
    }

    /// Edits a saved prompt in place (ADR-161). Its place in the list and its scope are unchanged.
    public mutating func updatePrompt(_ id: UUID, text: String? = nil, title: String? = nil) {
        guard let i = savedPrompts.firstIndex(where: { $0.id == id }) else { return }
        if let text { savedPrompts[i].text = text }
        if let title { savedPrompts[i].title = title.isEmpty ? nil : title }
    }

    /// Reorders one scope's prompts — a project's, or every project's when `projectPath` is nil — as a
    /// list's `onMove` reports it. The other scopes keep their slots, so each list moves on its own.
    public mutating func movePrompts(in projectPath: String?, fromOffsets source: IndexSet, toOffset destination: Int) {
        let slots = savedPrompts.indices.filter { savedPrompts[$0].projectPath == projectPath }
        let all = slots.map { savedPrompts[$0] }
        // `move(fromOffsets:toOffset:)` is SwiftUI's; this is its meaning, in Foundation.
        let moving = source.filter { $0 < all.count }.map { all[$0] }
        var group = all.enumerated().filter { !source.contains($0.offset) }.map(\.element)
        let insertAt = destination - source.filter { $0 < destination }.count
        group.insert(contentsOf: moving, at: max(0, min(insertAt, group.count)))
        for (slot, prompt) in zip(slots, group) { savedPrompts[slot] = prompt }
    }

    /// Drops prompts whose text was emptied in the editor, once it closes.
    public mutating func removeBlankPrompts() { savedPrompts.removeAll(where: \.isBlank) }

    /// Prompts compare by their words, not their spacing or case.
    static func key(_ text: String) -> String {
        text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    // MARK: Codable

    enum CodingKeys: String, CodingKey { case drafts, savedPrompts }

    /// Tolerant like `ClinicState`: a part that no longer decodes is dropped, not the file.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        drafts = (try? c.decodeIfPresent([String: ComposerDraft].self, forKey: .drafts)) ?? [:]
        savedPrompts = (try? c.decodeIfPresent([SavedPrompt].self, forKey: .savedPrompts)) ?? []
    }
}

/// Atomic, debounced JSON persistence for `ComposerLibrary`, in its own file so a keystroke in the
/// composer never rewrites `state.json` or wakes everything that observes it.
public actor ComposerLibraryStore {
    private let url: URL
    private var current: ComposerLibrary
    private var pendingWrite: Task<Void, Never>?
    private let debounce: Duration
    /// As loaded at init, so the app can seed itself before any actor hop.
    public nonisolated let initialLibrary: ComposerLibrary

    public init(url: URL, debounce: Duration = .milliseconds(500)) {
        self.url = url
        self.debounce = debounce
        let loaded = (try? Self.load(from: url)) ?? ComposerLibrary()
        current = loaded
        initialLibrary = loaded
    }

    public static func defaultURL(appSupport: URL = ClinicPaths.appSupport) -> URL {
        appSupport.appendingPathComponent("Clinic", isDirectory: true).appendingPathComponent("composer.json")
    }

    public var library: ComposerLibrary { current }

    public func replace(with library: ComposerLibrary) {
        guard library != current else { return }
        current = library
        pendingWrite?.cancel()
        pendingWrite = Task { [debounce] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            await self.flush()
        }
    }

    public func flush() {
        pendingWrite?.cancel()
        pendingWrite = nil
        try? Self.write(current, to: url)
    }

    static func load(from url: URL) throws -> ComposerLibrary {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        return try d.decode(ComposerLibrary.self, from: Data(contentsOf: url))
    }

    static func write(_ library: ComposerLibrary, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(library).write(to: url, options: .atomic)
    }
}
