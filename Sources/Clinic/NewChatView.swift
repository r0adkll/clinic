import SwiftUI
import ClinicCore

/// The new-chat screen: write the first prompt, pick model/effort/worktree, then Send (ADR-054).
struct NewChatView: View {
    @Environment(TabStore.self) private var tabs
    @Environment(SessionStore.self) private var sessions
    @Bindable var draft: NewChatDraftModel
    @FocusState private var focused: Bool

    private let models = ["default", "sonnet", "opus", "haiku"]
    private let efforts = ["default", "low", "medium", "high", "xhigh", "max"]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                ProjectIcon(project: Project(path: draft.projectPath), size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(Project(path: draft.projectPath).name).font(.title3.weight(.semibold))
                    Text(draft.projectPath).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                }
                Spacer()
                Button { tabs.discardDraft(draft) } label: { Image(systemName: "trash") }.buttonStyle(.borderless).help("Discard draft")
            }
            TextEditor(text: $draft.prompt)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minHeight: 160, maxHeight: 360)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
                .focused($focused)
                .onKeyPress(.return, phases: .down) { press in
                    if press.modifiers.contains(.command) { tabs.sendDraft(draft); return .handled }
                    return .ignored
                }
            HStack(spacing: 12) {
                Toggle("New git worktree", isOn: $draft.worktree).toggleStyle(.checkbox)
                Spacer()
                Picker("Model", selection: $draft.model) { ForEach(models, id: \.self) { Text($0.capitalized).tag($0) } }.frame(maxWidth: 160)
                Picker("Effort", selection: $draft.effort) { ForEach(efforts, id: \.self) { Text($0 == "xhigh" ? "Extra high" : $0.capitalized).tag($0) } }.frame(maxWidth: 170)
                Button(draft.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Empty Session" : "Send") { tabs.sendDraft(draft) }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
            }
            Text("The prompt becomes the session's first turn. ⌘↩ sends. Unsent text is kept as a Draft in the sidebar.").font(.caption).foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: 820, maxHeight: .infinity, alignment: .topLeading)
        .frame(maxWidth: .infinity)
        .onAppear { focused = true }
        .onChange(of: draft.prompt) { tabs.persistDraft(draft) }
        .onChange(of: draft.model) { tabs.persistDraft(draft) }
        .onChange(of: draft.effort) { tabs.persistDraft(draft) }
        .onChange(of: draft.worktree) { tabs.persistDraft(draft) }
    }
}

/// Editable, observable copy of a `ClinicState.NewChatDraft`.
@MainActor
@Observable
final class NewChatDraftModel: Identifiable {
    let id: UUID
    let projectPath: String
    var prompt: String
    var model: String
    var effort: String
    var worktree: Bool

    init(_ d: ClinicState.NewChatDraft) {
        id = d.id; projectPath = d.projectPath; prompt = d.prompt; model = d.model ?? "default"; effort = d.effort ?? "default"; worktree = d.worktree
    }

    var snapshot: ClinicState.NewChatDraft {
        ClinicState.NewChatDraft(id: id, projectPath: projectPath, prompt: prompt, model: model == "default" ? nil : model, effort: effort == "default" ? nil : effort, worktree: worktree, updatedAt: Date())
    }
}
