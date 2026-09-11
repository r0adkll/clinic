import SwiftUI
import ClinicCore

/// Read-only facts about a session from its transcript (ADR-059). ⌘I / context menu "Details…".
struct SessionDetailsSheet: View {
    @Environment(SessionStore.self) private var sessions
    @Environment(\.dismiss) private var dismiss
    let summary: SessionSummary
    @State private var result: TranscriptTurns.Result?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(sessions.displayName(for: summary)).font(.title3.weight(.semibold)).lineLimit(2)
                    Text(summary.id.rawValue).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Spacer()
                Button("Copy ID") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(summary.id.rawValue, forType: .string) }
                Button("Reveal Transcript") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: summary.transcriptPath)]) }
            }
            if let r = result {
                let s = r.stats
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                    row("Project", ProjectGrouping.project(for: summary)?.path ?? "—")
                    row("Working directory", summary.lastCwd ?? summary.cwd ?? "—")
                    row("Branch", summary.gitBranch ?? "—")
                    row("Messages", "\(s.userMessages) from you · \(s.assistantMessages) from Claude · \(s.thinkingBlocks) thinking")
                    row("Tool calls", "\(s.totalToolCalls)")
                    row("Models", s.models.isEmpty ? "—" : s.models.map(TabFooter.shortModel).joined(separator: ", "))
                    row("Tokens", "in \(fmt(s.inputTokens)) · out \(fmt(s.outputTokens)) · cache read \(fmt(s.cacheReadTokens)) · cache write \(fmt(s.cacheCreationTokens))")
                    row("Cost", s.totalCostUSD.map { $0.formatted(.currency(code: "USD")) } ?? "—")
                    row("Started", s.firstAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "—")
                    row("Last activity", s.lastAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "—")
                    row("Duration", s.duration.map(ReplayView.duration) ?? "—")
                    row("Transcript size", ByteCountFormatter.string(fromByteCount: s.fileSize, countStyle: .file))
                    row("MCP servers", s.mcpServers.isEmpty ? "—" : s.mcpServers.joined(separator: ", "))
                    row("Pull requests", summary.pullRequests.isEmpty ? "—" : summary.pullRequests.map { "#\($0.number)" }.joined(separator: ", "))
                    let tasks = sessions.workItems(for: summary.id)
                    row("Tasks", tasks.isEmpty ? "—" : tasks.map(\.display).joined(separator: ", "))
                }
                .font(.callout)
                if !s.toolCalls.isEmpty {
                    Text("Tools").font(.headline).padding(.top, 4)
                    let sorted = s.toolCalls.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
                    FlowText(items: sorted.map { "\($0.key) ×\($0.value)" })
                }
                let peek = r.turns.filter { if case .user = $0 { return true }; if case .assistant = $0 { return true }; return false }.suffix(3)
                if !peek.isEmpty {
                    Text("Recent activity").font(.headline).padding(.top, 4)
                    ScrollView { VStack(alignment: .leading, spacing: 8) { ForEach(Array(peek.enumerated()), id: \.offset) { _, t in TurnBubble(turn: t) } } }
                        .frame(maxHeight: 200)
                }
            } else if let error {
                Text(error).foregroundStyle(.red)
            } else {
                ProgressView("Reading transcript…")
            }
            HStack { Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.cancelAction) }
        }
        .padding(20)
        .frame(width: 640)
        .task {
            let path = summary.transcriptPath
            let r = await Task.detached { () -> Result<TranscriptTurns.Result, Error> in
                do { return .success(try TranscriptTurns.read(fileAt: path)) } catch { return .failure(error) }
            }.value
            switch r { case .success(let v): result = v; case .failure(let e): error = "\(e)" }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow(alignment: .top) { Text(label).foregroundStyle(.secondary); Text(value).textSelection(.enabled).lineLimit(3) }
    }

    private func fmt(_ n: Int) -> String { n.formatted(.number.notation(.compactName)) }
}

/// Wrapping row of small capsules.
struct FlowText: View {
    let items: [String]
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(items, id: \.self) { item in
                    Text(item).font(.system(.caption, design: .monospaced)).padding(.horizontal, 6).padding(.vertical, 2).background(.quaternary, in: Capsule())
                }
            }
        }
    }
}
