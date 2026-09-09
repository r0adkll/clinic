import SwiftUI
import ClinicCore

/// The template gallery, shown wherever nothing is selected (ADR-095).
///
/// Templates are data — `automation-templates.json` in ClinicCore — so this view knows nothing about
/// any particular one. A template whose CLI is missing is shown greyed with the reason rather than
/// hidden: "you could have this if you installed `gh`" is more useful than a shorter gallery.
struct AutomationGallery: View {
    @Environment(AutomationsModel.self) private var model
    @Environment(SessionStore.self) private var sessions
    let defaultProject: String?

    private let columns = [GridItem(.adaptive(minimum: 240, maximum: 340), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Start from a template").font(.headline)
                    Text("Each one is a prompt and a schedule you can change afterwards. Read-only templates cannot write to your repository; the ones that can edit get a fresh git worktree per run.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                    ForEach(AutomationTemplate.bundled) { template in
                        TemplateTile(template: template,
                                     missingTool: missingTool(for: template),
                                     action: { use(template) })
                    }
                    BlankTile { model.draft = AutomationDraft(target: target(for: .project)) }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func missingTool(for template: AutomationTemplate) -> String? {
        guard let tool = template.requiredTool, !ProcessEnvironment.hasTool(tool) else { return nil }
        return tool
    }

    private func use(_ template: AutomationTemplate) {
        model.draft = AutomationDraft(template: template, target: target(for: template.scope))
    }

    private func target(for scope: AutomationTemplate.Scope) -> Automation.Target {
        switch scope {
        case .chat: .chat
        case .project: defaultProject.map { .project(path: $0) } ?? .chat
        }
    }
}

private struct TemplateTile: View {
    let template: AutomationTemplate
    let missingTool: String?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: template.icon)
                        .font(.system(size: 15)).frame(width: 22)
                        .foregroundStyle(missingTool == nil ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(HierarchicalShapeStyle.tertiary))
                    Text(template.name).font(.body.weight(.semibold)).lineLimit(1)
                    Spacer(minLength: 4)
                }
                Text(template.blurb)
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    tag(template.parsedSchedule?.summary() ?? template.schedule, "clock")
                    if template.permissionMode.wantsWorktree {
                        tag("Can edit", "pencil")
                    } else {
                        tag("Read-only", "eye")
                    }
                    if template.scope == .chat { tag("Chat", "bubble.left.and.bubble.right") }
                }
                if let missingTool {
                    Label("Needs `\(missingTool)`, which isn't installed", systemImage: "exclamationmark.triangle")
                        .font(.caption2).foregroundStyle(.orange).lineLimit(1)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
            .background(hovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.quaternary.opacity(0.4)),
                        in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator, lineWidth: 0.5))
            .opacity(missingTool == nil ? 1 : 0.65)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(missingTool == nil ? "Create an automation from this template"
                                 : "You can still create it — it just needs \(missingTool!) to work")
    }

    private func tag(_ text: String, _ icon: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 9))
            Text(text).font(.caption2)
        }
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(.quaternary, in: Capsule())
        .lineLimit(1)
    }
}

private struct BlankTile: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: "plus").font(.title2).foregroundStyle(.secondary)
                Text("Blank automation").font(.callout.weight(.medium))
                Text("Your own prompt and schedule").font(.caption2).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, minHeight: 150)
            .background(hovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
                        in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .foregroundStyle(.separator))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
