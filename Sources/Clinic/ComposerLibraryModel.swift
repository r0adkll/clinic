import Foundation
import Observation
import ClinicCore

/// Persisted composer drafts and saved prompts (ADR-160), mirrored out of `ComposerLibraryStore` so
/// SwiftUI reads them without awaiting. Drafts and saved prompts are separate properties so typing
/// in the composer doesn't redraw what only reads the saved prompts.
@MainActor
@Observable
final class ComposerLibraryModel {
    private(set) var drafts: [String: ComposerDraft]
    private(set) var savedPrompts: [SavedPrompt]
    private let store: ComposerLibraryStore
    @ObservationIgnored private var sync: Task<Void, Never>?

    init(url: URL = ComposerLibraryStore.defaultURL()) {
        store = ComposerLibraryStore(url: url)
        drafts = store.initialLibrary.drafts
        savedPrompts = store.initialLibrary.savedPrompts
    }

    private var library: ComposerLibrary {
        var lib = ComposerLibrary()
        lib.drafts = drafts
        lib.savedPrompts = savedPrompts
        return lib
    }

    private func mutate(_ change: (inout ComposerLibrary) -> Void) {
        var lib = library
        change(&lib)
        guard lib != library else { return }
        if lib.drafts != drafts { drafts = lib.drafts }
        if lib.savedPrompts != savedPrompts { savedPrompts = lib.savedPrompts }
        // Chained, so a later snapshot never reaches the store before an earlier one.
        sync = Task { [store, previous = sync, lib] in
            await previous?.value
            await store.replace(with: lib)
        }
    }

    func flush() async {
        await sync?.value
        await store.flush()
    }

    // MARK: Drafts

    func setDraft(_ draft: ComposerDraft?, for projectPath: String) {
        mutate { $0.setDraft(draft, for: projectPath) }
    }

    // MARK: Saved prompts

    func savedPrompts(for projectPath: String) -> [SavedPrompt] { library.savedPrompts(for: projectPath) }
    func savedPrompt(matching text: String, in projectPath: String) -> SavedPrompt? { library.savedPrompt(matching: text, in: projectPath) }
    func savePrompt(_ text: String, projectPath: String?) { mutate { $0.savePrompt(text, projectPath: projectPath) } }
    func deletePrompt(_ id: UUID) { mutate { $0.deletePrompt(id) } }
    func setScope(of id: UUID, projectPath: String?) { mutate { $0.setScope(of: id, projectPath: projectPath) } }
}

extension NewSessionDraft {
    /// What of this composer is kept on disk.
    var persisted: ComposerDraft {
        ComposerDraft(prompt: prompt, model: resolvedModel,
                      effort: resolvedEffort, worktree: worktree, worktreeName: worktreeName, worktreeBase: worktreeBase, workItem: workItem)
    }

    /// A composer restored from disk; the project's defaults fill in what the draft didn't record.
    convenience init(projectPath: String, restoring saved: ComposerDraft, defaultBase: WorktreeBase) {
        self.init(projectPath: projectPath, model: saved.model, worktree: saved.worktree, worktreeBase: saved.worktreeBase ?? defaultBase)
        prompt = saved.prompt
        if let effort = saved.effort { self.effort = effort }
        worktreeName = saved.worktreeName
        workItem = saved.workItem
    }
}
