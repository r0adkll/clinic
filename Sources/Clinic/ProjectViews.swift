import SwiftUI
import ClinicCore

/// Project header: icon, name, count, "+" and a menu (ADR-050).
struct ProjectHeader: View {
    @Environment(TabStore.self) private var tabs
    @Environment(SessionStore.self) private var sessions
    let project: Project
    let count: Int
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            ProjectIcon(project: project)
            Text(project.name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(1).help(project.path)
            Text("\(count)").font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                .padding(.horizontal, 6).padding(.vertical, 1).background(.quaternary, in: Capsule())
            Spacer(minLength: 4)
            if hovering {
                Button { NotificationCenter.default.post(name: .clinicNewSession, object: project.path) } label: {
                    Image(systemName: "plus.circle.fill").font(.body)
                }.buttonStyle(.borderless).help("New session in \(project.name)")
            }
            Menu { ProjectMenu(project: project) } label: { Image(systemName: "ellipsis.circle").font(.body) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .opacity(hovering ? 1 : 0.6)
                .help("Project actions")
        }
        .textCase(nil)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu { ProjectMenu(project: project) }
    }
}

struct ProjectMenu: View {
    @Environment(TabStore.self) private var tabs
    @Environment(SessionStore.self) private var sessions
    let project: Project
    @State private var remote: URL?

    var body: some View {
        Button("New Session…") { NotificationCenter.default.post(name: .clinicNewSession, object: project.path) }
        Button("New Session in Worktree") { tabs.newSession(projectPath: project.path, model: sessions.state.lastModelByProject[project.path], worktree: true) }
        Button("Import Session…") { NotificationCenter.default.post(name: .clinicQuickSwitch, object: project.path) }
        Divider()
        Button("Open Shell Here") { tabs.newShell(in: project.path) }
        Button("Open in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: project.path)]) }
        Button("Open on GitHub") { if let remote { NSWorkspace.shared.open(remote) } }
            .disabled(remote == nil)
            .task { remote = await GitInfo.remoteWebURL(at: project.path) }
        Button("Copy Path") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(project.path, forType: .string) }
        Divider()
        Button("Remove Project", role: .destructive) { sessions.removeProject(project) }
    }
}

/// `project-icon.svg|png` → `.clinic/icon.*` → monogram on a hashed colour (ADR-050).
struct ProjectIcon: View {
    let project: Project
    var size: CGFloat = 22

    var body: some View {
        Group {
            if let image = ProjectIconCache.shared.image(for: project.path) {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.22))
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: size * 0.22).fill(Self.color(for: project.path))
                    Text(String(project.name.prefix(1)).uppercased())
                        .font(.system(size: size * 0.6, weight: .bold, design: .rounded)).foregroundStyle(.white)
                }
            }
        }
        .frame(width: size, height: size)
    }

    static func color(for path: String) -> Color {
        var h: UInt32 = 2166136261
        for b in path.utf8 { h = (h ^ UInt32(b)) &* 16777619 }
        return Color(hue: Double(h % 360) / 360, saturation: 0.55, brightness: 0.75)
    }
}

@MainActor
final class ProjectIconCache {
    static let shared = ProjectIconCache()
    private var cache: [String: NSImage?] = [:]
    static let candidates = ["project-icon.svg", "project-icon.png", ".clinic/icon.svg", ".clinic/icon.png"]

    func image(for path: String) -> NSImage? {
        if let cached = cache[path] { return cached }
        var found: NSImage?
        for name in Self.candidates {
            let url = URL(fileURLWithPath: path).appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path), let img = NSImage(contentsOf: url), img.isValid { found = img; break }
        }
        cache[path] = found
        return found
    }

    func invalidate() { cache.removeAll() }
}
