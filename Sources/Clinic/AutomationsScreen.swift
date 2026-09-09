import SwiftUI
import ClinicCore

/// The Automations screen (ADR-095): prompts that run on a schedule, and what came of them.
///
/// Two states over one split, as the ADR settled: with nothing selected the detail side is the
/// **template gallery**, which is how most automations will be created; with something selected it is
/// that automation's settings and its run history. The history is the payoff — an automation is a
/// stream of readable sessions, not a log file.
struct AutomationsScreen: View {
    @Environment(AutomationsModel.self) private var model
    @Environment(SessionStore.self) private var sessions
    @Environment(TabStore.self) private var tabs

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                automationList.frame(width: 320)
                Divider()
                Group {
                    if let automation = selected {
                        AutomationDetail(automation: automation)
                    } else {
                        AutomationGallery(defaultProject: defaultProject)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            footer
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(item: $model.draft) { AutomationEditorSheet(draft: $0) }
        .sheet(item: $model.pendingRemoval) { AutomationRemovalSheet(pending: $0) }
    }

    private var selected: Automation? {
        model.automations.first { $0.id == model.selectedId }
    }

    /// Chats has no repository, so it is a poor thing to land on when creating a project automation.
    private var defaultProject: String? {
        sessions.projects.first { !SessionStore.isChats($0.path) }?.path ?? sessions.projects.first?.path
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "alarm.fill").font(.title3).foregroundStyle(Color.accentColor)
            Text("Automations").font(.title3.weight(.semibold))
            Text("Prompts that run on a schedule").font(.callout).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Button {
                model.draft = AutomationDraft(target: defaultProject.map { .project(path: $0) } ?? .chat)
            } label: {
                Label("New Automation", systemImage: "plus")
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    // MARK: List

    private var automationList: some View {
        @Bindable var model = model
        return Group {
            if model.automations.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "alarm.fill").font(.largeTitle).foregroundStyle(.tertiary)
                    Text("No automations yet").font(.callout).foregroundStyle(.secondary)
                    Text("Pick a template on the right, or start from blank.")
                        .font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity).padding(24)
            } else {
                List(selection: $model.selectedId) {
                    ForEach(model.automations) { automation in
                        AutomationRow(automation: automation, runs: model.runs(for: automation))
                            .tag(automation.id)
                            .contextMenu {
                                Button(automation.isEnabled ? "Disable" : "Enable") {
                                    model.setEnabled(automation, !automation.isEnabled)
                                }
                                Button("Run Now") { model.runNow(automation) }
                                Button("Edit…") { model.draft = AutomationDraft(automation: automation) }
                                Button("Duplicate") { model.duplicate(automation) }
                                Divider()
                                Button("Delete", role: .destructive) { model.delete(automation) }
                            }
                    }
                }
                .listStyle(.sidebar)
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            if let error = model.lastError {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(error).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            } else if let next = model.nextWakeUp {
                Image(systemName: "clock").foregroundStyle(.secondary)
                Text("Next run \(next.formatted(.relative(presentation: .named)))")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Nothing scheduled").font(.caption).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 12)
            // Said plainly rather than left to be discovered, exactly as the marketplace and MCP
            // screens state their own limits.
            Text("Automations run while Clinic is running.")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }
}

// MARK: - Row

private struct AutomationRow: View {
    let automation: Automation
    let runs: [AutomationRun]

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: glyph)
                .font(.system(size: 13)).frame(width: 18)
                .foregroundStyle(automation.isEnabled ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(HierarchicalShapeStyle.tertiary))
            VStack(alignment: .leading, spacing: 1) {
                Text(automation.name).font(.body.weight(.medium)).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if let last = runs.first { AutomationOutcomeBadge(outcome: last.outcome) }
        }
        .padding(.vertical, 2)
        .opacity(automation.isEnabled ? 1 : 0.55)
    }

    private var glyph: String {
        switch automation.target {
        case .chat: "bubble.left.and.bubble.right.fill"
        case .project: automation.permissionMode.wantsWorktree ? "pencil.and.outline" : "eye"
        }
    }

    private var subtitle: String {
        var parts = [automation.schedule.summary()]
        if case .project(let path) = automation.target {
            parts.append((path as NSString).lastPathComponent)
        } else {
            parts.append("Chat")
        }
        return parts.joined(separator: " · ")
    }
}

struct AutomationOutcomeBadge: View {
    let outcome: AutomationRun.Outcome

    var body: some View {
        Image(systemName: symbol).font(.caption).foregroundStyle(tint).help(outcome.title)
    }

    private var symbol: String {
        switch outcome {
        case .running: "circle.dotted"
        case .finished: "checkmark.circle.fill"
        case .failed, .launchFailed: "xmark.octagon.fill"
        case .stalled: "exclamationmark.circle.fill"
        case .skipped: "minus.circle"
        }
    }

    private var tint: Color {
        switch outcome {
        case .running: .accentColor
        case .finished: .green
        case .failed, .launchFailed: .red
        case .stalled: .orange
        case .skipped: .secondary
        }
    }
}
