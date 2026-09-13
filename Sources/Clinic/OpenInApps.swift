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

    private(set) var targets: [OpenInTarget] = []
    /// Id of the target the footer chip opens; nil until the user picks one.
    var defaultTargetId: String? {
        didSet { UserDefaults.standard.set(defaultTargetId, forKey: Self.defaultKey) }
    }
    @ObservationIgnored private var icons: [String: NSImage] = [:]
    @ObservationIgnored private var resolvedAt: Date?

    private init() {
        defaultTargetId = UserDefaults.standard.string(forKey: Self.defaultKey)
        refresh()
    }

    /// The target the primary action opens: the user's pick if it is still installed, else the first one.
    var defaultTarget: OpenInTarget? {
        targets.first { $0.id == defaultTargetId } ?? targets.first
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
        if found != targets { targets = found }
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

    private static func abbreviatingHome(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard path == home || path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }

    /// A default picked before ADR-146 was stored as a bundle id. Now that targets are keyed by path,
    /// rewrite it to the install it resolves to, so the pick survives rather than silently falling back
    /// to Finder.
    private func adoptPreAppPathDefault() {
        guard let id = defaultTargetId, !targets.contains(where: { $0.id == id }) else { return }
        guard let match = targets.first(where: { $0.bundleId == id }) else { return }
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
    private var apps: OpenInApps { OpenInApps.shared }

    var body: some View {
        if !path.isEmpty, let current = apps.defaultTarget {
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
                PopoverMenu(width: 240) {
                    PopoverMenuHeader(title: "Open with")
                    ForEach(apps.targets) { target in
                        PopoverMenuRow(title: target.name, checked: apps.isDefault(target).wrappedValue) {
                            apps.isDefault(target).wrappedValue = true
                        } icon: {
                            if let icon = apps.icon(target, size: 16) { Image(nsImage: icon) }
                        }
                    }
                }
            }
            .onAppear { apps.refreshIfStale() }
        }
    }
}
