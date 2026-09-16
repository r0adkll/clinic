import Foundation
import Testing
@testable import ClinicCore

@Suite struct ComposerLibraryTests {
    @Test func blankDraftsAreForgotten() {
        var lib = ComposerLibrary()
        lib.setDraft(ComposerDraft(prompt: "fix the sidebar"), for: "/repo")
        #expect(lib.drafts["/repo"]?.prompt == "fix the sidebar")
        // Settings alone are not worth keeping.
        lib.setDraft(ComposerDraft(prompt: "  \n", model: "opus", effort: "high", worktree: true), for: "/repo")
        #expect(lib.drafts["/repo"] == nil)
        lib.setDraft(ComposerDraft(worktreeName: "spike"), for: "/repo")
        #expect(lib.drafts["/repo"] != nil)
        lib.setDraft(nil, for: "/repo")
        #expect(lib.drafts.isEmpty)
    }

    @Test func rerecordingAnUnchangedDraftKeepsItsDate() {
        var lib = ComposerLibrary()
        let first = Date(timeIntervalSince1970: 100)
        lib.setDraft(ComposerDraft(prompt: "x", updatedAt: first), for: "/repo")
        lib.setDraft(ComposerDraft(prompt: "x", updatedAt: Date(timeIntervalSince1970: 200)), for: "/repo")
        #expect(lib.drafts["/repo"]?.updatedAt == first)
    }

    @Test func projectPromptsComeBeforeGlobalOnes() {
        var lib = ComposerLibrary()
        lib.savePrompt("review the open PR", projectPath: nil)
        lib.savePrompt("run the smoke tests", projectPath: "/repo")
        lib.savePrompt("elsewhere", projectPath: "/other")
        #expect(lib.savedPrompts(for: "/repo").map(\.text) == ["run the smoke tests", "review the open PR"])
        #expect(lib.savedPrompts(for: "/other").map(\.text) == ["elsewhere", "review the open PR"])
    }

    @Test func savingTheSameTextMovesItToTheFront() {
        var lib = ComposerLibrary()
        let a = lib.savePrompt("Update  the README", projectPath: "/repo")
        lib.savePrompt("something else", projectPath: "/repo")
        let again = lib.savePrompt("update the readme\n", projectPath: "/repo")
        #expect(again?.id == a?.id)
        #expect(lib.savedPrompts.map(\.text) == ["Update  the README", "something else"])
        #expect(lib.savedPrompt(matching: "UPDATE the readme", in: "/repo")?.id == a?.id)
        #expect(lib.savePrompt("   ", projectPath: "/repo") == nil)
    }

    @Test func savingForAllProjectsTakesInProjectCopies() {
        var lib = ComposerLibrary()
        lib.savePrompt("bump deps", projectPath: "/a")
        lib.savePrompt("bump deps", projectPath: "/b")
        let global = lib.savePrompt("Bump deps", projectPath: nil)
        #expect(lib.savedPrompts.count == 1)
        #expect(global?.projectPath == nil)
        // A project that already offers the global prompt doesn't get its own copy.
        lib.savePrompt("bump deps", projectPath: "/a")
        #expect(lib.savedPrompts.count == 1)
    }

    @Test func scopeAndDelete() throws {
        var lib = ComposerLibrary()
        let saved = lib.savePrompt("x", projectPath: "/repo")
        let p = try #require(saved)
        lib.setScope(of: p.id, projectPath: nil)
        #expect(lib.savedPrompts(for: "/other").count == 1)
        lib.deletePrompt(p.id)
        #expect(lib.savedPrompts.isEmpty)
    }

    @Test func roundTripsAndToleratesBadParts() throws {
        var lib = ComposerLibrary()
        lib.setDraft(ComposerDraft(prompt: "p", model: "opus", worktree: true, worktreeName: "n", worktreeBase: .branch("develop")), for: "/repo")
        lib.savePrompt("s", projectPath: nil)
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        let back = try d.decode(ComposerLibrary.self, from: e.encode(lib))
        #expect(back.drafts["/repo"]?.worktreeBase == .branch("develop"))
        #expect(back.savedPrompts.map(\.text) == ["s"])

        let broken = #"{"drafts":{"/repo":{"prompt":1}},"savedPrompts":[]}"#
        let tolerant = try d.decode(ComposerLibrary.self, from: Data(broken.utf8))
        #expect(tolerant.drafts.isEmpty)
    }

    @Test func storePersists() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("composer.json")
        let store = ComposerLibraryStore(url: url, debounce: .seconds(60))
        var lib = ComposerLibrary()
        lib.savePrompt("kept", projectPath: nil)
        await store.replace(with: lib)
        await store.flush()
        #expect(ComposerLibraryStore(url: url).initialLibrary.savedPrompts.map(\.text) == ["kept"])
    }
}
