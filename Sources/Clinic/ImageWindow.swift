import AppKit
import ClinicCore
import SwiftUI

/// An image, animation or video in its own window (ADR-106, ADR-174), the way a file gets one
/// (ADR-081): the same viewer, its own zoom, no tab and no session.
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
    /// A gallery of one: the window reads facts, the full image and a video's asynchronous load
    /// through the same caches the pane uses, and the zoom model rides along on it.
    private let gallery: ImageGallery

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
        let gallery = ImageGallery()
        self.gallery = gallery
        let facts = gallery.facts(path)
        window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.initialSize(facts)),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        super.init()
        let view = MediaWindowContent(path: path, caption: caption, gallery: gallery)
        window.contentView = NSHostingView(rootView: view.frame(minWidth: 280, minHeight: 200).clinicAppearance())
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.delegate = self
        window.minSize = NSSize(width: 280, height: 200)
        window.title = (path as NSString).lastPathComponent
        window.subtitle = facts.map(Self.subtitle) ?? ""
        window.representedURL = URL(fileURLWithPath: path)
        // No shared autosaved frame, unlike the file windows of ADR-081: an image window's *size* is
        // the image's, and a remembered frame would silently hand a 96 pt icon the frame the last
        // 3600 pt screenshot left behind (which is exactly what it did on the first run).
        window.center()
        if let last = Self.controllers.last?.window {
            window.setFrameOrigin(last.cascadeTopLeft(from: last.frame.origin))
        }
        // A video's size is only known once AVFoundation has read it, so its window opens at the
        // default and then takes the video's size, keeping its top-left corner where it opened.
        if facts == nil, VideoFile.isVideo(path) {
            Task { [weak self, gallery] in
                guard let facts = await gallery.loadedFacts(path), let self else { return }
                window.subtitle = Self.subtitle(facts)
                let top = window.frame.maxY
                var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: Self.initialSize(facts)))
                frame.origin = NSPoint(x: window.frame.minX, y: top - frame.height)
                window.setFrame(frame, display: true, animate: false)
            }
        }
    }

    private static func subtitle(_ facts: ImageFacts) -> String {
        [facts.dimensions, facts.length, facts.fileSize].compactMap { $0 }.joined(separator: " · ")
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

/// The window's content: `ImageDetailView` over the window's gallery of one, observed so a video's
/// facts land in its footer when they load.
private struct MediaWindowContent: View {
    let path: String
    let caption: String?
    let gallery: ImageGallery

    var body: some View {
        // A window is already open, so `.openWindow` and `.remove` have nothing to do here; ⌘C and
        // space mean the same thing they mean in the pane.
        ImageDetailView(path: path, caption: caption, image: gallery.image(path),
                        facts: gallery.facts(path), model: gallery.zoom) { command in
            switch command {
            case .copy: ImageClipboard.copy(path)
            case .quickLook: ImageQuickLook.shared.toggle(paths: [path], showing: path)
            case .openWindow, .remove, .step: break
            }
        }
    }
}
