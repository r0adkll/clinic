import SwiftUI
import ClinicCore

/// The MCP Servers screen (ADR-093): see and change the MCP servers your sessions get, without
/// leaving Clinic. Shown in the content area like Marketplace, not as a tab — it owns no session.
struct MCPServersScreen: View {
    @Environment(MCPServersModel.self) private var model
    @Environment(SessionStore.self) private var sessions
    @Environment(TabStore.self) private var tabs

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            MCPFooter()
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(item: $model.draft) { MCPServerFormSheet(draft: $0) }
        .sheet(item: $model.pending) { MCPConfirmSheet(pending: $0) }
        .task { model.loadIfNeeded(defaultProject: defaultProject) }
    }

    /// The project the picker opens on. "Chats" is a pseudo-project with no repository and no
    /// `.mcp.json`, so it is a poor thing to land on; the first real project is the useful default.
    private var defaultProject: String? {
        sessions.projects.first { !SessionStore.isChats($0.path) }?.path ?? sessions.projects.first?.path
    }

    // MARK: Header

    private var header: some View {
        @Bindable var model = model
        return VStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "server.rack").font(.title3).foregroundStyle(Color.accentColor)
                Text("MCP Servers").font(.title3.weight(.semibold))
                Text("Tools your sessions can call").font(.callout).foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Menu {
                    Button("New Server…") { model.beginAdd(mode: .form) }
                    Button("Paste JSON…") { model.beginAdd(mode: .paste) }
                    Divider()
                    Button("Import from Claude Desktop…") { model.importFromClaudeDesktop() }
                    if let path = model.projectPath {
                        Button("Reset Approval Choices…") { model.resetProjectChoices(for: path) }
                    }
                    Divider()
                    Button("Reveal ~/.claude.json") {
                        NSWorkspace.shared.activateFileViewerSelecting([MCPServersConfig.configFileURL()])
                    }
                } label: {
                    Label("Add Server", systemImage: "plus")
                }
                .menuStyle(.button).fixedSize()
                .disabled(model.cliAvailable == false || model.runningCommand != nil)

                Button { Task { await model.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .disabled(model.isLoading)
                    .help("Re-read the configuration files")
            }
            HStack(spacing: 10) {
                Picker("Project", selection: Binding(get: { model.projectPath }, set: { model.selectProject($0) })) {
                    Text("None").tag(String?.none)
                    ForEach(sessions.projects) { p in
                        Text(p.name).tag(String?.some(p.path))
                    }
                }
                .fixedSize()
                .disabled(model.showAllProjects)
                .help("Which project's private and shared servers to show")

                Toggle("Show all projects", isOn: Binding(get: { model.showAllProjects }, set: { model.setShowAllProjects($0) }))
                    .toggleStyle(.checkbox)

                SearchField(text: $model.query, prompt: "Filter servers").frame(maxWidth: 260)
                Spacer(minLength: 0)
                if model.isLoading { ProgressView().controlSize(.small) }
            }
        }
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if model.cliAvailable == false {
            ContentUnavailableView {
                Label("Claude Code was not found", systemImage: "terminal")
            } description: {
                Text("Clinic runs `claude mcp` to change your MCP servers, and could not find `claude` on the PATH a GUI app inherits — /usr/bin, /bin, /opt/homebrew/bin, /usr/local/bin and ~/.local/bin. The list below is still read straight from your configuration files.")
            } actions: {
                Button("Try Again") { Task { await model.refresh() } }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            HStack(spacing: 0) {
                serverList.frame(width: 340)
                Divider()
                Group {
                    if let entry = model.selected {
                        MCPServerDetail(entry: entry)
                    } else {
                        ContentUnavailableView("Nothing selected", systemImage: "server.rack",
                                               description: Text("Pick a server to see how it starts and whether it connects."))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var serverList: some View {
        @Bindable var model = model
        return List(selection: $model.selectedId) {
            // Empty scopes are shown rather than hidden: "this project has no private servers" is
            // the answer to a question people actually ask (ADR-093).
            section(MCPScope.user.label, entries: model.entries(in: .user), empty: "No servers for every project.")
            if model.showAllProjects {
                ForEach(model.allProjectPaths, id: \.self) { path in
                    let name = (path as NSString).lastPathComponent
                    section("\(name) · private", entries: model.entries(in: .local, projectPath: path), empty: nil)
                    section("\(name) · shared", entries: model.entries(in: .project, projectPath: path), empty: nil)
                }
            } else if let path = model.projectPath {
                let name = (path as NSString).lastPathComponent
                section("\(name) · private", entries: model.entries(in: .local, projectPath: path),
                        empty: "Nothing private to this project.")
                section("\(name) · shared (.mcp.json)", entries: model.entries(in: .project, projectPath: path),
                        empty: "Nothing committed to .mcp.json.")
            }
        }
        .listStyle(.inset)
    }

    @ViewBuilder
    private func section(_ title: String, entries: [MCPServerEntry], empty: String?) -> some View {
        if !entries.isEmpty {
            Section(title) { ForEach(entries) { MCPServerRow(entry: $0).tag($0.id) } }
        } else if let empty, model.query.isEmpty {
            Section(title) {
                Text(empty).font(.caption).foregroundStyle(.tertiary).padding(.vertical, 2)
            }
        }
    }
}

// MARK: - Rows

struct MCPServerRow: View {
    @Environment(MCPServersModel.self) private var model
    let entry: MCPServerEntry

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: entry.transport == "stdio" ? "terminal" : "network")
                .foregroundStyle(.secondary).frame(width: 16).padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.name).font(.body.weight(.semibold)).lineLimit(1)
                    Text(entry.transport).font(.caption2)
                        .padding(.horizontal, 5).padding(.vertical, 1).background(.quaternary, in: Capsule())
                    if let approval = entry.approval { ApprovalPill(approval: approval) }
                    Spacer(minLength: 0)
                    if let h = model.health[entry.id] { HealthDot(health: h) }
                }
                Text(entry.summary)
                    .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
        }
        .padding(.vertical, 2)
    }
}

struct ApprovalPill: View {
    let approval: MCPApproval
    var body: some View {
        Text(approval.label).font(.caption2)
            .foregroundStyle(color)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(color.opacity(0.15), in: Capsule())
    }
    private var color: Color {
        switch approval {
        case .approved: .green
        case .disabled: .secondary
        case .pending: .orange
        }
    }
}

struct HealthDot: View {
    let health: MCPHealth
    var body: some View {
        Image(systemName: symbol).font(.caption2).foregroundStyle(color).help(health.detail ?? health.label)
    }
    private var symbol: String {
        switch health {
        case .connected: "checkmark.circle.fill"
        case .needsAuthentication: "person.crop.circle.badge.exclamationmark"
        case .pendingApproval: "pause.circle.fill"
        case .failed: "xmark.octagon.fill"
        case .unknown: "questionmark.circle"
        }
    }
    private var color: Color {
        switch health {
        case .connected: .green
        case .needsAuthentication, .pendingApproval: .orange
        case .failed: .red
        case .unknown: .secondary
        }
    }
}

// MARK: - Detail

struct MCPServerDetail: View {
    @Environment(MCPServersModel.self) private var model
    @Environment(TabStore.self) private var tabs
    let entry: MCPServerEntry

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                title
                status
                actions
                definition
                if entry.scope == .project { approvalNote }
                facts
            }
            .frame(maxWidth: 620, alignment: .leading)
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .id(entry.id)
        .task(id: entry.id) { model.checkHealth(entry) }
    }

    private var title: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(entry.name).font(.title2.weight(.semibold)).textSelection(.enabled)
                Text(entry.transport).font(.caption)
                    .padding(.horizontal, 6).padding(.vertical, 2).background(.quaternary, in: Capsule())
                if let approval = entry.approval { ApprovalPill(approval: approval) }
            }
            Text(entry.scope.detail).font(.callout).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var status: some View {
        HStack(spacing: 8) {
            if model.checkingHealth.contains(entry.id) {
                ProgressView().controlSize(.small)
                Text("Checking…").font(.callout).foregroundStyle(.secondary)
            } else if let h = model.health[entry.id] {
                HealthDot(health: h)
                VStack(alignment: .leading, spacing: 1) {
                    Text(h.label).font(.callout)
                    if let d = h.detail {
                        Text(d).font(.caption).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
                    }
                }
            } else {
                // A running command clears every cached verdict, and `.task(id:)` will not re-fire
                // for a selection that never changed — so this branch has to say something.
                Image(systemName: "questionmark.circle").font(.caption2).foregroundStyle(.secondary)
                Text("Not checked").font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button { model.checkHealth(entry, force: true) } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless).help("Re-check with `claude mcp get`")
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button("Edit") { model.beginEdit(entry) }
            Button("Duplicate") { model.beginDuplicate(entry) }
            if entry.transport != "stdio" {
                // OAuth opens a browser and waits for a redirect, so it runs in a real PTY rather
                // than a captured pipe (ADR-093).
                Button("Log In") {
                    tabs.newShell(in: entry.projectPath, initialInput: MCPService.displayCommand(.login(name: entry.name)))
                }
                .help("Opens a shell tab and runs claude mcp login \(entry.name)")
                Button("Log Out") { model.logout(entry) }
            }
            Button("Remove", role: .destructive) { model.remove(entry) }
            Spacer(minLength: 0)
        }
        .disabled(model.runningCommand != nil || model.cliAvailable == false)
    }

    private var definition: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let url = entry.url {
                labelled("URL", MCPServerEntry.redact(url))
            } else {
                labelled("Command", entry.command ?? "—")
                if !entry.args.isEmpty { labelled("Arguments", entry.args.joined(separator: "\n")) }
            }
            if !entry.envKeys.isEmpty { keyList("Environment", entry.envKeys) }
            if !entry.headerKeys.isEmpty { keyList("Headers", entry.headerKeys) }
            if !entry.envKeys.isEmpty || !entry.headerKeys.isEmpty {
                Text("Values are stored in plain text in \(MCPServersConfig.fileURL(for: entry).lastPathComponent) and are never shown here. Use Reveal to open the file if you need to read one.")
                    .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    private func labelled(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            Text(value).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Names only — the values never leave the file (ADR-060's rule, kept by ADR-093).
    private func keyList(_ label: String, _ keys: [String]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            ForEach(keys, id: \.self) { k in
                HStack(spacing: 4) {
                    Text(k).font(.system(.caption, design: .monospaced))
                    Text("••••••").font(.system(.caption, design: .monospaced)).foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var approvalNote: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle").foregroundStyle(.secondary)
            Text("Approval for a shared server is answered inside a session, the first time Claude Code sees it. There is no command to set it, so Clinic shows the answer but cannot change it — only reset every choice for this project at once.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }

    private var facts: some View {
        VStack(alignment: .leading, spacing: 4) {
            fact("Scope", entry.scope.rawValue)
            if let p = entry.projectPath { fact("Project", (p as NSString).abbreviatingWithTildeInPath) }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("File").foregroundStyle(.tertiary).frame(width: 60, alignment: .leading)
                Button((MCPServersConfig.fileURL(for: entry).path as NSString).abbreviatingWithTildeInPath) {
                    NSWorkspace.shared.activateFileViewerSelecting([MCPServersConfig.fileURL(for: entry)])
                }
                .buttonStyle(.link)
            }
        }
        .font(.caption)
    }

    private func fact(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).foregroundStyle(.tertiary).frame(width: 60, alignment: .leading)
            Text(value).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }
}

// MARK: - Footer

/// What the screen is doing, and the standing caveat: nothing here changes a session already running.
struct MCPFooter: View {
    @Environment(MCPServersModel.self) private var model

    var body: some View {
        @Bindable var model = model
        return HStack(spacing: 8) {
            if let command = model.runningCommand {
                ProgressView().controlSize(.small)
                Text(command).font(.system(.caption, design: .monospaced)).lineLimit(1).truncationMode(.middle)
            } else if let error = model.runError {
                Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                Text(error).font(.caption).foregroundStyle(.primary).lineLimit(3).textSelection(.enabled)
                Spacer(minLength: 8)
                Button("Dismiss") { model.runError = nil }.buttonStyle(.borderless)
            } else if let done = model.lastSucceeded {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("\(done) — takes effect in sessions started from now on.").font(.caption)
            } else {
                Image(systemName: "info.circle").foregroundStyle(.tertiary)
                Text("Adding or removing a server affects sessions you start afterwards, not ones already running.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }
}

/// The commands Clinic is about to hand the CLI, shown before any of them run.
///
/// An edit is two commands, and both are listed — the remove-then-add is the CLI's shape, so it is
/// visible rather than hidden behind a Save button (ADR-093).
struct MCPConfirmSheet: View {
    @Environment(MCPServersModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let pending: MCPServersModel.Pending

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(pending.title).font(.title3.weight(.semibold))
            Text(pending.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 4) {
                Text(pending.operations.count > 1 ? "Clinic will run, in order" : "Clinic will run")
                    .font(.caption).foregroundStyle(.tertiary)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(pending.commands.enumerated()), id: \.offset) { _, command in
                        Text(command).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            }
            if let path = pending.projectPath {
                Text("Run in \((path as NSString).abbreviatingWithTildeInPath) — project and private scopes act on the directory the command runs in.")
                    .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            }
            if pending.commands.contains(where: { $0.contains("••••••") }) {
                Text("Secrets are masked above, not in the command itself: the real values are passed to the CLI and stored in plain text by Claude Code.")
                    .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            }
            Text("Clinic never edits ~/.claude.json or .mcp.json itself; the Claude CLI owns those files.")
                .font(.caption2).foregroundStyle(.tertiary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(pending.isDestructive ? "Continue" : "Run", role: pending.isDestructive ? .destructive : nil) {
                    model.runPending()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}
