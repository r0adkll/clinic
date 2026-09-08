import SwiftUI
import ClinicCore

/// Read-only list of MCP servers Claude Code is configured with (ADR-060). View → MCP Servers… (⌘⇧M).
struct MCPServersSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [MCPServerEntry] = []
    @State private var loaded = false

    private var global: [MCPServerEntry] { entries.filter { $0.scope == .global } }
    private var projectPaths: [String] {
        Array(Set(entries.compactMap { e -> String? in
            switch e.scope { case .project(let p), .projectFile(let p): return p; case .global: return nil }
        })).sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("MCP Servers").font(.title3.weight(.semibold))
                Spacer()
                Button { NSWorkspace.shared.activateFileViewerSelecting([MCPServersConfig.configFileURL()]) } label: { Label("Reveal ~/.claude.json", systemImage: "folder") }
            }
            Text("Read from Claude Code's configuration. Clinic adds its own “clinic” server to each session it starts; that one is not listed here.")
                .font(.caption).foregroundStyle(.secondary)
            if !loaded {
                ProgressView().frame(maxWidth: .infinity)
            } else if entries.isEmpty {
                ContentUnavailableView("No MCP servers configured", systemImage: "server.rack", description: Text("Add servers with `claude mcp add` or a project .mcp.json."))
            } else {
                List {
                    if !global.isEmpty { Section("Global") { ForEach(global) { ServerRow(entry: $0) } } }
                    ForEach(projectPaths, id: \.self) { path in
                        Section((path as NSString).abbreviatingWithTildeInPath) {
                            ForEach(entries.filter { $0.scope == .project(path) || $0.scope == .projectFile(path) }) { ServerRow(entry: $0) }
                        }
                    }
                }
                .listStyle(.inset)
            }
            HStack { Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.cancelAction) }
        }
        .padding(20)
        .frame(width: 640, height: 480)
        .task {
            let e = await Task.detached { MCPServersConfig.load() }.value
            entries = e; loaded = true
        }
    }
}

struct ServerRow: View {
    let entry: MCPServerEntry
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: entry.transport == "stdio" ? "terminal" : "network").foregroundStyle(.secondary).frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.name).font(.body.weight(.semibold))
                    Text(entry.transport).font(.caption2).padding(.horizontal, 5).padding(.vertical, 1).background(.quaternary, in: Capsule())
                    if case .projectFile = entry.scope { Text(".mcp.json").font(.caption2).foregroundStyle(.tertiary) }
                    if let on = entry.enabled { Text(on ? "enabled" : "disabled").font(.caption2).foregroundStyle(on ? .green : .red) }
                }
                Text(entry.summary).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                if !entry.envKeys.isEmpty { Text("env: " + entry.envKeys.joined(separator: ", ")).font(.caption2).foregroundStyle(.tertiary) }
            }
        }
        .padding(.vertical, 2)
    }
}
