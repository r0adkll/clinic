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
                LineageSection(summary: summary, dismiss: { dismiss() })
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

/// Who this session came out of and what came out of it (ADR-181). Each is a button that reveals the
/// session, closing the sheet first so the sidebar's selection can move.
struct LineageSection: View {
    @Environment(SessionStore.self) private var sessions
    @Environment(TabStore.self) private var tabs
    @Environment(SessionReportService.self) private var reports
    let summary: SessionSummary
    let dismiss: () -> Void

    var body: some View {
        let parent = sessions.parent(of: summary.id)
        let children = sessions.children(of: summary.id).compactMap { sessions.sessions[$0] }
        let log = reports.reports(for: summary.id).suffix(10).reversed()
        if parent != nil || !children.isEmpty || !log.isEmpty {
            Text("Lineage").font(.headline).padding(.top, 4)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                if let parent {
                    GridRow(alignment: .top) {
                        Text(parent.kind == .fork ? "Forked from" : "Started by").foregroundStyle(.secondary)
                        if let p = sessions.sessions[parent.id] {
                            link(p)
                        } else {
                            Text("a session no longer on disk").foregroundStyle(.secondary)
                        }
                    }
                }
                if !children.isEmpty {
                    GridRow(alignment: .top) {
                        Text(children.count == 1 ? "Child" : "Children").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(children) { child in
                                HStack(spacing: 6) {
                                    link(child)
                                    Text(sessions.parent(of: child.id)?.kind == .fork ? "fork" : "spawned")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                // What children reported, newest first, and whether it reached this session (ADR-182).
                if !log.isEmpty {
                    GridRow(alignment: .top) {
                        Text("Reports").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(log)) { r in
                                HStack(spacing: 6) {
                                    Text(sessions.sessions[r.from].map(sessions.displayName(for:)) ?? "a child session").lineLimit(1)
                                    Text(r.at.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                                    Text(r.deliveredAt.map { "delivered " + $0.formatted(date: .omitted, time: .shortened) } ?? "held")
                                        .font(.caption).foregroundStyle(r.deliveredAt == nil ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
                                }
                                .help(r.message)
                            }
                        }
                    }
                }
            }
            .font(.callout)
        }
    }

    private func link(_ s: SessionSummary) -> some View {
        Button(sessions.displayName(for: s)) { dismiss(); tabs.reveal(sessionId: s.id) }
            .buttonStyle(.link)
    }
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
