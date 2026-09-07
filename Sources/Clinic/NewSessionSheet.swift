import SwiftUI
import ClinicCore

/// ADR-032: project, model, worktree. First prompt is typed in the terminal.
struct NewSessionSheet: View {
    @Environment(TabStore.self) private var tabs
    @Environment(SessionStore.self) private var sessions
    @Environment(\.dismiss) private var dismiss

    @State private var projectPath: String = ""
    @State private var modelChoice: String = "default"
    @State private var customModel: String = ""
    @State private var worktree = false

    private let modelChoices = ["default", "sonnet", "opus", "haiku", "custom"]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Session").font(.title2.bold())
            Form {
                Picker("Project", selection: $projectPath) {
                    ForEach(sessions.projects) { p in Text(p.path).tag(p.path) }
                    if !projectPath.isEmpty && !sessions.projects.contains(where: { $0.path == projectPath }) { Text(projectPath).tag(projectPath) }
                }
                HStack { Spacer(); Button("Choose Folder…") { chooseFolder() } }
                Picker("Model", selection: $modelChoice) {
                    ForEach(modelChoices, id: \.self) { Text($0.capitalized).tag($0) }
                }
                if modelChoice == "custom" { TextField("Model id", text: $customModel) }
                Toggle("Start in a new git worktree", isOn: $worktree)
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Start") { start() }.keyboardShortcut(.defaultAction).disabled(projectPath.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear {
            projectPath = tabs.selectedTab?.projectPath ?? sessions.projects.first?.path ?? ""
            loadDefaults()
        }
        .onChange(of: projectPath) { loadDefaults() }
    }

    private func loadDefaults() {
        let m = sessions.state.lastModelByProject[projectPath]
        if let m { if modelChoices.contains(m) { modelChoice = m } else { modelChoice = "custom"; customModel = m } }
        else { modelChoice = UserDefaults.standard.string(forKey: Prefs.defaultModel) ?? "default" }
        worktree = sessions.state.lastWorktreeByProject[projectPath] ?? false
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            projectPath = url.path
            sessions.update { s in if !s.addedProjects.contains(url.path) { s.addedProjects.append(url.path) } }
        }
    }

    private func start() {
        let model: String? = switch modelChoice { case "default": nil; case "custom": customModel.isEmpty ? nil : customModel; default: modelChoice }
        tabs.newSession(projectPath: projectPath, model: model, worktree: worktree)
        dismiss()
    }
}
