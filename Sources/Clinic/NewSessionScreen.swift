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
    private enum Field { case prompt, branch }

    @Environment(TabStore.self) private var tabs
    @Environment(SessionStore.self) private var sessions
    @Bindable var draft: NewSessionDraft
    @FocusState private var focus: Field?
    @State private var branch: String?

    private let models = ["default", "sonnet", "opus", "haiku", "custom"]
    private let efforts = ["default", "low", "medium", "high", "xhigh", "max"]
    private var project: Project { Project(path: draft.projectPath) }
    private var isChats: Bool { SessionStore.isChats(project.path) }
    private var hasPrompt: Bool { !draft.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    /// The wash behind the card takes the icon's own colour, so a project's start screen looks like its icon.
    private var tint: Color {
        _ = ProjectIconCache.shared.revision
        return isChats ? .accentColor : ProjectIconCache.shared.tint(for: project.path)
    }

    /// This project's last few opening prompts, newest first, deduplicated (ADR-071 quick starts).
    private var recentPrompts: [String] {
        var seen = Set<String>(), out: [String] = []
        for s in sessions.sessions(in: project) {
            let p = (s.firstPrompt ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard p.count > 3, !p.hasPrefix("<"), seen.insert(p.lowercased()).inserted else { continue }
            out.append(p)
            if out.count == 3 { break }
        }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            composer
            if !recentPrompts.isEmpty { quickStarts }
            footer
        }
        .padding(24)
        .frame(maxWidth: 720, alignment: .topLeading)
        .background {
            // A wash of the project's own colour behind the card, so each start screen is recognisable at a glance.
            RadialGradient(colors: [tint.opacity(0.22), .clear], center: .center, startRadius: 0, endRadius: 380)
                .blur(radius: 40).padding(-120).allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .overlay(alignment: .topTrailing) {
            Button { tabs.discardDraft(draft) } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless).help("Discard (⌘W)").padding(16)
        }
        .onAppear { focus = .prompt }
        .task(id: draft.projectPath) {
            guard !isChats else { return }
            branch = await GitRepository.discover(from: draft.projectPath)?.currentBranch()
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            ProjectIcon(project: project, size: 40)
            VStack(alignment: .leading, spacing: 1) {
                Text(isChats ? "New chat" : project.name).font(.title2.weight(.semibold))
                Text(TabFooter.abbreviate(draft.projectPath))
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.head)
            }
            Spacer(minLength: 8)
            if let branch {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.branch").imageScale(.small)
                    Text(branch)
                    if draft.worktree {
                        Image(systemName: "arrow.right").imageScale(.small).opacity(0.6)
                        Text(trimmedWorktreeName.isEmpty ? "new worktree" : trimmedWorktreeName)
                            .fontWeight(.medium)
                    }
                }
                .font(.caption).lineLimit(1)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(draft.worktree ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.07), in: Capsule())
                .foregroundStyle(draft.worktree ? Color.accentColor : Color.secondary)
                .help(draft.worktree ? "The session gets its own branch off \(branch)" : "Current branch")
            }
        }
        .padding(.bottom, 2)
    }

    // MARK: Composer

    private var composer: some View {
        VStack(spacing: 0) {
            TextEditor(text: $draft.prompt)
                .font(.body)
                .scrollContentBackground(.hidden)
                // The placeholder rides inside the editor's own padding so it lands on the text baseline;
                // the 5pt inset is NSTextContainer's line-fragment padding, which TextEditor does not expose.
                .overlay(alignment: .topLeading) {
                    if draft.prompt.isEmpty {
                        Text(isChats ? "What do you want to talk about?" : "What should Claude do first?")
                            .font(.body).foregroundStyle(.tertiary)
                            .padding(.leading, 5).allowsHitTesting(false)
                    }
                }
                .padding(.horizontal, 10).padding(.top, 10)
                .frame(minHeight: 88, maxHeight: 168)
                .focused($focus, equals: .prompt)
                .onKeyPress(.return, phases: .down) { press in
                    if press.modifiers.contains(.command) { tabs.sendDraft(draft); return .handled }
                    return .ignored
                }
            controlBar
            if draft.worktree, !isChats { worktreeRow }
        }
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(focus == .prompt ? Color.accentColor.opacity(0.55) : Color(nsColor: .separatorColor),
                              lineWidth: focus == .prompt ? 1.5 : 1)
        }
        .animation(.easeOut(duration: 0.12), value: focus)
        .animation(.easeOut(duration: 0.16), value: draft.worktree)
    }

    /// The settings that shape the launch sit inside the box they configure, next to the button that sends it.
    private var controlBar: some View {
        HStack(spacing: 8) {
            modelMenu
            if draft.model == "custom" {
                TextField("model id", text: $draft.customModel)
                    .textFieldStyle(.plain).font(.callout).frame(maxWidth: 130)
            }
            effortMenu
            if !isChats { worktreeChip }
            Spacer(minLength: 4)
            Button { tabs.sendDraft(draft) } label: {
                Image(systemName: hasPrompt ? "arrow.up" : "play.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(Color.accentColor, in: Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: .command)
            .help(hasPrompt ? "Send (⌘↩)" : "Start at Claude's prompt (⌘↩)")
        }
        .padding(.horizontal, 8).padding(.vertical, 7)
        .overlay(alignment: .top) { Divider().opacity(0.6) }
    }

    private var modelMenu: some View {
        Menu {
            Picker("Model", selection: $draft.model) {
                ForEach(models, id: \.self) { Text($0 == "default" ? "Default" : $0.capitalized).tag($0) }
            }.pickerStyle(.inline).labelsHidden()
        } label: {
            chip(active: draft.model != "default") {
                Image(systemName: "cpu").imageScale(.small)
                Text(draft.model == "default" ? "Auto" : draft.model.capitalized)
            }
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help("Model")
    }

    private var effortMenu: some View {
        Menu {
            Picker("Effort", selection: $draft.effort) {
                ForEach(efforts, id: \.self) { Text($0 == "default" ? "Default" : $0 == "xhigh" ? "Extra high" : $0.capitalized).tag($0) }
            }.pickerStyle(.inline).labelsHidden()
        } label: {
            chip(active: draft.effort != "default") {
                let level = efforts.firstIndex(of: draft.effort) ?? 0
                if level == 0 {
                    Image(systemName: "gauge.with.dots.needle.bottom.50percent").imageScale(.small)
                } else {
                    EffortBars(level: level)
                }
                Text(draft.effort == "default" ? "Auto" : draft.effort == "xhigh" ? "Extra high" : draft.effort.capitalized)
            }
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help("Reasoning effort")
    }

    /// A boolean sitting between two menus needs to say which it is, so the chip carries its own on/off mark.
    private var worktreeChip: some View {
        Button {
            draft.worktree.toggle()
            focus = draft.worktree ? .branch : .prompt
        } label: {
            chip(active: draft.worktree) {
                Image(systemName: "arrow.triangle.branch").imageScale(.small)
                Text("Worktree")
                Image(systemName: draft.worktree ? "checkmark.circle.fill" : "circle")
                    .imageScale(.small).opacity(draft.worktree ? 1 : 0.5)
            }
        }
        .buttonStyle(.plain)
        .help("Run this session in a new git worktree")
    }

    /// Revealed under the control bar: what gets created, a field with room to type it, and what an empty
    /// name means — none of which fitted in a pill.
    private var worktreeRow: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label("New branch from \(branch ?? "the current branch")", systemImage: "arrow.triangle.branch")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                TextField("branch name", text: $draft.worktreeName)
                    .textFieldStyle(.roundedBorder).font(.callout)
                    .frame(maxWidth: 240)
                    .focused($focus, equals: .branch)
                    .onSubmit { tabs.sendDraft(draft) }
                Text(trimmedWorktreeName.isEmpty
                     ? "Claude names the worktree if you leave this empty."
                     : ".claude/worktrees/\(trimmedWorktreeName)")
                    .font(.caption.monospaced()).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.head)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Divider().opacity(0.6) }
    }

    private var trimmedWorktreeName: String { draft.worktreeName.trimmingCharacters(in: .whitespaces) }

    // MARK: Quick starts

    private var quickStarts: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(recentPrompts, id: \.self) { prompt in
                    Button {
                        draft.prompt = prompt
                        focus = .prompt
                    } label: {
                        chip {
                            Image(systemName: "clock.arrow.circlepath").imageScale(.small)
                            Text(Self.snippet(prompt)).lineLimit(1).truncationMode(.tail).frame(maxWidth: 230, alignment: .leading)
                        }
                    }
                    .buttonStyle(.plain)
                    .help(prompt)
                }
            }
            .padding(.horizontal, 1)
        }
        .scrollIndicators(.never)
        .frame(maxWidth: .infinity, alignment: .leading)
        .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.93),
                                     .init(color: .clear, location: 1)],
                             startPoint: .leading, endPoint: .trailing))
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Text(hint).font(.caption).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
            Spacer()
            Button("Empty Session") { tabs.sendDraft(draft, empty: true) }
        }
    }

    private var hint: String {
        "⌘↩ sends the prompt as the first turn. Empty Session starts Claude at its own prompt."
    }

    /// One pill in the control bar; `active` tints it with the accent colour so a non-default setting is visible.
    private func chip<Content: View>(active: Bool = false, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 4) { content() }
            .font(.callout)
            .foregroundStyle(active ? Color.accentColor : Color.secondary)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(active ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.07), in: Capsule())
            .overlay(Capsule().strokeBorder(active ? Color.accentColor.opacity(0.35) : Color.primary.opacity(0.08)))
            .contentShape(Capsule())
    }
}

extension NewSessionScreen {
    /// One line of a past first prompt, short enough to sit in a pill.
    static func snippet(_ prompt: String, limit: Int = 44) -> String {
        let flat = prompt.replacingOccurrences(of: "\n", with: " ").split(separator: " ").joined(separator: " ")
        return flat.count <= limit ? flat : String(flat.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
    }
}

/// Five rising bars, filled to `level` (0 = CLI default, all dim), so effort reads as the ordered scale it is.
private struct EffortBars: View {
    let level: Int

    var body: some View {
        HStack(alignment: .bottom, spacing: 1.5) {
            ForEach(1...5, id: \.self) { i in
                Capsule()
                    .fill(i <= level ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: 2.5, height: 3 + CGFloat(i) * 1.8)
            }
        }
        .frame(height: 11, alignment: .bottom)
    }
}
