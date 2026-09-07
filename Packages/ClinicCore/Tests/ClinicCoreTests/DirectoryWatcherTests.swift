import Foundation
import Testing
@testable import ClinicCore

@Suite struct DirectoryWatcherTests {
    @Test func emitsOnNewTranscriptInNewProjectDir() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clinic-watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let watcher = DirectoryWatcher(root: root, debounce: 0.1)
        watcher.start()
        defer { watcher.stop() }
        try await Task.sleep(for: .milliseconds(200))

        let proj = root.appendingPathComponent("-Users-me-repo")
        try FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)
        let changes = watcher.changes
        let first = await withTimeout(seconds: 5) { () -> Bool in for await _ in changes { return true }; return false }
        #expect(first == true)

        // The new project dir is now watched: a file written inside it must emit again.
        try await Task.sleep(for: .milliseconds(200))
        try Data("{}\n".utf8).write(to: proj.appendingPathComponent("a.jsonl"))
        let second = await withTimeout(seconds: 5) { () -> Bool in for await _ in changes { return true }; return false }
        #expect(second == true)
    }
}
