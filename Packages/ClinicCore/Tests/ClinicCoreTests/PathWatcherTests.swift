import Foundation
import Testing
@testable import ClinicCore

@Suite struct PathWatcherTests {
    private func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clinic-pathwatch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func next(_ changes: AsyncStream<Void>) async -> Bool {
        await withTimeout(seconds: 5) { () -> Bool in for await _ in changes { return true }; return false } == true
    }

    @Test func anchorClimbsToNearestExistingAncestor() throws {
        let root = try scratch()
        let deep = root.appendingPathComponent(".clinic/icon.svg").path
        #expect(PathWatcher.anchor(for: deep) == root.path)
        #expect(PathWatcher.anchor(for: root.path) == root.path)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".clinic"), withIntermediateDirectories: true)
        #expect(PathWatcher.anchor(for: deep) == root.appendingPathComponent(".clinic").path)
    }

    /// A file that does not exist yet is heard through its parent, and once it exists, through itself.
    @Test func emitsWhenAMissingFileAppearsThenChanges() async throws {
        let root = try scratch()
        let icon = root.appendingPathComponent("project-icon.svg")
        let watcher = PathWatcher(debounce: 0.1)
        watcher.watch([icon.path])
        defer { watcher.stop() }
        try await Task.sleep(for: .milliseconds(200))

        try Data("<svg/>".utf8).write(to: icon)
        #expect(await next(watcher.changes))

        // Now anchored on the file itself: an in-place write (no directory entry change) must still emit.
        try await Task.sleep(for: .milliseconds(200))
        let h = try FileHandle(forWritingTo: icon)
        try h.seekToEnd(); try h.write(contentsOf: Data("<!-- -->".utf8)); try h.close()
        #expect(await next(watcher.changes))
    }

    /// `.clinic/icon.svg` in a repo with no `.clinic/`: the directory appearing, then the file, are both heard.
    @Test func followsANewIntermediateDirectory() async throws {
        let root = try scratch()
        let dir = root.appendingPathComponent(".clinic")
        let icon = dir.appendingPathComponent("icon.svg")
        let watcher = PathWatcher(debounce: 0.1)
        watcher.watch([icon.path])
        defer { watcher.stop() }
        try await Task.sleep(for: .milliseconds(200))

        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        #expect(await next(watcher.changes))

        try await Task.sleep(for: .milliseconds(200))
        try Data("<svg/>".utf8).write(to: icon)
        #expect(await next(watcher.changes))
    }

    @Test func emitsOnDeletion() async throws {
        let root = try scratch()
        let icon = root.appendingPathComponent("project-icon.png")
        try Data([0]).write(to: icon)
        let watcher = PathWatcher(debounce: 0.1)
        watcher.watch([icon.path])
        defer { watcher.stop() }
        try await Task.sleep(for: .milliseconds(200))

        try FileManager.default.removeItem(at: icon)
        #expect(await next(watcher.changes))
    }
}
