import SwiftUI
import ClinicCore

/// One automation: what it does, when, and every run it has produced (ADR-095).
struct AutomationDetail: View {
    @Environment(AutomationsModel.self) private var model
    @Environment(SessionStore.self) private var sessions
    @Environment(TabStore.self) private var tabs
    let automation: Automation

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                title
                summaryChips
                promptCard
                if automation.permissionMode.wantsWorktree { worktreeNote }
                history
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var runs: [AutomationRun] { model.runs(for: automation) }

    private var title: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(automation.name).font(.title2.weight(.semibold))
                Text(automation.schedule.summary()).font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Toggle("Enabled", isOn: Binding(get: { automation.isEnabled },
                                            set: { model.setEnabled(automation, $0) }))
                .toggleStyle(.switch).labelsHidden()
                .help(automation.isEnabled ? "Enabled" : "Disabled")
            Button("Run Now") { model.runNow(automation) }
            Menu {
                Button("Edit…") { model.draft = AutomationDraft(automation: automation) }
                Button("Duplicate") { model.duplicate(automation) }
                Divider()
                Button("Delete", role: .destructive) { model.delete(automation) }
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.button).buttonStyle(.plain).fixedSize()
        }
    }

    private var summaryChips: some View {
        HStack(spacing: 6) {
            chip(icon: targetIcon, targetLabel)
            chip(icon: automation.permissionMode.wantsWorktree ? "pencil" : "eye", automation.permissionMode.title)
                .help(automation.permissionMode.detail)
            if let model = automation.model { chip(icon: "cpu", model) }
            chip(icon: "bell", automation.notifyOn.title)
            chip(icon: "arrow.uturn.backward", automation.catchUp.title)
        }
    }

    private func chip(icon: String, _ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.caption2)
            Text(text).font(.caption)
        }
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(.quaternary, in: Capsule())
    }

    private var targetIcon: String {
        if case .chat = automation.target { return "bubble.left.and.bubble.right" }
        return "folder"
    }

    private var targetLabel: String {
        switch automation.target {
        case .chat: "Chat"
        case .project(let path): (path as NSString).lastPathComponent
        }
    }

    private var promptCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Prompt").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(automation.prompt)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    /// The retention rule, said on the screen rather than left to be discovered: most runs leave
    /// nothing behind, and the ones that do are never removed without asking.
    private var worktreeNote: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "arrow.trianglehead.branch").foregroundStyle(.secondary)
            Text("Each run gets a fresh git worktree so it never collides with your working tree. A run that ends with no commits and a clean tree is removed automatically; one that produced work is kept until you remove it.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: History

    private var history: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Runs").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if let next = nextRun {
                    Text("Next \(next.formatted(.relative(presentation: .named)))")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
            if runs.isEmpty {
                Text("No runs yet.").font(.callout).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
            } else {
                VStack(spacing: 0) {
                    ForEach(runs) { run in
                        AutomationRunRow(run: run, automation: automation)
                        if run.id != runs.last?.id { Divider() }
                    }
                }
                .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var nextRun: Date? {
        guard automation.isEnabled else { return nil }
        let since = automation.lastFiredAt ?? automation.createdAt
        return automation.schedule.nextDate(after: since)
    }
}

/// One row of run history. The session it produced is the point, so opening it is the primary action.
private struct AutomationRunRow: View {
    @Environment(AutomationsModel.self) private var model
    @Environment(SessionStore.self) private var sessions
    @Environment(TabStore.self) private var tabs
    let run: AutomationRun
    let automation: Automation
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            AutomationOutcomeBadge(outcome: run.outcome)
            VStack(alignment: .leading, spacing: 1) {
                Text(run.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.callout)
                HStack(spacing: 6) {
                    Text(run.outcome.title).font(.caption).foregroundStyle(.secondary)
                    if let d = run.duration, run.outcome != .running {
                        Text("· \(Duration.seconds(d).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow)))")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                    if run.holdsWorktree, let name = run.worktreeName {
                        Label(name, systemImage: "arrow.trianglehead.branch")
                            .font(.caption2).foregroundStyle(.orange)
                            .help("This run's worktree was kept because it holds work")
                    }
                }
            }
            Spacer(minLength: 8)
            if hovering { actions }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { open() }
    }

    @ViewBuilder private var actions: some View {
        if run.sessionId != nil {
            Button("Open") { open() }.buttonStyle(.link).font(.caption)
        }
        if run.outcome == .running {
            Button("Stop") { model.stopRun(run) }.buttonStyle(.link).font(.caption)
        }
        if run.holdsWorktree {
            Button("Remove…") { model.confirmRemoval(of: run, automation: automation) }
                .buttonStyle(.link).font(.caption)
                .help("Runs `claude rm`, which deletes the worktree and its branch")
        }
    }

    /// Opens the run's session. It is a background agent, so this attaches rather than resumes —
    /// exactly the path ADR-061 already built.
    private func open() {
        guard let sessionId = run.sessionId, let summary = sessions.sessions[sessionId] else { return }
        tabs.open(session: summary)
    }
}

/// `claude rm` takes the worktree *and its branch*, so the removal says so before it runs — the
/// confirmation shape ADR-084 established for every CLI mutation.
struct AutomationRemovalSheet: View {
    @Environment(AutomationsModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let pending: AutomationsModel.PendingRemoval

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Remove this run?").font(.headline)
            Text("This run of **\(pending.automationName)** kept its worktree because it holds work. Removing it deletes the worktree **and its branch**, along with anything uncommitted in it.")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            if let name = pending.run.worktreeName {
                Label(name, systemImage: "arrow.trianglehead.branch").font(.callout.monospaced())
            }
            Text(pending.command)
                .font(.caption.monospaced())
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            HStack {
                Spacer()
                Button("Cancel") { model.pendingRemoval = nil; dismiss() }.keyboardShortcut(.cancelAction)
                Button("Remove", role: .destructive) { model.commitPendingRemoval(); dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 460)
    }
}
