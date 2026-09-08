import Foundation
import Testing
@testable import ClinicCore

@Suite struct FuzzyMatcherTests {
    @Test func abbreviationPrefersFileName() {
        let a = "Sources/Clinic/GitPageModel.swift", b = "Packages/GhosttyBridge/Package.swift"
        let ma = try? #require(FuzzyMatcher.match("gpm", in: a))
        #expect(ma != nil)
        let ranked = FuzzyMatcher.rank("gpm", candidates: [b, a])
        #expect(ranked.first?.candidate == a)
    }

    @Test func emptyAndCaseAndMiss() {
        #expect(FuzzyMatcher.rank("", candidates: ["a", "b"]).count == 2)
        #expect(FuzzyMatcher.match("README", in: "docs/readme.md") != nil)
        #expect(FuzzyMatcher.match("zzz", in: "Sources/Main.swift") == nil)
    }
}

@Suite struct FileIndexTests {
    private func sh(_ args: [String], in dir: URL) throws {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/env"); p.arguments = args; p.currentDirectoryURL = dir
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try p.run(); p.waitUntilExit()
    }

    @Test func gitIndexRespectsIgnoreAndListsUntracked() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("clinic-index-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("src"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("node_modules/x"), withIntermediateDirectories: true)
        try "a".write(to: dir.appendingPathComponent("src/tracked.swift"), atomically: true, encoding: .utf8)
        try "b".write(to: dir.appendingPathComponent("untracked.md"), atomically: true, encoding: .utf8)
        try "c".write(to: dir.appendingPathComponent("secret.env"), atomically: true, encoding: .utf8)
        try "d".write(to: dir.appendingPathComponent("node_modules/x/index.js"), atomically: true, encoding: .utf8)
        try "*.env\nnode_modules/\n".write(to: dir.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        try sh(["git", "init", "-q", "-b", "main"], in: dir)
        try sh(["git", "add", "src/tracked.swift", ".gitignore"], in: dir)
        let index = FileIndex(root: dir.path)
        let files = await index.files()
        #expect(files.contains("src/tracked.swift"))
        #expect(files.contains("untracked.md"))
        #expect(!files.contains("secret.env"))
        #expect(!files.contains { $0.hasPrefix("node_modules/") })
        let top = await index.children(of: "", showHidden: false)
        #expect(top.first?.isDirectory == true && top.first?.name == "src")
        #expect(!top.contains { $0.name == ".gitignore" })
        let hidden = await index.children(of: "", showHidden: true)
        #expect(hidden.contains { $0.name == ".gitignore" })
    }

    @Test func plainWalkSkipsNoise() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("clinic-walk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("node_modules"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("lib"), withIntermediateDirectories: true)
        try "x".write(to: dir.appendingPathComponent("node_modules/dep.js"), atomically: true, encoding: .utf8)
        try "y".write(to: dir.appendingPathComponent("lib/main.py"), atomically: true, encoding: .utf8)
        let files = await FileIndex(root: dir.path).files()
        #expect(files == ["lib/main.py"])
    }
}

@Suite struct RecentFilesTests {
    @Test func collectsWritesNotReads() {
        var f = TranscriptFixture()
        f.user("go")
        f.toolUse(name: "Read", input: ["file_path": "/repo/README.md"])
        f.toolUse(name: "Write", input: ["file_path": "/repo/a.swift", "content": "x"])
        f.toolUse(name: "Edit", input: ["file_path": "/repo/b.swift", "old_string": "1", "new_string": "2"])
        f.toolUse(name: "Edit", input: ["file_path": "/repo/a.swift", "old_string": "x", "new_string": "y"])
        let s = TranscriptReader().parse(id: f.sessionId, path: "p", head: f.data, tail: Data())
        #expect(s.recentFiles == ["/repo/b.swift", "/repo/a.swift"])
    }
}
