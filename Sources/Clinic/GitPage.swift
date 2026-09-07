import SwiftUI
import ClinicCore

/// Right-column git page for a session tab (ADR-052).
struct GitPage: View {
    let tab: Tab
    @Bindable var model: GitPageModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if !model.isBound {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !model.hasRepo {
                ContentUnavailableView("Not a git repository", systemImage: "arrow.triangle.branch", description: Text(tab.pwd ?? tab.projectPath))
            } else {
                VSplitView {
                    changes.frame(minHeight: 140)
                    diffArea.frame(minHeight: 160)
                    commits.frame(minHeight: 80, idealHeight: 160)
                }
            }
        }
        .frame(minWidth: 380)
        .alert(model.confirmDiscardTitle, isPresented: Binding(get: { model.confirmDiscard != nil }, set: { if !$0 { model.confirmDiscard = nil } })) {
            Button("Discard", role: .destructive) { model.confirmDiscard?(); model.confirmDiscard = nil }
            Button("Cancel", role: .cancel) { model.confirmDiscard = nil }
        } message: { Text("This cannot be undone.") }
        .task(id: tab.pwd) { await model.bind(directory: tab.pwd ?? tab.projectPath) }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.branch").foregroundStyle(.secondary)
            Text(model.status?.branch ?? (model.status?.isDetached == true ? "detached HEAD" : "—")).font(.headline)
            if let s = model.status, s.ahead + s.behind > 0 {
                Text("↑\(s.ahead) ↓\(s.behind)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Spacer()
            if model.isLoading { ProgressView().controlSize(.small) }
            Button { Task { await model.reload() } } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless).help("Reload")
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.bar)
    }

    private var changes: some View {
        VStack(spacing: 0) {
            List {
                Section {
                    ForEach(model.unstagedFiles) { file in
                        FileRow(file: file, staged: false, selected: model.selectedPath == file.path && !model.selectedStaged, model: model)
                    }
                } header: {
                    HStack { Text("Unstaged (\(model.unstagedFiles.count))"); Spacer(); Button("Stage All") { model.stageAll() }.controlSize(.mini).disabled(model.unstagedFiles.isEmpty) }
                }
                Section {
                    ForEach(model.stagedFiles) { file in
                        FileRow(file: file, staged: true, selected: model.selectedPath == file.path && model.selectedStaged, model: model)
                    }
                } header: {
                    HStack { Text("Staged (\(model.stagedFiles.count))"); Spacer(); Button("Unstage All") { model.unstageAll() }.controlSize(.mini).disabled(model.stagedFiles.isEmpty) }
                }
            }
            .listStyle(.inset)
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.red).lineLimit(2).padding(.horizontal, 10).padding(.vertical, 4) }
            commitBox
        }
    }

    private var commitBox: some View {
        VStack(spacing: 6) {
            TextField("Commit message", text: $model.commitMessage, axis: .vertical)
                .lineLimit(2...5).textFieldStyle(.roundedBorder).font(.callout)
            HStack {
                Spacer()
                Button("Amend") { model.commit(amend: true) }.disabled(model.commits.isEmpty)
                Button("Commit") { model.commit() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(model.stagedFiles.isEmpty || model.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .controlSize(.small)
        }
        .padding(8)
        .background(.bar)
    }

    @ViewBuilder
    private var diffArea: some View {
        if let file = model.diff {
            if model.selectedStaged {
                DiffView(file: file, onUnstageHunk: { model.unstage(hunk: $0) })
            } else if file.isNew || file.hunks.isEmpty {
                DiffView(file: file)
            } else {
                DiffView(file: file, onStageHunk: { model.stage(hunk: $0) }, onDiscardHunk: { model.discard(hunk: $0) })
            }
        } else {
            ContentUnavailableView("No file selected", systemImage: "doc.text", description: Text("Pick a change above."))
        }
    }

    private var commits: some View {
        List(model.commits) { c in
            HStack(alignment: .top, spacing: 8) {
                Text(c.shortSha).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(c.subject).lineLimit(1)
                    Text("\(c.author) · \(c.date, format: .relative(presentation: .named))").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .contextMenu { Button("Copy SHA") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(c.sha, forType: .string) } }
        }
        .listStyle(.inset)
        .overlay { if model.commits.isEmpty { Text("No commits ahead of the default branch").font(.caption).foregroundStyle(.tertiary) } }
    }
}

struct FileRow: View {
    let file: GitFileStatus
    let staged: Bool
    let selected: Bool
    let model: GitPageModel
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Text(glyph).font(.system(.caption, design: .monospaced).weight(.bold)).foregroundStyle(color).frame(width: 14)
            Text(file.path).lineLimit(1).truncationMode(.head)
            Spacer()
            if hovering || selected {
                if staged { Button("Unstage") { model.unstage(file) } }
                else {
                    Button("Stage") { model.stage(file) }
                    Button { model.discard(file) } label: { Image(systemName: "trash") }.help(file.isUntracked ? "Delete" : "Discard")
                }
            }
        }
        .controlSize(.mini)
        .contentShape(Rectangle())
        .listRowBackground(selected ? Color.accentColor.opacity(0.15) : Color.clear)
        .onTapGesture { model.select(file, staged: staged) }
        .onHover { hovering = $0 }
    }

    private var kind: GitChangeKind? { staged ? file.index : file.worktree }
    private var glyph: String {
        if file.isConflicted { return "!" }
        switch kind { case .added, .untracked: return "A"; case .deleted: return "D"; case .renamed: return "R"; case .copied: return "C"; case .typeChanged: return "T"; case .unmerged: return "U"; case .modified, nil: return "M" }
    }
    private var color: Color {
        if file.isConflicted { return .red }
        switch kind { case .added, .untracked: return .green; case .deleted: return .red; case .renamed, .copied: return .blue; default: return .orange }
    }
}
