import SwiftUI
import UniformTypeIdentifiers
import ClinicCore
import os

/// Project header: icon, name, count, "+" and a menu (ADR-050).
struct ProjectHeader: View {
    @Environment(TabStore.self) private var tabs
    @Environment(SessionStore.self) private var sessions
    @Environment(ComposerLibraryModel.self) private var composer
    let project: Project
    let count: Int
    var collapsed = false
    @State private var hovering = false
    @State private var dropTargeted = false

    var body: some View {
        HStack(spacing: 6) {
            ProjectFoldIcon(project: project, collapsed: collapsed)
            Text(project.name).font(.body.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                .help(SessionStore.isChats(project.path) ? "Chats: sessions without a repository. Click to start one." : project.path + "\nClick to start a session here")
            Text("\(count)").font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                .padding(.horizontal, 5).padding(.vertical, 1).background(.quaternary, in: Capsule())
            // A folded project still says when a session in it waits on you or finished unseen (ADR-210).
            if collapsed, case let attention = tabs.attention(in: [project.path]), !attention.isEmpty {
                Circle().fill(attention.color).frame(width: 7, height: 7)
                    .help(attention.waiting > 0 ? "A session here needs you" : "A session here finished while you were away")
                    .accessibilityLabel(attention.spoken)
            }
            if let draft = composer.draft(for: project.path) { DraftMark(project: project, draft: draft) }
            Spacer(minLength: 4)
            // The chosen quick actions and ⋯ (ADR-211). They take room only under the pointer: reserved
            // for up to six buttons they would cut every name short all the time, so a long name gives
            // way while hovered instead. Collapsed rather than removed, so an open menu keeps its anchor.
            ProjectQuickActions(project: project)
                .fixedSize()
                .opacity(hovering ? 1 : 0)
                .frame(maxWidth: hovering ? nil : 0, alignment: .trailing)
                .clipped()
                .padding(.trailing, 6)
        }
        .textCase(nil)
        // 2 pt in from the section header's inset, so the project tiles share one column with the
        // nav rows' tiles and the Projects caption above them (ADR-209).
        .padding(.leading, 2)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture { if SessionStore.isChats(project.path) { tabs.newChat() } else { tabs.startNewSession(projectPath: project.path) } }
        .onHover { hovering = $0 }
        .contextMenu { ProjectMenu(project: project) }
        .draggable(project.path)
        .dropDestination(for: String.self) { items, _ in
            guard let moved = items.first, moved != project.path, ProjectGroupDrag.groupId(moved) == nil else { return false }
            sessions.moveProject(moved, before: project.path)
            // Dropped among a group's projects, it joins that group; among ungrouped ones, it leaves its own (ADR-210).
            if !SessionStore.isChats(project.path) { sessions.move(project: moved, toGroup: sessions.group(of: project.path)?.id) }
            return true
        } isTargeted: { dropTargeted = $0 }
        .overlay(alignment: .top) { if dropTargeted { Rectangle().fill(Color.accent).frame(height: 2) } }
    }
}

/// The project's icon, which is also its fold control (ADR-209): hovering the tile shows the disclosure
/// chevron on it, and clicking it collapses or expands the project. A drawn tile (a monogram, Chats) swaps
/// its glyph for the chevron; a picture is blurred under a scrim with the chevron on top. It replaces a
/// chevron column of its own, which gives the header's name 16 pt more room.
struct ProjectFoldIcon: View {
    @Environment(SessionStore.self) private var sessions
    let project: Project
    let collapsed: Bool
    var size: CGFloat = 22
    @State private var hovering = false

    var body: some View {
        let picture = ProjectIcon.hasPicture(project)
        Button { sessions.setCollapsed(project, !collapsed) } label: {
            ProjectIcon(project: project, size: size, showsFold: hovering && !picture, collapsed: collapsed)
        }
        .buttonStyle(FoldIconStyle(collapsed: collapsed, hovering: hovering, picture: picture, size: size))
        .onHover { hovering = $0 }
        .help(collapsed ? "Expand \(project.name)" : "Collapse \(project.name)")
        .accessibilityLabel(collapsed ? "Expand \(project.name)" : "Collapse \(project.name)")
    }

    /// A picture's scrim and chevron, drawn only while the pointer is on the tile; a press darkens the
    /// scrim, or a drawn tile's own colour.
    private struct FoldIconStyle: ButtonStyle {
        let collapsed: Bool
        let hovering: Bool
        let picture: Bool
        let size: CGFloat

        func makeBody(configuration: Configuration) -> some View {
            // ProjectIcon's own corner, so the blur and scrim stay on the tile and nothing past it.
            let tile = RoundedRectangle(cornerRadius: size * 0.22)
            configuration.label
                // A softened picture under a dark scrim: with it still sharp, a `>` in the icon read as
                // part of the chevron. A drawn tile is left alone; it shows the chevron itself.
                .blur(radius: picture && hovering ? 2 : 0, opaque: true)
                .clipShape(tile)
                .overlay {
                    if picture {
                        ZStack {
                            tile.fill(.black.opacity(configuration.isPressed ? 0.7 : 0.55))
                            ProjectIcon.chevron(collapsed: collapsed, size: size)
                        }
                        .opacity(hovering ? 1 : 0)
                    } else {
                        tile.fill(.black.opacity(configuration.isPressed ? 0.2 : 0))
                    }
                }
                .contentShape(Rectangle())
                .animation(.easeOut(duration: 0.12), value: hovering)
                .animation(.snappy(duration: 0.2), value: collapsed)
        }
    }
}

/// A project with an unsent composer (ADR-161): a pencil beside the count, always shown rather than on
/// hover, because the point is to notice it. Clicking it opens the composer, which restores the draft.
struct DraftMark: View {
    @Environment(TabStore.self) private var tabs
    let project: Project
    let draft: ComposerDraft

    var body: some View {
        Button {
            if SessionStore.isChats(project.path) { tabs.newChat() } else { tabs.startNewSession(projectPath: project.path) }
        } label: {
            Image(systemName: "pencil.line")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.accent)
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel("Unsent draft")
    }

    private var help: String {
        let text = draft.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let what = text.isEmpty ? "a worktree named \(draft.worktreeName)" : "“\(NewSessionScreen.snippet(text, limit: 80))”"
        return "Unsent draft: \(what)\nClick to continue it"
    }
}

/// Stand-in row for a project with no sessions, so an empty group is still a place to start one.
struct NewSessionPlaceholderRow: View {
    @Environment(TabStore.self) private var tabs
    @Environment(ComposerLibraryModel.self) private var composer
    let project: Project
    @State private var hovering = false

    var body: some View {
        let chats = SessionStore.isChats(project.path)
        let hasDraft = composer.draft(for: project.path) != nil
        HStack(spacing: 8) {
            Image(systemName: hasDraft ? "pencil.line" : "plus").font(.system(size: 10, weight: .semibold)).frame(width: 10)
            Text(hasDraft ? "Continue Draft" : chats ? "New Chat" : "New Session")
            Spacer(minLength: 0)
        }
        .font(.callout)
        .foregroundStyle(hovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .sidebarRowHover(hovering)
        .onTapGesture { if chats { tabs.newChat() } else { tabs.startNewSession(projectPath: project.path) } }
        .help(hasDraft ? "Continue the unsent draft in \(project.name)" : chats ? "Start a chat" : "Start a session in \(project.name)")
    }
}

struct ProjectMenu: View {
    @Environment(TabStore.self) private var tabs
    @Environment(SessionStore.self) private var sessions
    @Environment(ComposerLibraryModel.self) private var composer
    let project: Project
    @State private var remote: URL?
    @State private var checkoutTarget: String?

    var body: some View {
        let hasDraft = composer.draft(for: project.path) != nil
        if SessionStore.isChats(project.path) { Button(hasDraft ? "Continue Draft" : "New Chat") { tabs.newChat() } }
        // The composer restores the draft, so with one kept, New Session is Continue Draft (ADR-161).
        Button(hasDraft && !SessionStore.isChats(project.path) ? "Continue Draft" : "New Session") { tabs.startNewSession(projectPath: project.path) }
        if hasDraft { Button("Discard Draft") { tabs.discardDraft(projectPath: project.path) } }
        Button("New Session in New Window") { tabs.startNewSession(projectPath: project.path, inNewWindow: true) }
        Button("New Session in Worktree") { tabs.newSession(projectPath: project.path, model: sessions.state.lastModelByProject[project.path], worktree: true) }
        Button("Continue Last Session Here") { tabs.continueLast(in: project.path) }
        Button("Import Session…") { NotificationCenter.default.post(name: .clinicQuickSwitch, object: project.path) }
        Divider()
        Button("Open Shell Here") { tabs.openTerminal(in: project.path) }
        ProjectRunMenu(projectPath: project.path)
        OpenInMenu(path: project.path)
        SoundPackMenu(target: .project(project.path))
        Button("Open on GitHub") { if let remote { NSWorkspace.shared.open(remote) } }
            .disabled(remote == nil)
            .task { remote = await GitInfo.remoteWebURL(at: project.path) }
        if !SessionStore.isChats(project.path) {
            Button("Task Source…") { NotificationCenter.default.post(name: .clinicTaskSource, object: project.path) }
        }
        Button("Copy Path") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(project.path, forType: .string) }
        MoveToGroupMenu(project: project)
        Divider()
        Button("Generate Icon…") { NotificationCenter.default.post(name: .clinicGenerateIcon, object: project.path) }
        Button("Remove Generated Icon") {
            try? ProjectIconGenerator.removeGeneratedIcon(projectPath: project.path)
            ProjectIconCache.shared.invalidate(project.path)
        }
        .disabled(!ProjectIconGenerator.hasGeneratedIcon(projectPath: project.path))
        Divider()
        Button("Git Pull") { NotificationCenter.default.post(name: .clinicGitPull, object: project.path) }
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
        Divider()
        Button("Customize Quick Actions\u{2026}") { PreferencesView.open(.general) }
    }
}

/// `project-icon.svg|png` → `.clinic/icon.*` → monogram on a hashed colour (ADR-050).
struct ProjectIcon: View {
    let project: Project
    var size: CGFloat = 22
    /// On a drawn tile, shows the fold chevron in place of its glyph (ADR-209). A picture ignores it.
    var showsFold = false
    /// Which way that chevron points.
    var collapsed = false

    var body: some View {
        Group {
            if SessionStore.isChats(project.path) {
                drawn(Color.accent) {
                    Image(systemName: "bubble.left.and.bubble.right.fill").font(.system(size: size * 0.5)).foregroundStyle(.white)
                }
            } else if let image = Self.picture(for: project) {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.22))
            } else {
                drawn(Self.color(for: project.path)) {
                    Text(String(project.name.prefix(1)).uppercased())
                        .font(.system(size: size * 0.6, weight: .bold, design: .rounded)).foregroundStyle(.white)
                }
            }
        }
        .frame(width: size, height: size)
    }

    /// A glyph on a coloured tile, crossfading to the chevron while `showsFold` is set.
    private func drawn(_ fill: Color, @ViewBuilder glyph: () -> some View) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.22).fill(fill)
            glyph().opacity(showsFold ? 0 : 1)
            Self.chevron(collapsed: collapsed, size: size).opacity(showsFold ? 1 : 0)
        }
    }

    static func chevron(collapsed: Bool, size: CGFloat) -> some View {
        Image(systemName: "chevron.right")
            .font(.system(size: size * 0.5, weight: .bold))
            .foregroundStyle(.white)
            .rotationEffect(.degrees(collapsed ? 0 : 90))
    }

    static func hasPicture(_ project: Project) -> Bool {
        !SessionStore.isChats(project.path) && picture(for: project) != nil
    }

    /// Reading `revision` first makes the calling view depend on `invalidate` (ADR-076).
    private static func picture(for project: Project) -> NSImage? {
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
    private static let log = Logger(subsystem: "com.r0adkll.clinic", category: "icons")
    /// Bumped by `invalidate`; views read it so a generated icon (ADR-076) redraws everywhere.
    private(set) var revision = 0
    /// Lookups fill the cache lazily, so this storage must stay out of observation (it is written during `body`).
    @ObservationIgnored private var cache: [String: NSImage?] = [:]
    @ObservationIgnored private var tints: [String: Color?] = [:]
    /// What the candidate files looked like when `cache` was filled; a watcher event that leaves a
    /// project's stamp unchanged is ignored, so build churn in a repo root never redraws (ADR-154).
    @ObservationIgnored private var stamps: [String: Stamp] = [:]
    @ObservationIgnored private let watcher = PathWatcher()
    @ObservationIgnored private var watchTask: Task<Void, Never>?
    static let candidates = ["project-icon.svg", "project-icon.png", ".clinic/icon.svg", ".clinic/icon.png"]

    /// Existence, size and modification time of each candidate, in lookup order.
    struct Stamp: Equatable {
        var entries: [(Int, Date)?]
        static func == (a: Stamp, b: Stamp) -> Bool {
            a.entries.count == b.entries.count && zip(a.entries, b.entries).allSatisfy { $0?.0 == $1?.0 && $0?.1 == $1?.1 }
        }
    }

    static func stamp(for path: String) -> Stamp {
        Stamp(entries: candidates.map { name in
            let attrs = try? FileManager.default.attributesOfItem(atPath: (path as NSString).appendingPathComponent(name))
            guard let attrs else { return nil }
            return ((attrs[.size] as? Int) ?? 0, (attrs[.modificationDate] as? Date) ?? .distantPast)
        })
    }

    /// Follows the candidate icon files of these projects (ADR-154). Called whenever the project list
    /// changes; a file appearing, changing or vanishing redraws that project's icon without a relaunch.
    func watch(projects: [String]) {
        let paths = projects.filter { !SessionStore.isChats($0) }
        watcher.watch(Set(paths.flatMap { p in Self.candidates.map { (p as NSString).appendingPathComponent($0) } }))
        guard watchTask == nil else { return }
        watchTask = Task { [weak self, watcher] in
            for await _ in watcher.changes {
                guard let self else { return }
                self.reconcile()
            }
        }
    }

    /// Drops every cached icon whose files no longer match the stamp taken when it was cached.
    private func reconcile() {
        var changed: [String] = []
        for (path, old) in stamps where Self.stamp(for: path) != old { changed.append(path) }
        for path in changed { Self.log.info("icon files changed, reloading: \(path, privacy: .public)"); invalidate(path) }
    }

    func image(for path: String) -> NSImage? {
        if let cached = cache[path] { return cached }
        var found: NSImage?
        for name in Self.candidates {
            let url = URL(fileURLWithPath: path).appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path), let img = NSImage(contentsOf: url), img.isValid { found = img; break }
        }
        cache[path] = found
        stamps[path] = Self.stamp(for: path)
        return found
    }

    /// Drops one project's icon (or all of them) and asks every `ProjectIcon` to look again.
    func invalidate(_ path: String? = nil) {
        if let path { cache[path] = nil; tints[path] = nil; stamps[path] = nil } else { cache.removeAll(); tints.removeAll(); stamps.removeAll() }
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
