import SwiftUI
import ClinicCore

/// Add or edit one MCP server (ADR-093).
///
/// Two doors onto the same draft: **Form** for typing fields, and **Paste JSON** for the snippet an
/// MCP server's README actually gives you. Both end in the same `claude mcp add-json`, previewed at
/// the bottom with secrets masked.
struct MCPServerFormSheet: View {
    @Environment(MCPServersModel.self) private var model
    @Environment(SessionStore.self) private var sessions
    @Environment(\.dismiss) private var dismiss
    @Bindable var draft: MCPServerDraft

    private var isEditing: Bool { draft.editing != nil }

    /// `add` refuses to overwrite, so a collision is caught here and turned into a disabled button
    /// rather than an error from the CLI.
    private var nameCollision: Bool {
        guard let scope = draft.scope, !draft.trimmedName.isEmpty else { return false }
        if let editing = draft.editing, editing.name == draft.trimmedName, editing.scope == scope { return false }
        return model.takenNames(in: scope, projectPath: scope.isProjectScoped ? draft.projectPath : nil)
            .contains(draft.trimmedName)
    }

    private var nameProblem: String? {
        let n = draft.trimmedName
        if n.isEmpty { return nil }
        if !MCPServersConfig.isValidName(n) { return "Letters, digits, dash, dot and underscore only." }
        if nameCollision { return "A server called \(n) already exists in this scope." }
        return nil
    }

    private var canSubmit: Bool { draft.definition != nil && !nameCollision }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    identity
                    if draft.mode == .form { transportFields } else { pasteBox }
                }
                .padding(16)
            }
            Divider()
            preview
            Divider()
            footer
        }
        .frame(width: 620, height: 620)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(isEditing ? "Edit \(draft.editing?.name ?? "")" : "Add MCP Server").font(.title3.weight(.semibold))
            Spacer(minLength: 12)
            if !isEditing {
                Picker("", selection: $draft.mode) {
                    ForEach(MCPServerDraft.Mode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    // MARK: Name and scope

    private var identity: some View {
        VStack(alignment: .leading, spacing: 10) {
            field("Name") {
                VStack(alignment: .leading, spacing: 3) {
                    TextField("my-server", text: $draft.name).textFieldStyle(.roundedBorder)
                    if let problem = nameProblem {
                        Text(problem).font(.caption).foregroundStyle(.red)
                    }
                }
            }
            field("Scope") {
                VStack(alignment: .leading, spacing: 4) {
                    // No preselection: the CLI defaults to `local`, one of the two scopes people
                    // confuse, so the user says which one (ADR-093).
                    Picker("", selection: $draft.scope) {
                        Text("Choose…").tag(MCPScope?.none)
                        ForEach(MCPScope.allCases, id: \.self) { Text($0.label).tag(MCPScope?.some($0)) }
                    }
                    .labelsHidden().fixedSize()
                    .disabled(isEditing)
                    if let scope = draft.scope {
                        Text(scope.detail).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if draft.scope?.isProjectScoped == true {
                        Picker("Project", selection: $draft.projectPath) {
                            Text("Choose…").tag(String?.none)
                            ForEach(sessions.projects) { Text($0.name).tag(String?.some($0.path)) }
                        }
                        .fixedSize()
                        .disabled(isEditing)
                    }
                    if isEditing {
                        Text("Moving a server between scopes is not an edit — remove it here and add it there.")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    // MARK: Form door

    private var transportFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            field("Transport") {
                Picker("", selection: $draft.transport) {
                    Text("stdio").tag("stdio")
                    Text("http").tag("http")
                    Text("sse").tag("sse")
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            if draft.isStdio {
                field("Command") {
                    TextField("/opt/homebrew/bin/hardcover", text: $draft.command).textFieldStyle(.roundedBorder)
                }
                field("Arguments") {
                    VStack(alignment: .leading, spacing: 3) {
                        TextEditor(text: $draft.argumentsText)
                            .font(.system(.body, design: .monospaced))
                            .frame(height: 70)
                            .overlay(RoundedRectangle(cornerRadius: 5).stroke(.quaternary))
                        Text("One per line — arguments contain spaces often enough that splitting on them would lie.")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                pairs("Environment", $draft.env, keyPrompt: "API_KEY")
            } else {
                field("URL") {
                    TextField("https://mcp.example.com/mcp", text: $draft.url).textFieldStyle(.roundedBorder)
                }
                pairs("Headers", $draft.headers, keyPrompt: "Authorization")
            }
        }
    }

    /// Key/value rows. Values use a secure field: they are secrets often enough to be the default.
    private func pairs(_ label: String, _ binding: Binding<[MCPKeyValue]>, keyPrompt: String) -> some View {
        field(label) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(binding) { $pair in
                    HStack(spacing: 6) {
                        TextField(keyPrompt, text: $pair.key).textFieldStyle(.roundedBorder).frame(width: 160)
                        SecureField("value", text: $pair.value).textFieldStyle(.roundedBorder)
                        Button { binding.wrappedValue.removeAll { $0.id == pair.id } } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                Button { binding.wrappedValue.append(MCPKeyValue()) } label: { Label("Add", systemImage: "plus") }
                    .buttonStyle(.borderless)
                if !binding.wrappedValue.isEmpty {
                    Text("Claude Code stores these in plain text. Clinic masks them in the preview below, not in the command it runs.")
                        .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: Paste door

    private var pasteBox: some View {
        let snippets = MCPServersConfig.parseSnippet(draft.snippetText)
        return VStack(alignment: .leading, spacing: 8) {
            Text("Paste the JSON from the server's README").font(.callout.weight(.medium))
            Text("Either the documented wrapper, `{\"mcpServers\": {…}}`, or just the definition. Clinic fills in the fields; you review them before anything runs.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $draft.snippetText)
                .font(.system(.caption, design: .monospaced))
                .frame(height: 190)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(.quaternary))
            if draft.snippetText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                EmptyView()
            } else if snippets.isEmpty {
                Label("No MCP server found in that JSON.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            } else {
                ForEach(snippets) { snippet in
                    HStack(spacing: 8) {
                        Image(systemName: snippet.definition.isStdio ? "terminal" : "network").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(snippet.name.isEmpty ? "Unnamed server" : snippet.name).font(.callout.weight(.medium))
                            Text(MCPServerEntry.redact(snippet.definition.command.map { ([$0] + snippet.definition.args).joined(separator: " ") } ?? snippet.definition.url ?? ""))
                                .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        Button("Use") { draft.apply(snippet); draft.mode = .form }
                    }
                    .padding(8)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
                }
                Text(snippets.count == 1 && !snippets[0].name.isEmpty
                     ? "Use fills in the form so you can check it before adding."
                     : "Use fills in the form. Servers without a name in the JSON need one typed above.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: Preview and footer

    /// The command, live and redacted — ADR-084's "show it before you run it", minus the API key.
    private var preview: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(isEditing ? "Clinic will remove and re-add it — the CLI has no in-place edit" : "Clinic will run")
                .font(.caption2).foregroundStyle(.tertiary)
            Text(previewCommand)
                .font(.system(.caption, design: .monospaced)).foregroundStyle(canSubmit ? .primary : .secondary)
                .textSelection(.enabled).lineLimit(3).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var previewCommand: String {
        guard let scope = draft.scope, let definition = draft.definition else {
            return "Fill in a name, a scope and a \(draft.isStdio ? "command" : "URL")."
        }
        let add = MCPService.displayCommand(.add(name: draft.trimmedName, definition: definition, scope: scope))
        guard let editing = draft.editing else { return add }
        return MCPService.displayCommand(.remove(name: editing.name, scope: editing.scope)) + "\n" + add
    }

    private var footer: some View {
        HStack {
            if draft.scope?.isProjectScoped == true, draft.projectPath == nil {
                Label("Pick a project for this scope.", systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.orange)
            }
            Spacer()
            Button("Cancel") { model.draft = nil }.keyboardShortcut(.cancelAction)
            Button(isEditing ? "Save…" : "Add…") { model.submit(draft) }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSubmit || (draft.scope?.isProjectScoped == true && draft.projectPath == nil))
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label).font(.callout).foregroundStyle(.secondary)
                .frame(width: 90, alignment: .trailing)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
