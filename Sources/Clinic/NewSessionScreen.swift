import SwiftUI
import ClinicCore

/// First-prompt screen in the content area (ADR-071): prompt, model, effort, worktree + branch; Send or Empty Session.
@MainActor
@Observable
final class NewSessionDraft: Identifiable {
    let id = UUID()
    let projectPath: String
    var prompt = ""
    var model = "default"
    var customModel = ""
    var effort = "default"
    var worktree = false
    var worktreeName = ""

    init(projectPath: String, model: String?, worktree: Bool) {
        self.projectPath = projectPath
        if let model { if ["sonnet", "opus", "haiku"].contains(model) { self.model = model } else { self.model = "custom"; customModel = model } }
        self.worktree = worktree
    }

    var resolvedModel: String? {
        switch model { case "default": return nil; case "custom": return customModel.trimmingCharacters(in: .whitespaces).isEmpty ? nil : customModel; default: return model }
    }
    var resolvedEffort: String? { effort == "default" ? nil : effort }
}

struct NewSessionScreen: View {
    @Environment(TabStore.self) private var tabs
    @Environment(SessionStore.self) private var sessions
    @Bindable var draft: NewSessionDraft
    @FocusState private var focused: Bool

    private let models = ["default", "sonnet", "opus", "haiku", "custom"]
    private let efforts = ["default", "low", "medium", "high", "xhigh", "max"]
    private var project: Project { Project(path: draft.projectPath) }
    private var hasPrompt: Bool { !draft.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                ProjectIcon(project: project, size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(SessionStore.isChats(project.path) ? "New chat" : project.name).font(.title3.weight(.semibold))
                    Text(TabFooter.abbreviate(draft.projectPath)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                }
                Spacer()
                Button { tabs.discardDraft(draft) } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).help("Discard (⌘W)")
            }
            TextEditor(text: $draft.prompt)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minHeight: 160, maxHeight: 360)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
                .overlay(alignment: .topLeading) {
                    if draft.prompt.isEmpty { Text("What should Claude do first? Leave empty to start at the prompt.").foregroundStyle(.tertiary).padding(14).allowsHitTesting(false) }
                }
                .focused($focused)
                .onKeyPress(.return, phases: .down) { press in
                    if press.modifiers.contains(.command) { tabs.sendDraft(draft); return .handled }
                    return .ignored
                }
            HStack(spacing: 14) {
                Picker("Model", selection: $draft.model) { ForEach(models, id: \.self) { Text($0.capitalized).tag($0) } }.frame(maxWidth: 170)
                if draft.model == "custom" { TextField("model id", text: $draft.customModel).textFieldStyle(.roundedBorder).frame(maxWidth: 220) }
                Picker("Effort", selection: $draft.effort) { ForEach(efforts, id: \.self) { Text($0 == "xhigh" ? "Extra high" : $0.capitalized).tag($0) } }.frame(maxWidth: 190)
                Spacer()
            }
            if !SessionStore.isChats(project.path) {
                HStack(spacing: 12) {
                    Toggle("New git worktree", isOn: $draft.worktree).toggleStyle(.checkbox)
                    if draft.worktree {
                        TextField("branch name (optional)", text: $draft.worktreeName).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                    }
                    Spacer()
                }
            }
            HStack {
                Text("⌘↩ sends. The prompt becomes the session's first turn.").font(.caption).foregroundStyle(.tertiary)
                Spacer()
                Button("Empty Session") { tabs.sendDraft(draft, empty: true) }
                Button(hasPrompt ? "Send" : "Start") { tabs.sendDraft(draft) }.keyboardShortcut(.return, modifiers: .command).buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(maxWidth: 820, alignment: .topLeading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { focused = true }
    }
}
