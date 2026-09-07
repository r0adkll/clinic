import Foundation
import Testing
@testable import ClinicCore

@Suite struct TranscriptReaderTests {
    let reader = TranscriptReader()

    @Test func readsHeadFields() throws {
        var f = TranscriptFixture()
        f.unknown()
        f.user("Fix the flaky spinner test in CI", at: "2026-09-07T10:00:00.000Z")
        f.assistant("On it.", model: "claude-opus-5", at: "2026-09-07T10:00:05.000Z")
        f.aiTitle("Flaky spinner fix")
        f.costState(0.42)
        let s = reader.parse(id: f.sessionId, path: "/x/\(f.sessionId).jsonl", head: f.data, tail: Data())
        #expect(s.cwd == "/Users/me/repo")
        #expect(s.gitBranch == "main")
        #expect(s.firstPrompt == "Fix the flaky spinner test in CI")
        #expect(s.model == "claude-opus-5")
        #expect(s.aiTitle == "Flaky spinner fix")
        #expect(s.totalCostUSD == 0.42)
        #expect(s.createdAt == TranscriptReader.parseDate("2026-09-07T10:00:00.000Z"))
        #expect(s.lastActivityAt == TranscriptReader.parseDate("2026-09-07T10:00:05.000Z"))
    }

    @Test func skipsMetaAndInjectedPrompts() {
        var f = TranscriptFixture()
        f.user("<system-reminder>ignore me</system-reminder>")
        f.user("caveat", meta: true)
        f.userBlocks("Real prompt here")
        let s = reader.parse(id: f.sessionId, path: "p", head: f.data, tail: Data())
        #expect(s.firstPrompt == "Real prompt here")
    }

    @Test func toleratesGarbageLines() {
        var f = TranscriptFixture()
        f.raw("not json at all")
        f.raw("{\"type\":\"user\"")
        f.user("ok")
        let s = reader.parse(id: f.sessionId, path: "p", head: f.data, tail: Data())
        #expect(s.firstPrompt == "ok")
    }

    @Test func tailOverridesLatestValues() {
        var head = TranscriptFixture()
        head.user("start", at: "2026-09-07T10:00:00.000Z")
        var tail = TranscriptFixture(cwd: "/Users/me/repo/.claude/worktrees/feature-x")
        tail.gitBranch = "feature-x"
        tail.assistant("done", model: "claude-haiku-4-5", at: "2026-09-07T11:00:00.000Z")
        tail.customTitle("My renamed session")
        // simulate a partial first line in the tail (seek landed mid-record)
        let tailData = Data("garbage-partial-line\n".utf8) + tail.data
        let s = reader.parse(id: head.sessionId, path: "p", head: head.data, tail: tailData, size: 999_999)
        #expect(s.cwd == "/Users/me/repo")
        #expect(s.lastCwd == "/Users/me/repo/.claude/worktrees/feature-x")
        #expect(s.gitBranch == "feature-x")
        #expect(s.model == "claude-haiku-4-5")
        #expect(s.customTitle == "My renamed session")
        #expect(s.lastActivityAt == TranscriptReader.parseDate("2026-09-07T11:00:00.000Z"))
    }

    @Test func readsFromDiskWithBoundedHeadAndTail() throws {
        var f = TranscriptFixture()
        f.user("first prompt", at: "2026-09-07T10:00:00.000Z")
        for i in 0..<3000 { f.assistant(String(repeating: "x", count: 200) + "\(i)", at: "2026-09-07T10:00:05.000Z") }
        f.aiTitle("Late title")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("clinic-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(f.sessionId).jsonl")
        try f.data.write(to: url)
        let small = TranscriptReader(headLimit: 4096, tailLimit: 4096)
        let s = try small.read(fileAt: url.path)
        #expect(s.id == f.sessionId)
        #expect(s.firstPrompt == "first prompt")
        #expect(s.aiTitle == "Late title")
        #expect(s.fileSize > 4096)
    }
}
