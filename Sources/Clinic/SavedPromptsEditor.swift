import SwiftUI
import ClinicCore

/// Managing saved prompts from the composer (ADR-161): title, text, scope, order and delete, in a
/// popover off the Saved row. Edits land as they are typed, like the draft they sit under.
struct SavedPromptsEditor: View {
    @Environment(ComposerLibraryModel.self) private var library
    let projectPath: String
    let projectName: String

    private var projectPrompts: [SavedPrompt] { library.savedPrompts.filter { $0.projectPath == projectPath } }
    private var everyPrompts: [SavedPrompt] { library.savedPrompts.filter { $0.projectPath == nil } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Saved Prompts").font(.headline)
                Spacer()
                Text("Drag to reorder").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 8)
            if projectPrompts.isEmpty && everyPrompts.isEmpty {
                Text("Nothing saved. The bookmark beside Send saves the prompt you've typed.")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(24)
            } else {
                List {
                    if !projectPrompts.isEmpty {
                        Section(projectName) {
                            ForEach(projectPrompts) { row($0) }
                                .onMove { library.movePrompts(in: projectPath, fromOffsets: $0, toOffset: $1) }
                        }
                    }
                    if !everyPrompts.isEmpty {
                        Section("Every Project") {
                            ForEach(everyPrompts) { row($0) }
                                .onMove { library.movePrompts(in: nil, fromOffsets: $0, toOffset: $1) }
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
        .frame(width: 460, height: 400)
        // A prompt emptied here is kept while it is being edited, and dropped once the editor closes.
        .onDisappear { library.removeBlankPrompts() }
    }

    private func row(_ prompt: SavedPrompt) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 3) {
                TextField("Title", text: Binding(get: { prompt.title ?? "" }, set: { library.updatePrompt(prompt.id, title: $0) }),
                          prompt: Text(NewSessionScreen.snippet(prompt.text)))
                    .textFieldStyle(.plain).font(.callout.weight(.medium))
                    .accessibilityLabel("Title")
                TextField("Prompt", text: Binding(get: { prompt.text }, set: { library.updatePrompt(prompt.id, text: $0) }),
                          prompt: Text("Empty prompts are removed when this closes"), axis: .vertical)
                    .textFieldStyle(.plain).font(.callout).foregroundStyle(.secondary)
                    .lineLimit(1...6)
                    .accessibilityLabel("Prompt text")
            }
            Spacer(minLength: 4)
            Button {
                library.setScope(of: prompt.id, projectPath: prompt.projectPath == nil ? projectPath : nil)
            } label: {
                Image(systemName: prompt.projectPath == nil ? "globe" : "folder")
                    .frame(width: 20, height: 20).contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .help(prompt.projectPath == nil ? "Offered in every project. Click to offer it only in \(projectName)."
                                             : "Offered only in \(projectName). Click to offer it in every project.")
            .accessibilityLabel(prompt.projectPath == nil ? "Offer only in \(projectName)" : "Offer in every project")
            Button { library.deletePrompt(prompt.id) } label: {
                Image(systemName: "trash").frame(width: 20, height: 20).contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .help("Delete saved prompt")
            .accessibilityLabel("Delete saved prompt")
        }
        .padding(.vertical, 3)
    }
}
