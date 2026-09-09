import SwiftUI
import ClinicCore

/// The automation editor (ADR-095): [[ADR-082]]'s composer card, reused, with a schedule bar.
///
/// The reuse is the point rather than a shortcut — this is the same prompt box, the same chip bar
/// inside it, and the same send-shaped primary action as the New Session screen, so writing a prompt
/// that runs at 9 a.m. feels like writing one that runs now.
struct AutomationEditorSheet: View {
    @Environment(AutomationsModel.self) private var model
    @Environment(SessionStore.self) private var sessions
    @Environment(\.dismiss) private var dismiss
    @State var draft: AutomationDraft
    @FocusState private var promptFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            composerCard
            scheduleBar
            behaviourRow
            footer
        }
        .padding(20)
        // A sheet sizes to its content, so anything inside that refuses to compress is clipped rather
        // than resized. Every row below must be able to shrink to this.
        .frame(width: 640)
        .onAppear { promptFocused = draft.prompt.isEmpty }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "alarm.fill").font(.title3).foregroundStyle(Color.accentColor)
            TextField("Automation name", text: $draft.name)
                .textFieldStyle(.plain)
                .font(.title3.weight(.semibold))
            Spacer(minLength: 8)
            targetPicker
        }
    }

    private var targetPicker: some View {
        Menu {
            Button {
                draft.target = .chat
            } label: {
                Label("Chat — no repository", systemImage: "bubble.left.and.bubble.right")
            }
            Divider()
            ForEach(sessions.projects.filter { !SessionStore.isChats($0.path) }, id: \.path) { project in
                Button((project.path as NSString).lastPathComponent) {
                    draft.target = .project(path: project.path)
                }
            }
        } label: {
            Label(targetLabel, systemImage: targetIcon)
        }
        .menuStyle(.button).fixedSize()
    }

    private var targetIcon: String {
        if case .chat = draft.target { return "bubble.left.and.bubble.right" }
        return "folder"
    }

    private var targetLabel: String {
        switch draft.target {
        case .chat: "Chat"
        case .project(let path): (path as NSString).lastPathComponent
        }
    }

    // MARK: Composer card

    private var composerCard: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                if draft.prompt.isEmpty {
                    // ADR-082's placeholder fix, kept: offset only by the NSTextContainer's own
                    // 5pt line-fragment padding, which SwiftUI does not expose.
                    Text("What should this run?")
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 5).padding(.top, 8)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $draft.prompt)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    // A fixed height, not a range: with `maxHeight` the box grew to fit a long
                    // template prompt and then clipped the last line halfway through, so the text
                    // appeared to bleed into the chips below it.
                    .frame(height: 170)
                    .focused($promptFocused)
            }
            .padding(10)

            Divider()
            chipBar
        }
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(promptFocused ? Color.accentColor.opacity(0.6) : Color.clear, lineWidth: 2))
    }

    private var chipBar: some View {
        HStack(spacing: 6) {
            Menu {
                Button("Default") { draft.model = nil }
                Divider()
                ForEach(["opus", "sonnet", "haiku"], id: \.self) { m in
                    Button(m.capitalized) { draft.model = m }
                }
            } label: {
                chipLabel(icon: "cpu", draft.model?.capitalized ?? "Default model")
            }
            .menuStyle(.button).buttonStyle(.plain).fixedSize()

            Menu {
                ForEach(Automation.PermissionMode.allCases, id: \.self) { mode in
                    Button {
                        draft.permissionMode = mode
                    } label: {
                        Text(mode.title)
                    }
                }
            } label: {
                chipLabel(icon: draft.permissionMode.wantsWorktree ? "pencil" : "eye", draft.permissionMode.title)
            }
            .menuStyle(.button).buttonStyle(.plain).fixedSize()
            .help(draft.permissionMode.detail)

            // Derived, not chosen: isolation follows the permission posture, so this states what the
            // choice above implies rather than offering a second switch that could disagree with it.
            if case .project = draft.target, draft.permissionMode.wantsWorktree {
                chipLabel(icon: "arrow.trianglehead.branch", "Fresh worktree per run")
                    .help("Because this automation can edit files, each run gets its own git worktree so it never collides with your working tree.")
            }

            Spacer(minLength: 4)
        }
        .padding(.horizontal, 10).padding(.bottom, 10)
    }

    private func chipLabel(icon: String, _ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.caption2)
            Text(text).font(.caption)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(.quaternary, in: Capsule())
    }

    // MARK: Schedule

    private var scheduleBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: $draft.preset) {
                ForEach(AutomationDraft.PresetKind.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()

            HStack(spacing: 8) {
                switch draft.preset {
                case .hourly:
                    Text("On the hour, every hour.").font(.callout).foregroundStyle(.secondary)
                case .everyNHours:
                    Stepper("Every \(draft.everyNHours) hours", value: $draft.everyNHours, in: 2...12)
                        .fixedSize()
                case .daily:
                    timePicker
                case .weekly:
                    Picker("", selection: $draft.weekday) {
                        ForEach(0..<7, id: \.self) { i in
                            Text(DateFormatter().weekdaySymbols[i]).tag(i)
                        }
                    }
                    .labelsHidden().frame(maxWidth: 140)
                    timePicker
                case .custom:
                    TextField("minute hour day month weekday", text: $draft.customExpression)
                        .textFieldStyle(.roundedBorder).font(.body.monospaced())
                }
                Spacer(minLength: 4)
            }

            if let error = draft.scheduleError {
                Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            } else if let schedule = draft.schedule, let next = schedule.nextDate(after: Date()) {
                Text("\(schedule.summary()) — next \(next.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var timePicker: some View {
        HStack(spacing: 4) {
            Picker("", selection: $draft.hour) {
                ForEach(0..<24, id: \.self) { Text(String(format: "%02d", $0)).tag($0) }
            }
            .labelsHidden().fixedSize()
            Text(":")
            Picker("", selection: $draft.minute) {
                ForEach(Array(stride(from: 0, to: 60, by: 5)), id: \.self) { Text(String(format: "%02d", $0)).tag($0) }
            }
            .labelsHidden().fixedSize()
        }
    }

    // MARK: Behaviour

    /// Two lines, not one.
    ///
    /// These were a single `HStack` of three `.fixedSize()` controls, whose labels alone need about
    /// 650 pt — wider than the sheet, so SwiftUI centred the row and clipped it at both edges, taking
    /// every other row's leading text with it. Nothing here may claim its intrinsic width: the labels
    /// are captions outside the controls, and the menus shrink.
    /// One label-and-control pair per row.
    ///
    /// These began as a single `HStack` of three `.fixedSize()` controls needing ~650 pt of labels —
    /// wider than the sheet, so SwiftUI centred the row and clipped it at both edges, taking every
    /// other row's leading text with it. Two pairs per row then made the `Grid` share width between
    /// the two menus and truncate the longer one. Nothing here may claim its intrinsic width, and
    /// nothing shares a column with a control that has a different natural size.
    private var behaviourRow: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
            GridRow {
                Text("Notify").font(.callout).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                Picker("", selection: $draft.notifyOn) {
                    ForEach(Automation.NotifyPolicy.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden()
            }
            GridRow {
                Text("Missed runs").font(.callout).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                Picker("", selection: $draft.catchUp) {
                    ForEach(Automation.CatchUpPolicy.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden()
            }
            GridRow {
                Text("Give up after").font(.callout).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                Stepper("\(draft.stallMinutes) min waiting", value: $draft.stallMinutes, in: 1...240, step: 5)
                    .help("A run that sits waiting on you past this is stopped and recorded, rather than holding a worktree until morning.")
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            if draft.missingProject {
                Label("This template works on a repository — pick a project above.",
                      systemImage: "folder.badge.questionmark")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if draft.permissionMode == .bypassPermissions {
                Label("This automation asks for nothing at all before running commands.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Runs detached, like `claude --bg`. You can open and continue any run afterwards.")
                    .font(.caption).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Cancel") { model.draft = nil; dismiss() }.keyboardShortcut(.cancelAction)
            Button(draft.editing == nil ? "Create" : "Save") { save() }
                .keyboardShortcut(.defaultAction)
                .disabled(!draft.isValid)
        }
    }

    private func save() {
        let existing = draft.editing.flatMap { id in model.automations.first { $0.id == id } }
        guard let automation = draft.makeAutomation(existing: existing) else { return }
        if draft.editing == nil { model.add(automation) } else { model.update(automation) }
        model.draft = nil
        dismiss()
    }
}
