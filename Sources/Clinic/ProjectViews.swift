import SwiftUI
import UniformTypeIdentifiers
import ClinicCore

/// Project header: icon, name, count, "+" and a menu (ADR-050).
struct ProjectHeader: View {
    @Environment(TabStore.self) private var tabs
    @Environment(SessionStore.self) private var sessions
    let project: Project
    let count: Int
    var collapsed = false
    @State private var hovering = false
    @State private var dropTargeted = false

    var body: some View {
        HStack(spacing: 6) {
            Button { sessions.setCollapsed(project, !collapsed) } label: {
                Image(systemName: "chevron.right").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                    .rotationEffect(.degrees(collapsed ? 0 : 90)).frame(width: 12, height: 12).contentShape(Rectangle())
            }
            .buttonStyle(.plain).help(collapsed ? "Expand" : "Collapse")
            ProjectIcon(project: project, size: 22)
            Text(project.name).font(.body.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                .help(SessionStore.isChats(project.path) ? "Chats: sessions without a repository. Click to start one." : project.path + "\nClick to start a session here")
            Text("\(count)").font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                .padding(.horizontal, 5).padding(.vertical, 1).background(.quaternary, in: Capsule())
            Spacer(minLength: 4)
            // Both reveal on hover but always occupy their space, so the header never reflows.
            HStack(spacing: 2) {
                Button { tabs.startNewSession(projectPath: project.path) } label: {
                    Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).frame(width: 18, height: 18).contentShape(Rectangle())
                }.buttonStyle(.plain).help("New session in \(project.name)")
                Menu { ProjectMenu(project: project) } label: { Image(systemName: "ellipsis").font(.system(size: 11, weight: .semibold)) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help("Project actions")
            }
            .foregroundStyle(.secondary)
            .opacity(hovering ? 1 : 0)
            .padding(.trailing, 6)
        }
        .textCase(nil)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture { if SessionStore.isChats(project.path) { tabs.newChat() } else { tabs.startNewSession(projectPath: project.path) } }
        .onHover { hovering = $0 }
        .contextMenu { ProjectMenu(project: project) }
        .draggable(project.path)
        .dropDestination(for: String.self) { items, _ in
            guard let moved = items.first, moved != project.path else { return false }
            sessions.moveProject(moved, before: project.path)
            return true
        } isTargeted: { dropTargeted = $0 }
        .overlay(alignment: .top) { if dropTargeted { Rectangle().fill(Color.accentColor).frame(height: 2) } }
    }
}

/// Stand-in row for a project with no sessions, so an empty group is still a place to start one.
struct NewSessionPlaceholderRow: View {
    @Environment(TabStore.self) private var tabs
    let project: Project
    @State private var hovering = false

    var body: some View {
        let chats = SessionStore.isChats(project.path)
        HStack(spacing: 8) {
            Image(systemName: "plus").font(.system(size: 10, weight: .semibold)).frame(width: 10)
            Text(chats ? "New Chat" : "New Session")
            Spacer(minLength: 0)
        }
        .font(.callout)
        .foregroundStyle(hovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { if chats { tabs.newChat() } else { tabs.startNewSession(projectPath: project.path) } }
        .help(chats ? "Start a chat" : "Start a session in \(project.name)")
    }
}

struct ProjectMenu: View {
    @Environment(TabStore.self) private var tabs
    @Environment(SessionStore.self) private var sessions
    let project: Project
    @State private var remote: URL?
    @State private var checkoutTarget: String?

    var body: some View {
        if SessionStore.isChats(project.path) { Button("New Chat") { tabs.newChat() } }
        Button("New Session") { tabs.startNewSession(projectPath: project.path) }
        Button("New Session in New Window") { tabs.startNewSession(projectPath: project.path, inNewWindow: true) }
        Button("New Session in Worktree") { tabs.newSession(projectPath: project.path, model: sessions.state.lastModelByProject[project.path], worktree: true) }
        Button("Continue Last Session Here") { tabs.continueLast(in: project.path) }
        Button("Import Session…") { NotificationCenter.default.post(name: .clinicQuickSwitch, object: project.path) }
        Divider()
        Button("Open Shell Here") { tabs.newShell(in: project.path) }
        OpenInMenu(path: project.path)
        Button("Open on GitHub") { if let remote { NSWorkspace.shared.open(remote) } }
            .disabled(remote == nil)
            .task { remote = await GitInfo.remoteWebURL(at: project.path) }
        Button("Copy Path") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(project.path, forType: .string) }
        Divider()
        Button("Generate Icon…") { NotificationCenter.default.post(name: .clinicGenerateIcon, object: project.path) }
        Button("Remove Generated Icon") {
            try? ProjectIconGenerator.removeGeneratedIcon(projectPath: project.path)
            ProjectIconCache.shared.invalidate(project.path)
        }
        .disabled(!ProjectIconGenerator.hasGeneratedIcon(projectPath: project.path))
        Divider()
        Button("Git Pull") { Task { if let out = await RepoUpkeep.pull(project: project) { RepoUpkeep.showError("Git pull", out) } } }
        Button("Checkout \(checkoutTarget ?? "default branch")") { Task { await RepoUpkeep.checkoutDefault(project: project) } }
            .disabled(checkoutTarget == nil)
            .task { checkoutTarget = await RepoUpkeep.checkoutTarget(project: project) }
        Divider()
        Button("Archive Project") { sessions.archiveProject(project) }
        Button("Reset Project Order") { sessions.resetProjectOrder() }.disabled(sessions.state.projectOrder.isEmpty)
        // Chats is pinned and permanent, so there is nothing to remove it to (ADR-077).
        if !SessionStore.isChats(project.path) {
            Button("Remove Project", role: .destructive) { sessions.removeProject(project) }
        }
    }
}

/// `project-icon.svg|png` → `.clinic/icon.*` → monogram on a hashed colour (ADR-050).
struct ProjectIcon: View {
    let project: Project
    var size: CGFloat = 22

    var body: some View {
        Group {
            if SessionStore.isChats(project.path) {
                ZStack {
                    RoundedRectangle(cornerRadius: size * 0.22).fill(Color.accentColor)
                    Image(systemName: "bubble.left.and.bubble.right.fill").font(.system(size: size * 0.5)).foregroundStyle(.white)
                }
            } else if let image = icon {
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

    /// Reading `revision` first makes this view depend on `invalidate` (ADR-076).
    private var icon: NSImage? {
        _ = ProjectIconCache.shared.revision
        return ProjectIconCache.shared.image(for: project.path)
    }

    static func color(for path: String) -> Color {
        var h: UInt32 = 2166136261
        for b in path.utf8 { h = (h ^ UInt32(b)) &* 16777619 }
        return Color(hue: Double(h % 360) / 360, saturation: 0.55, brightness: 0.75)
    }
}

@MainActor @Observable
final class ProjectIconCache {
    static let shared = ProjectIconCache()
    /// Bumped by `invalidate`; views read it so a generated icon (ADR-076) redraws everywhere.
    private(set) var revision = 0
    /// Lookups fill the cache lazily, so this storage must stay out of observation (it is written during `body`).
    @ObservationIgnored private var cache: [String: NSImage?] = [:]
    @ObservationIgnored private var tints: [String: Color?] = [:]
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

    /// Drops one project's icon (or all of them) and asks every `ProjectIcon` to look again.
    func invalidate(_ path: String? = nil) {
        if let path { cache[path] = nil; tints[path] = nil } else { cache.removeAll(); tints.removeAll() }
        revision &+= 1
    }

    /// The icon's average colour, lifted into a usable wash — the new-session screen tints itself with it (ADR-082).
    /// Falls back to the hashed monogram colour when the project has no icon.
    func tint(for path: String) -> Color {
        if let cached = tints[path] { return cached ?? ProjectIcon.color(for: path) }
        let found = image(for: path).flatMap(Self.averageColor)
        tints[path] = found
        return found ?? ProjectIcon.color(for: path)
    }

    /// Draws the icon into a single pixel. Dark or mostly-transparent icons still have a hue worth using,
    /// so saturation and brightness are floored rather than taken as measured.
    private static func averageColor(_ image: NSImage) -> Color? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var px = [UInt8](repeating: 0, count: 4)
        let drawn: Bool = px.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                                      bytesPerRow: 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        let alpha = Double(px[3]) / 255
        guard drawn, alpha > 0.05 else { return nil }
        let rgb = (0..<3).map { Double(px[$0]) / 255 / alpha }
        var h: CGFloat = 0, sat: CGFloat = 0, bri: CGFloat = 0
        guard let c = NSColor(srgbRed: rgb[0], green: rgb[1], blue: rgb[2], alpha: 1).usingColorSpace(.deviceRGB) else { return nil }
        c.getHue(&h, saturation: &sat, brightness: &bri, alpha: nil)
        guard sat > 0.04 else { return nil }
        return Color(hue: Double(h), saturation: min(1, Double(sat) * 1.5 + 0.1), brightness: max(0.6, Double(bri)))
    }
}
