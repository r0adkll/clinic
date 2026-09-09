import SwiftUI
import ClinicCore

/// The automation editor (ADR-095): [[ADR-082]]'s composer card, reused, with a schedule bar.
///
/// The reuse is the point rather than a shortcut — this is the same prompt box, the same chip bar
/// inside it, and the same primary action as the New Session screen, so writing a prompt that runs at
/// 9 a.m. feels like writing one that runs now.
///
/// **One spacing scale.** The first version mixed 6, 8, 10, 14 and 20 pt gaps and read as loose; every
/// gap here comes from `Metrics` below, so the rhythm is a decision rather than an accumulation.
/// **Nothing may claim its intrinsic width**: a sheet sizes to its content, so a child that refuses to
/// compress is clipped rather than resized, and because the stack is centred one over-wide row clips
/// every other row's leading text too.
struct AutomationEditorSheet: View {
    @Environment(AutomationsModel.self) private var model
    @Environment(SessionStore.self) private var sessions
    @Environment(\.dismiss) private var dismiss
    @State var draft: AutomationDraft
    @State private var pickingTarget = false
    @FocusState private var promptFocused: Bool

    private enum Metrics {
        /// Between sections.
        static let section: CGFloat = 18
        /// Between a section's own rows.
        static let row: CGFloat = 10
        /// Inside a control — card padding, chip padding.
        static let inset: CGFloat = 12
        static let sheet: CGFloat = 24
        static let width: CGFloat = 660
        static let corner: CGFloat = 12
        static let promptHeight: CGFloat = 200
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.section) {
            header
            composerCard
            section("Schedule") { scheduleControls }
            section("Behaviour") { behaviourControls }
            Divider()
            footer
        }
        .padding(Metrics.sheet)
        .frame(width: Metrics.width)
        .onAppear {
            promptFocused = draft.prompt.isEmpty
            // `-ClinicAutomationPickerOnLaunch YES` (ADR-038): a popover cannot be opened by a
            // synthesised click reliably, and it is the part of this sheet most worth photographing.
            if UserDefaults.standard.bool(forKey: "ClinicAutomationPickerOnLaunch") { pickingTarget = true }
        }
    }

    /// A captioned group. Section labels replace the loose stack the first version had: with four
    /// unlabelled blocks it was never obvious which control belonged to which idea.
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Metrics.row) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
                .kerning(0.6)
            content()
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: Metrics.row) {
            Image(systemName: "alarm.fill")
                .font(.system(size: 22))
                .foregroundStyle(Color.accentColor)
                .frame(width: 28)
            TextField("Automation name", text: $draft.name)
                .textFieldStyle(.plain)
                .font(.title2.weight(.semibold))
            Spacer(minLength: 8)
            targetButton
        }
    }

    // MARK: Target picker

    /// A popover, not a `Menu`. macOS menu items render a title and a system image only, so a project's
    /// real icon — the whole point of showing it — cannot appear in one. The popover also has room for
    /// the path, which is what actually distinguishes two projects with the same folder name.
    private var targetButton: some View {
        Button { pickingTarget = true } label: {
            HStack(spacing: 8) {
                targetGlyph
                Text(targetLabel).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.horizontal, Metrics.inset).padding(.vertical, 7)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $pickingTarget, arrowEdge: .bottom) { targetList }
    }

    @ViewBuilder private var targetGlyph: some View {
        if let project = selectedProject {
            ProjectIcon(project: project, size: 18)
        } else {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 13)).foregroundStyle(Color.accentColor).frame(width: 18)
        }
    }

    private var targetList: some View {
        VStack(alignment: .leading, spacing: 0) {
            targetRow(icon: AnyView(Image(systemName: "bubble.left.and.bubble.right.fill")
                        .font(.system(size: 15)).foregroundStyle(Color.accentColor).frame(width: 24)),
                      title: "Chat",
                      detail: "No repository — runs in Clinic's scratch folder",
                      selected: selectedProject == nil) {
                draft.target = .chat
            }
            if !projects.isEmpty {
                Divider().padding(.vertical, 4)
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(projects, id: \.path) { project in
                            targetRow(icon: AnyView(ProjectIcon(project: project, size: 24)),
                                      title: project.name,
                                      detail: TabFooter.abbreviate(project.path),
                                      selected: selectedProject?.path == project.path) {
                                draft.target = .project(path: project.path)
                            }
                        }
                    }
                }
                .frame(maxHeight: 260)
            }
        }
        .padding(8)
        .frame(width: 340)
    }

    private func targetRow(icon: AnyView, title: String, detail: String, selected: Bool,
                           action: @escaping () -> Void) -> some View {
        TargetRow(icon: icon, title: title, detail: detail, selected: selected, gap: Metrics.row) {
            action()
            pickingTarget = false
        }
    }

    private var projects: [Project] {
        sessions.projects.filter { !SessionStore.isChats($0.path) }
    }

    private var selectedProject: Project? {
        guard case .project(let path) = draft.target else { return nil }
        return sessions.projects.first { $0.path == path }
            ?? Project(path: path)   // a project removed from the sidebar still names its automation
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
                    // 5 pt line-fragment padding, which SwiftUI does not expose.
                    Text("What should this run?")
                        .font(.body)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 5).padding(.top, 8)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $draft.prompt)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    // A fixed height, not a `maxHeight` range: with a range the box grew to fit a long
                    // template prompt and then clipped its last line halfway, so the text appeared to
                    // bleed into the chips below it.
                    .frame(height: Metrics.promptHeight)
                    .focused($promptFocused)
            }
            .padding(Metrics.inset)

            Divider()
            chipBar
        }
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: Metrics.corner))
        .overlay(RoundedRectangle(cornerRadius: Metrics.corner)
            .strokeBorder(promptFocused ? Color.accentColor.opacity(0.55) : Color.black.opacity(0.08),
                          lineWidth: promptFocused ? 2 : 1))
    }

    private var chipBar: some View {
        HStack(spacing: 8) {
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
                    Button(mode.title) { draft.permissionMode = mode }
                }
            } label: {
                chipLabel(icon: draft.permissionMode.wantsWorktree ? "pencil" : "eye",
                          draft.permissionMode.title)
            }
            .menuStyle(.button).buttonStyle(.plain).fixedSize()
            .help(draft.permissionMode.detail)

            // Derived, not chosen: isolation follows the permission posture, so this states what the
            // choice beside it implies rather than offering a second switch that could disagree.
            if case .project = draft.target, draft.permissionMode.wantsWorktree {
                chipLabel(icon: "arrow.trianglehead.branch", "Fresh worktree", muted: true)
                    .help("Because this automation can edit files, each run gets its own git worktree so it never collides with your working tree.")
            }

            Spacer(minLength: 4)
        }
        .padding(.horizontal, Metrics.inset).padding(.vertical, 10)
    }

    private func chipLabel(icon: String, _ text: String, muted: Bool = false) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.caption)
            Text(text).font(.callout)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .foregroundStyle(muted ? AnyShapeStyle(HierarchicalShapeStyle.secondary) : AnyShapeStyle(HierarchicalShapeStyle.primary))
        .background(.quaternary, in: Capsule())
    }

    // MARK: Schedule

    private var scheduleControls: some View {
        VStack(alignment: .leading, spacing: Metrics.row) {
            Picker("", selection: $draft.preset) {
                ForEach(AutomationDraft.PresetKind.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().controlSize(.large)

            HStack(spacing: 8) {
                switch draft.preset {
                case .hourly:
                    Text("On the hour, every hour.").font(.callout).foregroundStyle(.secondary)
                case .everyNHours:
                    Stepper("Every \(draft.everyNHours) hours", value: $draft.everyNHours, in: 2...12)
                        .controlSize(.large)
                case .daily:
                    timePicker
                case .weekly:
                    Picker("", selection: $draft.weekday) {
                        ForEach(0..<7, id: \.self) { i in
                            Text(DateFormatter().weekdaySymbols[i]).tag(i)
                        }
                    }
                    .labelsHidden().controlSize(.large).frame(maxWidth: 150)
                    timePicker
                case .custom:
                    TextField("minute hour day month weekday", text: $draft.customExpression)
                        .textFieldStyle(.roundedBorder).font(.body.monospaced()).controlSize(.large)
                }
                Spacer(minLength: 4)
            }

            summaryLine
        }
    }

    private var timePicker: some View {
        HStack(spacing: 6) {
            Picker("", selection: $draft.hour) {
                ForEach(0..<24, id: \.self) { Text(String(format: "%02d", $0)).tag($0) }
            }
            .labelsHidden().controlSize(.large).frame(width: 70)
            Text(":").foregroundStyle(.secondary)
            Picker("", selection: $draft.minute) {
                ForEach(Array(stride(from: 0, to: 60, by: 5)), id: \.self) { Text(String(format: "%02d", $0)).tag($0) }
            }
            .labelsHidden().controlSize(.large).frame(width: 70)
        }
    }

    @ViewBuilder private var summaryLine: some View {
        if let error = draft.scheduleError {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.callout).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        } else if let schedule = draft.schedule {
            HStack(spacing: 6) {
                Image(systemName: "clock").font(.caption).foregroundStyle(.secondary)
                Text(schedule.summary()).font(.callout)
                if let next = schedule.nextDate(after: Date()) {
                    Text("· next \(next.formatted(date: .abbreviated, time: .shortened))")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
        }
    }

    // MARK: Behaviour

    /// One label-and-control pair per row.
    ///
    /// These began as a single `HStack` of three `.fixedSize()` controls needing ~650 pt of labels —
    /// wider than the sheet, so SwiftUI centred the row and clipped it at both edges, taking every
    /// other row's leading text with it. Two pairs per row then made the `Grid` share width between
    /// the two menus and truncate the longer one.
    private var behaviourControls: some View {
        Grid(alignment: .leading, horizontalSpacing: Metrics.row, verticalSpacing: Metrics.row) {
            GridRow {
                Text("Notify").font(.callout).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                Picker("", selection: $draft.notifyOn) {
                    ForEach(Automation.NotifyPolicy.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden().controlSize(.large)
            }
            GridRow {
                Text("Missed runs").font(.callout).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                Picker("", selection: $draft.catchUp) {
                    ForEach(Automation.CatchUpPolicy.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden().controlSize(.large)
            }
            GridRow {
                Text("Give up after").font(.callout).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                Stepper("\(draft.stallMinutes) min waiting", value: $draft.stallMinutes, in: 1...240, step: 5)
                    .controlSize(.large)
                    .help("A run that sits waiting on you past this is stopped and recorded, rather than holding a worktree until morning.")
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(alignment: .center, spacing: Metrics.row) {
            note
            Spacer(minLength: 8)
            Button("Cancel") { model.draft = nil; dismiss() }
                .keyboardShortcut(.cancelAction).controlSize(.large)
            Button(draft.editing == nil ? "Create" : "Save") { save() }
                .keyboardShortcut(.defaultAction).controlSize(.large)
                .buttonStyle(.borderedProminent)
                .disabled(!draft.isValid)
        }
    }

    @ViewBuilder private var note: some View {
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
    }

    private func save() {
        let existing = draft.editing.flatMap { id in model.automations.first { $0.id == id } }
        guard let automation = draft.makeAutomation(existing: existing) else { return }
        if draft.editing == nil { model.add(automation) } else { model.update(automation) }
        model.draft = nil
        dismiss()
    }
}


/// A row in the target popover. Its own view because a plain `Button` list has no hover feedback, and
/// a list of rows that do not light up under the pointer reads as disabled rather than clickable.
private struct TargetRow: View {
    let icon: AnyView
    let title: String
    let detail: String
    let selected: Bool
    let gap: CGFloat
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: gap) {
                icon
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.body).lineLimit(1)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.head)
                }
                Spacer(minLength: 6)
                if selected {
                    Image(systemName: "checkmark").font(.caption.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 7)
            .background(hovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
                        in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
