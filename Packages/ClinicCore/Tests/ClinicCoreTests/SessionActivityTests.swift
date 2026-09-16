import Foundation
import Testing
@testable import ClinicCore

/// Record shapes copied from real 2.1.273 transcripts (ADR-044, ADR-156).
@Suite struct SessionActivityTests {
    private func fold(_ lines: [String]) -> SessionActivity {
        var a = SessionActivity()
        for line in lines { a.apply(line: Data(line.utf8)) }
        return a
    }

    private func toolUse(_ id: String, _ name: String, _ input: String, at ts: String = "2026-09-16T10:00:00.000Z") -> String {
        #"{"type":"assistant","isSidechain":false,"timestamp":"\#(ts)","message":{"role":"assistant","model":"claude-opus-5","usage":{"input_tokens":3,"cache_read_input_tokens":80000,"cache_creation_input_tokens":1200,"output_tokens":50},"content":[{"type":"tool_use","id":"\#(id)","name":"\#(name)","input":\#(input)}]}}"#
    }

    private func result(_ id: String, text: String, toolUseResult: String, error: Bool = false, at ts: String = "2026-09-16T10:00:01.000Z") -> String {
        #"{"type":"user","timestamp":"\#(ts)","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"\#(id)","is_error":\#(error),"content":"\#(text)"}]},"toolUseResult":\#(toolUseResult)}"#
    }

    private func notification(taskId: String, toolUseId: String, status: String, summary: String = "done") -> String {
        let body = "<task-notification>\\n<task-id>\(taskId)</task-id>\\n<tool-use-id>\(toolUseId)</tool-use-id>\\n<output-file>/private/tmp/claude-501/x/tasks/\(taskId).output</output-file>\\n<status>\(status)</status>\\n<summary>\(summary)</summary>\\n</task-notification>"
        return #"{"type":"queue-operation","operation":"enqueue","timestamp":"2026-09-16T10:05:00.000Z","content":"\#(body)"}"#
    }

    private func prompt(_ text: String, origin: String? = "human") -> String {
        let o = origin.map { #","origin":{"kind":"\#($0)"}"# } ?? ""
        return #"{"type":"user","timestamp":"2026-09-16T10:10:00.000Z","message":{"role":"user","content":"\#(text)"}\#(o)}"#
    }

    @Test func asyncAgentRunsUntilItsNotification() {
        let use = toolUse("toolu_A", "Agent", #"{"description":"Review branch changes","subagent_type":"general-purpose","prompt":"…"}"#)
        let launched = result("toolu_A", text: "Async agent launched successfully.",
                              toolUseResult: #"{"isAsync":true,"status":"async_launched","agentId":"a9e1cffa22d0b3e09","description":"Review branch changes"}"#)
        var a = fold([use, launched])
        #expect(a.running.count == 1)
        let child = a.children[0]
        #expect(child.kind == .agent)
        #expect(child.label == "Review branch changes")
        #expect(child.detail == "general-purpose")
        #expect(child.taskId == "a9e1cffa22d0b3e09")
        #expect(child.startedAt == TranscriptReader.parseDate("2026-09-16T10:00:00.000Z"))

        a.apply(line: Data(notification(taskId: "a9e1cffa22d0b3e09", toolUseId: "toolu_A", status: "completed").utf8))
        #expect(a.running.isEmpty)
        #expect(a.children[0].outcome == .completed)
        #expect(a.children[0].endedAt == TranscriptReader.parseDate("2026-09-16T10:05:00.000Z"))
    }

    @Test func synchronousAgentEndsWithItsResult() {
        let use = toolUse("toolu_S", "Task", #"{"description":"Find the glyph","subagent_type":"Explore"}"#)
        let done = result("toolu_S", text: "Found it", toolUseResult: #"{"status":"completed","agentId":"abc"}"#)
        let a = fold([use, done])
        #expect(a.children.first?.outcome == .completed)
    }

    @Test func backgroundShellTakesItsTaskIdAndOutputFile() {
        let use = toolUse("toolu_B", "Bash", #"{"command":"./gradlew hotRun","description":"Launch the desktop app","run_in_background":true}"#)
        let launched = result("toolu_B", text: "Command running in background with ID: bdchs60ut. Output is being written to: /private/tmp/claude-501/p/s/tasks/bdchs60ut.output. You will be notified",
                              toolUseResult: #"{"stdout":"","stderr":"","interrupted":false,"backgroundTaskId":"bdchs60ut"}"#)
        var a = fold([use, launched])
        #expect(a.running.map(\.label) == ["Launch the desktop app"])
        #expect(a.children[0].taskId == "bdchs60ut")
        #expect(a.children[0].outputFile == "/private/tmp/claude-501/p/s/tasks/bdchs60ut.output")

        a.apply(line: Data(notification(taskId: "bdchs60ut", toolUseId: "toolu_B", status: "failed").utf8))
        #expect(a.children[0].outcome == .failed)
    }

    @Test func foregroundBashIsNotAChild() {
        let a = fold([toolUse("toolu_F", "Bash", #"{"command":"ls","description":"List"}"#)])
        #expect(a.children.isEmpty)
        #expect(a.currentTool?.name == "Bash")
        #expect(a.currentTool?.summary == "ls")
    }

    @Test func monitorEndsWhenItsStreamEnds() {
        let use = toolUse("toolu_M", "Monitor", #"{"description":"wait for smoke window","command":"until …; done"}"#)
        let started = result("toolu_M", text: "Monitor started (task bw1ldfn07, timeout 15000ms).",
                             toolUseResult: #"{"taskId":"bw1ldfn07","timeoutMs":15000,"persistent":false}"#)
        var a = fold([use, started])
        #expect(a.running.first?.kind == .monitor)
        a.apply(line: Data(notification(taskId: "bw1ldfn07", toolUseId: "toolu_M", status: "completed", summary: "Monitor stream ended").utf8))
        #expect(a.running.isEmpty)
    }

    @Test func deniedLaunchIsDropped() {
        let use = toolUse("toolu_D", "Bash", #"{"command":"make","run_in_background":true}"#)
        let denied = result("toolu_D", text: "Permission denied", toolUseResult: #""Error: denied""#, error: true)
        #expect(fold([use, denied]).children.isEmpty)
    }

    @Test func taskStopEndsTheShellItNames() {
        let use = toolUse("toolu_B", "Bash", #"{"command":"serve","run_in_background":true}"#)
        let launched = result("toolu_B", text: "Command running in background with ID: b1.", toolUseResult: #"{"backgroundTaskId":"b1"}"#)
        let stop = result("toolu_X", text: "{}", toolUseResult: #"{"message":"Successfully stopped task: b1 (serve)","task_id":"b1","task_type":"local_bash"}"#)
        let a = fold([use, launched, toolUse("toolu_X", "TaskStop", #"{"task_id":"b1"}"#), stop])
        #expect(a.children.first?.outcome == .stopped)
    }

    @Test func notificationInAUserRecordOrAttachmentAlsoEnds() {
        let use = toolUse("toolu_B", "Bash", #"{"command":"make","run_in_background":true}"#)
        let launched = result("toolu_B", text: "Command running in background with ID: b2.", toolUseResult: #"{"backgroundTaskId":"b2"}"#)
        let viaUser = prompt("<task-notification>\\n<task-id>b2</task-id>\\n<tool-use-id>toolu_B</tool-use-id>\\n<status>completed</status>\\n</task-notification>", origin: "task-notification")
        let a = fold([use, launched, viaUser])
        #expect(a.children.first?.outcome == .completed)

        let attachment = #"{"type":"attachment","attachment":{"type":"queued_command","prompt":"<task-notification>\n<task-id>b2</task-id>\n<status>stopped</status>\n</task-notification>"}}"#
        let b = fold([use, launched, attachment])
        #expect(b.children.first?.outcome == .stopped)
    }

    @Test func aPromptClearsFinishedChildrenButKeepsRunningOnes() {
        let lines = [
            toolUse("toolu_1", "Bash", #"{"command":"a","run_in_background":true}"#),
            result("toolu_1", text: "Command running in background with ID: t1.", toolUseResult: #"{"backgroundTaskId":"t1"}"#),
            toolUse("toolu_2", "Bash", #"{"command":"b","run_in_background":true}"#),
            result("toolu_2", text: "Command running in background with ID: t2.", toolUseResult: #"{"backgroundTaskId":"t2"}"#),
            notification(taskId: "t1", toolUseId: "toolu_1", status: "completed"),
        ]
        var a = fold(lines)
        #expect(a.finished.count == 1)
        // A task notification is not the user's prompt.
        a.apply(line: Data(prompt("<task-notification><task-id>zz</task-id></task-notification>", origin: "task-notification").utf8))
        #expect(a.finished.count == 1)
        a.apply(line: Data(prompt("Next, please").utf8))
        #expect(a.finished.isEmpty)
        #expect(a.running.map(\.id) == ["toolu_2"])
    }

    @Test func recapContextAndModel() {
        let lines = [
            #"{"type":"attachment","attachment":{"type":"model","identity":{"modelId":"claude-opus-5","marketingName":"Opus 5"}}}"#,
            toolUse("toolu_E", "Edit", #"{"file_path":"/r/Sources/Clinic/SidebarView.swift"}"#),
            result("toolu_E", text: "ok", toolUseResult: "{}"),
            #"{"type":"system","subtype":"away_summary","content":"The fix is done. Next: eyeball it. (disable recaps in /config)","isSidechain":false}"#,
        ]
        var a = fold(lines)
        #expect(a.recap == "The fix is done. Next: eyeball it.")
        #expect(a.contextTokens == 81203)
        #expect(a.modelName == "Opus 5")
        #expect(a.currentTool == nil)
        a.apply(line: Data(prompt("Thanks").utf8))
        #expect(a.recap == nil)
    }

    @Test func sidechainRecordsAreIgnored() {
        let use = #"{"type":"assistant","isSidechain":true,"message":{"content":[{"type":"tool_use","id":"toolu_Z","name":"Bash","input":{"command":"x","run_in_background":true}}]}}"#
        #expect(fold([use]).children.isEmpty)
    }

    @Test func modelDisplayNames() {
        #expect(ModelName.display("claude-opus-5") == "Opus 5")
        #expect(ModelName.display("claude-sonnet-4-5-20250929") == "Sonnet 4.5")
        #expect(ModelName.display("claude-opus-5[1m]") == "Opus 5")
        #expect(ModelName.display("claude-fable-5-1") == "Fable 5.1")
        #expect(ModelName.display("claude-haiku-4-5-20251001") == "Haiku 4.5")
        #expect(ModelName.display("gpt-oss") == "Gpt")
    }
}

@Suite struct TranscriptFollowerTests {
    private func tempFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("follower-\(UUID().uuidString).jsonl")
    }

    private func append(_ s: String, to url: URL) throws {
        let h = try FileHandle(forWritingTo: url)
        try h.seekToEnd(); try h.write(contentsOf: Data(s.utf8)); try h.close()
    }

    @Test func foldsOnlyWhatWasAppendedAndWaitsForWholeLines() async throws {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let use = #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_1","name":"Monitor","input":{"description":"watch"}}]}}"#
        try Data((use + "\n").utf8).write(to: url)
        let follower = TranscriptFollower(path: url.path)
        #expect(await follower.poll()?.children.count == 1)
        #expect(await follower.poll() == nil)

        let note = #"{"type":"queue-operation","content":"<task-notification><tool-use-id>toolu_1</tool-use-id><status>completed</status></task-notification>"}"#
        // Half a line: nothing to fold yet.
        try append(String(note.prefix(40)), to: url)
        #expect(await follower.poll() == nil)
        try append(String(note.dropFirst(40)) + "\n", to: url)
        #expect(await follower.poll()?.children.first?.outcome == .completed)
    }

    @Test func startsInsideTheWindowOnALongTranscript() async throws {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let old = #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_old","name":"Monitor","input":{"description":"old"}}]}}"#
        let filler = String(repeating: #"{"type":"atis-latch"}"# + "\n", count: 200)
        let recent = #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_new","name":"Monitor","input":{"description":"new"}}]}}"#
        try Data((old + "\n" + filler + recent + "\n").utf8).write(to: url)
        let follower = TranscriptFollower(path: url.path, initialWindow: 1024)
        #expect(await follower.poll()?.children.map(\.label) == ["new"])
    }

    @Test func missingFileIsQuiet() async {
        #expect(await TranscriptFollower(path: "/nonexistent/\(UUID().uuidString).jsonl").poll() == nil)
    }
}
