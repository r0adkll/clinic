import AppKit
import SwiftUI
import ClinicCore

/// A file in its own window (ADR-081): the Files pane's code view, its own `EditorModel`, and no tab.
///
/// Plain AppKit rather than a SwiftUI `WindowGroup(for:)` on purpose: ADR-042 opts the app out of
/// AppKit state restoration, so a scene-backed window would try to restore files into a build whose
/// scene shape may have moved on. A window Clinic opens and owns needs no scene value and no
/// environment injection — the model is the whole of its state.
@MainActor
final class FileWindowController: NSObject, NSWindowDelegate {
    /// Every open file window. Looked up by the file each one currently shows, so quick-opening inside
    /// a window keeps the "one window per path" rule without the registry key going stale.
    private static var controllers: [FileWindowController] = []

    private let model: EditorModel
    private let window: NSWindow

    /// Opens `path` in a window, or fronts the window that already shows it.
    static func show(path: String, root: String) {
        NSApp.activate()
        if let existing = controllers.first(where: { $0.model.openPath == path }) {
            existing.window.makeKeyAndOrderFront(nil)
            return
        }
        let controller = FileWindowController(path: path, root: root)
        controllers.append(controller)
        controller.window.makeKeyAndOrderFront(nil)
    }

    /// True for a window this controller opened (see `TabStore.closeFront`).
    static func owns(_ window: NSWindow) -> Bool { controllers.contains { $0.window === window } }

    /// Closes every file window; the app is going away and their watchers must stop.
    static func closeAll() {
        for c in controllers { c.window.close() }
    }

    private init(path: String, root: String) {
        model = EditorModel(root: root, tree: false)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 640),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        super.init()
        model.open(absolute: path)
        model.onOpen = { [weak self] path in self?.retitle(path) }
        window.contentView = NSHostingView(rootView: FileEditorView(model: model).frame(minWidth: 480, minHeight: 320))
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.delegate = self
        window.minSize = NSSize(width: 480, height: 320)
        // Windows share one saved frame and cascade off each other, so a second file does not land on
        // top of the first.
        if !window.setFrameAutosaveName("ClinicFileWindow"), let last = Self.controllers.last?.window {
            window.setFrameOrigin(last.cascadeTopLeft(from: last.frame.origin))
        } else if window.frame.origin == .zero {
            window.center()
        }
        retitle(path)
    }

    private func retitle(_ path: String) {
        window.title = (path as NSString).lastPathComponent
        let dir = (model.relativeOpenPath as NSString?)?.deletingLastPathComponent ?? ""
        window.subtitle = dir.isEmpty ? (model.root as NSString).lastPathComponent : dir
        window.representedURL = URL(fileURLWithPath: path)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard model.isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = "Save changes to \(window.title)?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Discard"); alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: model.save(); return model.error == nil
        case .alertSecondButtonReturn: return true
        default: return false
        }
    }

    func windowWillClose(_ notification: Notification) {
        model.stop()
        Self.controllers.removeAll { $0 === self }
    }
}
