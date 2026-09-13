import AppKit
import Observation
import SwiftUI

/// One destination of an "Open In" action: Finder, Ghostty, or an installed editor (ADR-078).
struct OpenInTarget: Identifiable, Hashable {
    enum Kind: Hashable {
        case finder
        case ghostty(binary: String)
        case app(URL)
    }
    /// The app's path on disk, so two installs of one app are two targets (ADR-146). Finder and
    /// Ghostty keep their fixed ids.
    var id: String
    var name: String
    var kind: Kind
    /// File the icon is read from; Ghostty and Finder resolve to their bundles.
    var iconPath: String
    /// Bundle id this app was found under; nil for Finder and Ghostty. Only used to re-resolve a
    /// default picked before ADR-146, when the stored id *was* the bundle id.
    var bundleId: String? = nil
}

/// Installed "Open In" destinations plus their app icons and the user's default choice (ADR-078).
///
/// Lookups hit Launch Services, so the resolved list is cached and only refreshed when it goes stale;
/// icons are cached per target and size because menus rebuild on every open.
@MainActor
@Observable
final class OpenInApps {
    static let shared = OpenInApps()

    /// Editors we look for, in menu order (the ADR-063 set).
    static let editors: [(name: String, bundleId: String)] = [
        ("Xcode", "com.apple.dt.Xcode"),
        ("Visual Studio Code", "com.microsoft.VSCode"),
        ("Cursor", "com.todesktop.230313mzl4w4u92"),
        ("Zed", "dev.zed.Zed"),
        ("IntelliJ IDEA", "com.jetbrains.intellij"),
        ("Android Studio", "com.google.android.studio"),
    ]
    static let finderPath = "/System/Library/CoreServices/Finder.app"
    private static let staleAfter: TimeInterval = 60
    private static let defaultKey = "ClinicOpenInDefault"
    private static let customKey = "ClinicOpenInCustomApps"
    private static let hiddenKey = "ClinicOpenInHidden"

    /// Every destination Clinic knows about, hidden ones included. The Settings pane works on this.
    private(set) var allTargets: [OpenInTarget] = []
    /// What the menus and the toolbar offer: `allTargets` minus what the reader has hidden.
    var targets: [OpenInTarget] { allTargets.filter { !hiddenIds.contains($0.id) } }

    /// Apps the reader added by hand because discovery does not know them (ADR-147). Paths, so an
    /// app that moves stops resolving rather than silently opening something else.
    private(set) var customAppPaths: [String] = [] {
        didSet { UserDefaults.standard.set(customAppPaths, forKey: Self.customKey) }
    }
    private(set) var hiddenIds: Set<String> = [] {
        didSet { UserDefaults.standard.set(Array(hiddenIds), forKey: Self.hiddenKey) }
    }
    /// Id of the target the footer chip opens; nil until the user picks one.
    var defaultTargetId: String? {
        didSet { UserDefaults.standard.set(defaultTargetId, forKey: Self.defaultKey) }
    }
    @ObservationIgnored private var icons: [String: NSImage] = [:]
    @ObservationIgnored private var resolvedAt: Date?

    private init() {
        defaultTargetId = UserDefaults.standard.string(forKey: Self.defaultKey)
        customAppPaths = UserDefaults.standard.stringArray(forKey: Self.customKey) ?? []
        hiddenIds = Set(UserDefaults.standard.stringArray(forKey: Self.hiddenKey) ?? [])
        refresh()
    }

    /// The target the primary action opens when a project has no pick of its own: the reader's global
    /// default if it is still installed and visible, else the first one.
    var defaultTarget: OpenInTarget? {
        targets.first { $0.id == defaultTargetId } ?? targets.first
    }

    /// The target a project opens in: its own pick (ADR-147), falling back to the global default.
    /// An id that no longer resolves — app deleted, or hidden since — falls back rather than failing.
    func target(forProjectPick pick: String?) -> OpenInTarget? {
        guard let pick, let match = targets.first(where: { $0.id == pick }) else { return defaultTarget }
        return match
    }

    func addCustomApp(_ url: URL) {
        guard !customAppPaths.contains(url.path) else { return }
        customAppPaths.append(url.path)
        refresh()
    }

    /// Removes a reader-added app. Discovered apps cannot be removed, only hidden — they would come
    /// straight back on the next refresh.
    func removeCustomApp(_ id: String) {
        guard customAppPaths.contains(id) else { return }
        customAppPaths.removeAll { $0 == id }
        hiddenIds.remove(id)
        refresh()
    }

    func isCustom(_ target: OpenInTarget) -> Bool { customAppPaths.contains(target.id) }

    func setHidden(_ target: OpenInTarget, _ hidden: Bool) {
        if hidden { hiddenIds.insert(target.id) } else { hiddenIds.remove(target.id) }
    }

    func refreshIfStale() {
        if let resolvedAt, Date().timeIntervalSince(resolvedAt) < Self.staleAfter { return }
        refresh()
    }

    func refresh() {
        resolvedAt = Date()
        var found: [OpenInTarget] = [OpenInTarget(id: "finder", name: "Finder", kind: .finder, iconPath: Self.finderPath)]
        if let binary = TabStore.ghosttyBinary {
            let bundle = URL(fileURLWithPath: binary).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            found.append(OpenInTarget(id: "ghostty", name: "Ghostty", kind: .ghostty(binary: binary), iconPath: bundle.path))
        }
        for editor in Self.editors {
            // Every install, not the one Launch Services prefers: Android Studio and its Preview share
            // a bundle id, as do Xcode and Xcode-beta, so the singular lookup can only ever offer one
            // of each pair — and picks the wrong one (ADR-146).
            let urls = NSWorkspace.shared.urlsForApplications(withBundleIdentifier: editor.bundleId)
            for (url, name) in Self.named(urls, fallback: editor.name) {
                found.append(OpenInTarget(id: url.path, name: name, kind: .app(url), iconPath: url.path, bundleId: editor.bundleId))
            }
        }
        // Reader-added apps last, in the order they were added: discovery's order is curated
        // (ADR-078) and these have no place in it.
        for path in customAppPaths where !found.contains(where: { $0.id == path }) {
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: path) else { continue }
            let name = url.deletingPathExtension().lastPathComponent
            found.append(OpenInTarget(id: path, name: name.isEmpty ? path : name, kind: .app(url), iconPath: path))
        }
        if found != allTargets { allTargets = found }
        adoptPreAppPathDefault()
    }

    /// Names for one bundle id's installs, in menu order.
    ///
    /// The name is the `.app`'s file name, which is what Finder shows and the only thing that tells the
    /// two Android Studios apart — `CFBundleName` is "Android Studio" for both, so the bundle's own idea
    /// of its name would draw the list twice with one label. Installs that collide on the file name too
    /// take their directory as a suffix. Sorted by name so the menu does not reshuffle when Launch
    /// Services changes its mind about which install it prefers.
    private static func named(_ urls: [URL], fallback: String) -> [(URL, String)] {
        func fileName(_ url: URL) -> String {
            let name = url.deletingPathExtension().lastPathComponent
            return name.isEmpty ? fallback : name
        }
        let counts = urls.reduce(into: [String: Int]()) { $0[fileName($1), default: 0] += 1 }
        return urls.map { url in
            let name = fileName(url)
            guard (counts[name] ?? 0) > 1 else { return (url, name) }
            return (url, "\(name) (\(abbreviatingHome(url.deletingLastPathComponent().path)))")
        }
        .sorted { ($0.1, $0.0.path) < ($1.1, $1.0.path) }
    }

    static func abbreviatingHome(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard path == home || path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }

    /// A default picked before ADR-146 was stored as a bundle id. Now that targets are keyed by path,
    /// rewrite it to the install it resolves to, so the pick survives rather than silently falling back
    /// to Finder.
    private func adoptPreAppPathDefault() {
        guard let id = defaultTargetId, !allTargets.contains(where: { $0.id == id }) else { return }
        guard let match = allTargets.first(where: { $0.bundleId == id }) else { return }
        defaultTargetId = match.id
    }

    /// The target's app icon at `size` points, cached. Nil when the app has gone away since it was resolved.
    func icon(_ target: OpenInTarget, size: CGFloat = 16) -> NSImage? {
        let key = "\(target.id)@\(size)"
        if let cached = icons[key] { return cached }
        guard FileManager.default.fileExists(atPath: target.iconPath) else { return nil }
        guard let copy = NSWorkspace.shared.icon(forFile: target.iconPath).copy() as? NSImage else { return nil }
        copy.size = NSSize(width: size, height: size)
        icons[key] = copy
        return copy
    }

    func open(_ path: String, in target: OpenInTarget) {
        guard !path.isEmpty else { return }
        let url = URL(fileURLWithPath: path)
        switch target.kind {
        case .finder:
            NSWorkspace.shared.activateFileViewerSelecting([url])
        case .ghostty(let binary):
            let p = Process()
            p.executableURL = URL(fileURLWithPath: binary)
            p.arguments = ["--working-directory=\(path)"]
            try? p.run()
        case .app(let app):
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    /// Binding for a picker row: on means "this is the app the quick action opens".
    func isDefault(_ target: OpenInTarget) -> Binding<Bool> {
        Binding(get: { [weak self] in self?.defaultTarget == target },
                set: { [weak self] on in if on { self?.defaultTargetId = target.id } })
    }
}

/// A menu row's content: the app's icon and name, or just the name if the icon has gone missing.
struct OpenInLabel: View {
    let target: OpenInTarget

    var body: some View {
        if let icon = OpenInApps.shared.icon(target) {
            Label { Text(target.name) } icon: { Image(nsImage: icon) }
        } else {
            Text(target.name)
        }
    }
}

/// A menu row that opens a path in one target.
struct OpenInRow: View {
    let target: OpenInTarget
    let action: () -> Void

    var body: some View {
        Button(action: action) { OpenInLabel(target: target) }
    }
}

/// Toolbar quick action (ADR-078): the button opens the selected tab's working directory in the chosen
/// app, and the menu beside it chooses which app that is — picking one only changes the choice.
///
/// macOS draws toolbar item images desaturated, so the app reads as a grey silhouette here; the menu it
/// drops down is a real NSMenu and keeps the icons' colour.
struct OpenInToolbarMenu: View {
    let path: String
    /// The project the open directory belongs to, so the pick can be its own (ADR-147). Nil for a
    /// directory that is not under a registered project; the choice is then the global default.
    let projectPath: String?
    let sessions: SessionStore
    private var apps: OpenInApps { OpenInApps.shared }

    private var pick: String? { projectPath.flatMap { sessions.state.openInByProject[$0] } }
    private var current: OpenInTarget? { apps.target(forProjectPick: pick) }

    var body: some View {
        if !path.isEmpty, let current {
            ToolbarSplitButton(help: "Open \(TabFooter.abbreviate(path)) in \(current.name)",
                               choicesHelp: "Choose which app the button opens in", smokeId: "openIn") {
                apps.open(path, in: current)
            } label: {
                Group {
                    if let icon = apps.icon(current, size: 18) {
                        Image(nsImage: icon).renderingMode(.original).accessibilityLabel("Open in \(current.name)")
                    } else {
                        Image(systemName: "arrow.up.forward.app").accessibilityLabel("Open In")
                    }
                }
                .frame(width: 34, height: 28)
            } choices: {
                // Choosing only changes which app the button uses; it never opens anything (ADR-078).
                // With a project in view the choice is *that project's* (ADR-147) — an Android checkout
                // and a Swift one want different editors, and saying so once should stick.
                PopoverMenu(width: 260) {
                    PopoverMenuHeader(title: projectPath == nil ? "Open with" : "Open this project with")
                    ForEach(apps.targets) { target in
                        PopoverMenuRow(title: target.name, checked: target.id == current.id) {
                            choose(target)
                        } icon: {
                            if let icon = apps.icon(target, size: 16) { Image(nsImage: icon) }
                        }
                    }
                    if let projectPath, pick != nil, let fallback = apps.defaultTarget {
                        PopoverMenuDivider()
                        PopoverMenuRow(title: "Use Default (\(fallback.name))") {
                            sessions.update { $0.openInByProject[projectPath] = nil }
                        } icon: { EmptyView() }
                    }
                }
            }
            .onAppear { apps.refreshIfStale() }
        }
    }

    /// A pick with a project in view is the project's; without one it is the global default, which is
    /// the only thing such a directory could mean.
    private func choose(_ target: OpenInTarget) {
        guard let projectPath else { apps.defaultTargetId = target.id; return }
        sessions.update { $0.openInByProject[projectPath] = target.id }
    }
}
