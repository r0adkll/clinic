import AppKit
import ClinicCore
import SwiftUI

/// An image in its own window (ADR-106), the way a file gets one (ADR-081): the same viewer, its own
/// zoom, no tab and no session.
///
/// This is what "resize the viewer" actually means — a window has a resize corner, a full-screen
/// button and a second display to go to, and none of that can be built out of a modal sheet, which
/// is what the panel used to open. Plain AppKit for ADR-081's reason: ADR-042 opts the app out of
/// state restoration, so a scene-backed window would try to restore images into a build whose scene
/// shape may have moved on.
@MainActor
final class ImageWindowController: NSObject, NSWindowDelegate {
    /// One window per path: asking twice fronts the window you already have.
    private static var controllers: [ImageWindowController] = []

    private let path: String
    private let window: NSWindow
    private let zoom = ImageZoomModel()

    static func show(_ attachment: ClinicState.Attachment) {
        show(path: attachment.path, caption: attachment.caption)
    }

    static func show(path: String, caption: String? = nil) {
        NSApp.activate()
        if let existing = controllers.first(where: { $0.path == path }) {
            existing.window.makeKeyAndOrderFront(nil)
            return
        }
        let controller = ImageWindowController(path: path, caption: caption)
        controllers.append(controller)
        controller.window.makeKeyAndOrderFront(nil)
    }

    /// True for a window this controller opened, so ⌘W can close the window in front rather than the
    /// session tab behind it (see `TabStore.closeFront`).
    static func owns(_ window: NSWindow) -> Bool { controllers.contains { $0.window === window } }

    /// Closes every image window; the app is going away.
    static func closeAll() {
        for controller in controllers { controller.window.close() }
    }

    private init(path: String, caption: String?) {
        self.path = path
        let facts = ImageFile.facts(path)
        window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.initialSize(facts)),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        super.init()
        // A window is already open, so `.openWindow` and `.remove` have nothing to do here; ⌘C and
        // space mean the same thing they mean in the pane.
        let view = ImageDetailView(path: path, caption: caption, image: ImageFile.full(path),
                                   facts: facts, model: zoom) { command in
            switch command {
            case .copy: ImageClipboard.copy(path)
            case .quickLook: ImageQuickLook.shared.toggle(paths: [path], showing: path)
            case .openWindow, .remove, .step: break
            }
        }
        window.contentView = NSHostingView(rootView: view.frame(minWidth: 280, minHeight: 200))
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.delegate = self
        window.minSize = NSSize(width: 280, height: 200)
        window.title = (path as NSString).lastPathComponent
        window.subtitle = facts.map { "\($0.dimensions) · \($0.fileSize)" } ?? ""
        window.representedURL = URL(fileURLWithPath: path)
        // No shared autosaved frame, unlike the file windows of ADR-081: an image window's *size* is
        // the image's, and a remembered frame would silently hand a 96 pt icon the frame the last
        // 3600 pt screenshot left behind (which is exactly what it did on the first run).
        window.center()
        if let last = Self.controllers.last?.window {
            window.setFrameOrigin(last.cascadeTopLeft(from: last.frame.origin))
        }
    }

    /// Open at the image's own size where that is reasonable, so a small picture does not arrive in a
    /// window mostly made of matte and a huge one does not arrive larger than the screen.
    private static func initialSize(_ facts: ImageFacts?) -> NSSize {
        let bounds = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
        guard let pixels = facts?.pixels, pixels.width > 1, pixels.height > 1 else {
            return NSSize(width: 820, height: 640)
        }
        // The pixels are device pixels; a point holds two of them on the displays this app targets.
        let natural = NSSize(width: pixels.width / 2, height: pixels.height / 2 + 28)
        let scale = min(1, min((bounds.width - 80) / natural.width, (bounds.height - 80) / natural.height))
        return NSSize(width: max(380, natural.width * scale), height: max(280, natural.height * scale))
    }

    func windowWillClose(_ notification: Notification) {
        Self.controllers.removeAll { $0 === self }
    }
}
