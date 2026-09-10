import AppKit
import ImageIO
import Observation
import SwiftUI

/// Zoom, pan and the layout around them for one image (ADR-106).
///
/// The viewer is an `NSScrollView` with magnification rather than a SwiftUI `Image` in a frame:
/// pinch, two-finger scroll, ⌘/⌥-scroll zoom, live magnification and the scrollers all come from
/// AppKit, and what is left to write is the zoom *policy* — what fit means, what 1:1 means, and how
/// the image is drawn once you are past it.

/// What the pane's keys and menus ask for, from wherever they were pressed (ADR-107).
///
/// One enum rather than a closure per verb, because the same four verbs are reachable from three
/// places — the thumbnail list's key handling, the viewer's `keyDown`, and the menus — and the pane
/// is the only thing that can carry them out (Quick Look wants every image, Remove wants the store).
enum ImageCommand {
    case quickLook
    case openWindow
    case copy
    case remove
    /// ±1 through the gallery.
    case step(Int)
}

// MARK: - Preferences

/// Layout the Images panes and image windows share, in the shape ADR-081 set for the Files pane:
/// one observable object, persisted, because hiding the thumbnail list says how you look at images
/// rather than how one pane happens to be arranged.
@MainActor
@Observable
final class ImagePrefs {
    static let shared = ImagePrefs()
    static let showListKey = "ClinicImagesShowList"
    static let listWidthKey = "ClinicImagesListWidth"

    var showList: Bool { didSet { UserDefaults.standard.set(showList, forKey: Self.showListKey) } }
    /// The thumbnail column's width, as the user last dragged it.
    var listWidth: CGFloat { didSet { UserDefaults.standard.set(Double(listWidth), forKey: Self.listWidthKey) } }

    private init() {
        showList = UserDefaults.standard.object(forKey: Self.showListKey) as? Bool ?? true
        let stored = UserDefaults.standard.double(forKey: Self.listWidthKey)
        listWidth = stored > 0 ? CGFloat(stored) : 190
    }

    /// Wide enough for a thumbnail beside a caption; a thumbnail list narrower than that is a list
    /// of grey rectangles.
    static let minListWidth: CGFloat = 150
    static let maxListWidth: CGFloat = 340

    /// Never below a readable row, never leaving the viewer under 200 pt — the same shape of rule
    /// the other browsers apply to their own column (ADR-081, ADR-102).
    static func clamp(_ width: CGFloat, available: CGFloat) -> CGFloat {
        let upper = max(minListWidth, min(maxListWidth, available - 200))
        return min(max(width, minListWidth), upper)
    }
}

// MARK: - Reading the file

/// What the panel can say about an image without decoding it whole.
struct ImageFacts: Equatable, Sendable {
    var pixels: CGSize
    var bytes: Int

    var dimensions: String { "\(Int(pixels.width)) × \(Int(pixels.height))" }
    var fileSize: String { ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) }
}

/// ImageIO rather than `NSImage`: the properties of a 20-megapixel PNG are a header read, and a
/// thumbnail for a 44 pt row should never be a full decode plus a downscale.
enum ImageFile {
    static func facts(_ path: String) -> ImageFacts? {
        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Double,
              let height = props[kCGImagePropertyPixelHeight] as? Double
        else { return nil }
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return ImageFacts(pixels: CGSize(width: width, height: height), bytes: bytes)
    }

    static func thumbnail(_ path: String, maxPixel: CGFloat) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    static func full(_ path: String) -> NSImage? { NSImage(contentsOfFile: path) }
}

// MARK: - The scroll view

/// The image's canvas: the document view of `ImageZoomView`, sized in *image pixels*.
///
/// Sizing the document view in pixels rather than in `NSImage.size` points is what makes a zoom
/// percentage mean something: a screenshot's `NSImage` reports its size in points on the display it
/// was taken from, so two files of the same pixel dimensions could otherwise disagree about 100%.
///
/// The image is a **layer's contents**, not something this view draws. Drawing it was the obvious
/// first version and wrong twice over: a 3600 × 2338 document view inside SwiftUI's layer-backed
/// hosting view allocates a backing store of that size times the display scale — about 134 MB for
/// one screenshot — and magnification then scales that rasterisation rather than re-running `draw`,
/// so every zoom past 100% came out blurred by Core Animation's filter no matter what
/// `imageInterpolation` was set to. A layer's contents cost the image's own bitmap once, at any zoom.
@MainActor
private final class ImageCanvas: NSView {
    var image: NSImage? {
        didSet {
            imageLayer.contents = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
            needsLayout = true
        }
    }

    /// Set while the pointer is dragging the image around; the cursor is pushed for the duration.
    private var dragAnchor: NSPoint?
    private let imageLayer = CALayer()

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // Nothing to rasterise: everything on screen is either this layer's contents or the scroll
        // view's own drawing, so AppKit need not keep a backing store for the document's whole size.
        layerContentsRedrawPolicy = .never
        // One image pixel per point of the canvas, which is what makes the canvas's pixel-sized
        // frame mean 100%.
        imageLayer.contentsScale = 1
        imageLayer.contentsGravity = .resize
        imageLayer.minificationFilter = .trilinear
        layer?.addSublayer(imageLayer)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        imageLayer.frame = bounds
    }

    /// Past about 150% the reader is looking *at* pixels — a screenshot's text, an icon's edge — and
    /// smoothing them smooths away the thing they zoomed in to see.
    func setMagnified(_ magnified: Bool) {
        let filter: CALayerContentsFilter = magnified ? .nearest : .linear
        if imageLayer.magnificationFilter != filter { imageLayer.magnificationFilter = filter }
    }

    private var zoomView: ImageZoomView? { enclosingScrollView as? ImageZoomView }

    // MARK: Panning

    override func resetCursorRects() {
        guard let clip = enclosingScrollView?.contentView else { return }
        // Only offer the hand when there is somewhere to drag to.
        if frame.width > clip.bounds.width + 0.5 || frame.height > clip.bounds.height + 0.5 {
            addCursorRect(bounds, cursor: .openHand)
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if event.clickCount == 2 { zoomView?.toggleFitAndActualSize(); return }
        dragAnchor = convert(event.locationInWindow, from: nil)
        NSCursor.closedHand.push()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let anchor = dragAnchor, let clip = enclosingScrollView?.contentView else { return }
        // The anchor is deliberately *not* updated: the origin moves by exactly the drag's delta, so
        // the document point under the pointer stays put and converting the same window location
        // returns the same anchor again. Re-anchoring every frame is the bug ADR-081 hit with the
        // tree handle — the origin chases the pointer.
        let now = convert(event.locationInWindow, from: nil)
        var origin = clip.bounds.origin
        origin.x -= now.x - anchor.x
        origin.y -= now.y - anchor.y
        clip.scroll(to: origin)
        enclosingScrollView?.reflectScrolledClipView(clip)
    }

    override func mouseUp(with event: NSEvent) {
        if dragAnchor != nil { NSCursor.pop() }
        dragAnchor = nil
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        guard let zoomView else { return super.keyDown(with: event) }
        // Arrows walk the gallery rather than nudging the image about. Panning already has three
        // ways in — the hand cursor, two-finger scroll and the scrollers — and stepping through the
        // images had none from the keyboard, which is what the pane is mostly for.
        if let key = event.specialKey {
            if key == .upArrow || key == .leftArrow { zoomView.onStep?(-1); return }
            if key == .downArrow || key == .rightArrow { zoomView.onStep?(1); return }
        }
        if event.modifierFlags.contains(.command), event.specialKey == .delete || event.specialKey == .backspace {
            zoomView.onCommand?(.remove)
            return
        }
        switch event.charactersIgnoringModifiers {
        case "+", "=": zoomView.step(1)
        case "-", "_": zoomView.step(-1)
        case "0": zoomView.fitToWindow()
        case "1": zoomView.setZoom(1)
        // Finder's two: space previews, return opens.
        case " ": zoomView.onCommand?(.quickLook)
        case "\r", "\n": zoomView.onCommand?(.openWindow)
        default: super.keyDown(with: event)
        }
    }

    /// So ⌘C — and Edit ▸ Copy, which is where the menu bar says ⌘C lives — reach the image while the
    /// viewer has the keyboard. Implementing the action is also what *enables* that menu item;
    /// without it the item is grey and says the shortcut does nothing.
    @objc func copy(_ sender: Any?) { zoomView?.onCommand?(.copy) }

}

/// Keeps an image smaller than its viewport centred instead of pinned to the top-left corner.
@MainActor
private final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let document = documentView else { return rect }
        if rect.width > document.frame.width { rect.origin.x = (document.frame.width - rect.width) / 2 }
        if rect.height > document.frame.height { rect.origin.y = (document.frame.height - rect.height) / 2 }
        return rect
    }
}

/// One image, zoomable and pannable.
///
/// **Zoom is measured in device pixels per image pixel**, so 100% is one pixel of the file on one
/// pixel of the display — the only level at which what you are inspecting is what the file holds,
/// and the level at which a Retina screenshot is exactly the size of the screen it came from.
/// `magnification` (AppKit's own scale, points per document point) is therefore `zoom / backingScale`.
@MainActor
final class ImageZoomView: NSScrollView {
    static let minZoom: CGFloat = 0.02
    static let maxZoom: CGFloat = 32
    /// √2 per press: coarse enough to cross a decade in six presses, fine enough to land near 100%.
    static let stepFactor: CGFloat = 1.414_213_6

    private(set) var zoom: CGFloat = 1
    /// True while the viewer is showing the whole image and should re-fit when its column resizes.
    private(set) var isFitting = true

    /// Reports `(zoom, isFitting)` after anything changes either.
    var onChange: ((CGFloat, Bool) -> Void)?
    /// ⌥↑ / ⌥↓, and the viewer's own scroll-past gestures: walk the gallery by ±1.
    var onStep: ((Int) -> Void)?
    /// Space, return, ⌘C, ⌘⌫ — the verbs the pane, not the viewer, carries out.
    var onCommand: ((ImageCommand) -> Void)?

    private let canvas = ImageCanvas()
    private var key: String?
    private var refitting = false

    private var backingScale: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }

    override init(frame: NSRect) {
        super.init(frame: frame)
        // Same modern-SDK default as the canvas: without this, `draw`'s matte fill follows the dirty
        // rect straight over the pane's headers and list. It painted the whole window on the first run.
        clipsToBounds = true
        let clip = CenteringClipView()
        clip.drawsBackground = false
        contentView = clip
        documentView = canvas
        hasVerticalScroller = true
        hasHorizontalScroller = true
        autohidesScrollers = true
        scrollerStyle = .overlay
        allowsMagnification = true
        applyMagnificationLimits()
        // The matte, the checkerboard and the image's outline are all painted by `draw` below, so
        // AppKit must not fill the view first.
        drawsBackground = false
        contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(boundsChanged),
                                               name: NSView.boundsDidChangeNotification, object: contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(boundsChanged),
                                               name: NSScrollView.didEndLiveMagnifyNotification, object: self)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Gives the pane's keyboard to the image. Clicking a thumbnail row calls this: **the viewer is
    /// the pane's one responder**, because SwiftUI's `.onKeyPress` never sees a command chord — a
    /// focusable list handled ↑/↓/space/return and silently dropped ⌘C and ⌘⌫ (measured 2026-09-10),
    /// and one keyboard that answers every key beats two that each answer some.
    func focusDocument() { window?.makeFirstResponder(canvas) }

    /// Shows `image`, resetting the zoom only when the file actually changes: re-running SwiftUI's
    /// update for an unrelated reason must not throw away where the reader had zoomed to.
    func show(image: NSImage?, pixels: CGSize, key: String) {
        guard key != self.key else { return }
        self.key = key
        canvas.image = image
        let size = pixels.width > 1 && pixels.height > 1 ? pixels : (image?.size ?? NSSize(width: 1, height: 1))
        canvas.frame = NSRect(origin: .zero, size: size)
        isFitting = true
        fitToWindow()
    }

    // MARK: Zoom policy

    /// The zoom at which the whole image is visible — **never above 100%**. Blowing a 16 pt icon up
    /// to fill a 600 pt panel is not "fit", it is a decision the reader did not ask for; the `+`
    /// button is right there when they do.
    private var fitZoom: CGFloat {
        let size = canvas.frame.size
        let visible = contentView.frame.size
        guard size.width > 0, size.height > 0, visible.width > 0, visible.height > 0 else { return 1 }
        let magnification = min(visible.width / size.width, visible.height / size.height)
        // Clamped here rather than only in `apply`, so `layout`'s "am I still fitting?" test compares
        // against a zoom that is actually reachable — otherwise an image too large to fit even at the
        // minimum zoom re-fits on every layout pass, forever.
        return min(max(min(magnification * backingScale, 1), Self.minZoom), Self.maxZoom)
    }

    func fitToWindow() {
        isFitting = true
        apply(zoom: fitZoom, centeredAt: nil)
    }

    func setZoom(_ value: CGFloat, centeredAt point: NSPoint? = nil) {
        isFitting = false
        apply(zoom: value, centeredAt: point)
    }

    func step(_ direction: Int) {
        setZoom(direction > 0 ? zoom * Self.stepFactor : zoom / Self.stepFactor)
    }

    /// The double-click gesture: zoom in from a fitted image, and back to fitted from anywhere else.
    /// `max(1, …)` is what makes the first double-click on a downscaled screenshot land on 100%
    /// rather than on some fraction of it.
    func toggleFitAndActualSize() {
        if isFitting { setZoom(max(1, zoom * 2)) } else { fitToWindow() }
    }

    private func apply(zoom value: CGFloat, centeredAt point: NSPoint?) {
        let clamped = min(max(value, Self.minZoom), Self.maxZoom)
        refitting = true
        if let point {
            setMagnification(clamped / backingScale, centeredAt: point)
        } else {
            magnification = clamped / backingScale
        }
        refitting = false
        // Read the magnification *back* rather than trusting the value just written: AppKit clamps
        // it to `minMagnification`/`maxMagnification`, and a readout that reports what it asked for
        // instead of what happened is how a fitted 3600 pt screenshot came up cropped at "32%" —
        // the default `minMagnification` is 0.25, which is a 50% zoom on a Retina display.
        zoom = magnification * backingScale
        report()
    }

    /// AppKit's limits, in AppKit's units. Re-applied when the window changes display, because the
    /// zoom the reader chose is in device pixels and a point holds a different number of those.
    private func applyMagnificationLimits() {
        minMagnification = Self.minZoom / backingScale
        maxMagnification = Self.maxZoom / backingScale
    }

    private func report() {
        canvas.setMagnified(zoom > 1.5)
        // The hand only belongs on the pointer while there is somewhere to drag to, and that answer
        // changes with every zoom.
        window?.invalidateCursorRects(for: canvas)
        // The checkerboard and the outline are drawn where the image *currently* is, so they follow
        // it (see `draw`).
        needsDisplay = true
        onChange?(zoom, isFitting)
    }

    @objc private func boundsChanged() {
        needsDisplay = true
        guard !refitting else { return }
        // Fires for panning too, where the zoom has not moved and this is a no-op.
        let current = magnification * backingScale
        guard abs(current - zoom) > 0.0001 else { return }
        zoom = current
        report()
    }

    // MARK: The matte, the checkerboard and the outline

    /// Everything that is not the image itself is painted here, in the **scroll view's** own
    /// coordinates — which is why it costs nothing: this view is never magnified, so its backing
    /// store is the size of the pane and its checkerboard squares stay a constant size on screen at
    /// any zoom. Painting them in the document view instead is what made a 3600 pt canvas allocate a
    /// backing store to match.
    override func draw(_ dirtyRect: NSRect) {
        NSColor.underPageBackgroundColor.setFill()
        dirtyRect.intersection(bounds).fill()
        guard canvas.image != nil else { return }
        let frame = convert(canvas.bounds, from: canvas).intersection(bounds)
        guard !frame.isEmpty else { return }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: frame).setClip()
        // So a transparent PNG reads as transparent rather than as white-on-white or black-on-black.
        NSColor.textBackgroundColor.setFill()
        frame.fill()
        NSColor.systemGray.withAlphaComponent(0.13).setFill()
        let cell: CGFloat = 9
        let path = NSBezierPath()
        var row = 0
        var y = frame.minY
        while y < frame.maxY {
            var column = 0
            var x = frame.minX
            while x < frame.maxX {
                if (row + column).isMultiple(of: 2) {
                    path.appendRect(NSRect(x: x, y: y, width: cell, height: cell).intersection(frame))
                }
                x += cell; column += 1
            }
            y += cell; row += 1
        }
        path.fill()
        NSGraphicsContext.restoreGraphicsState()
        // A hairline so the picture's edge is visible against the matte even where its own pixels
        // are transparent.
        NSColor.separatorColor.setStroke()
        NSBezierPath(rect: frame.insetBy(dx: 0.5, dy: 0.5)).stroke()
    }

    // MARK: Gestures

    override func magnify(with event: NSEvent) {
        isFitting = false
        super.magnify(with: event)
    }

    /// ⌘- or ⌥-scroll zooms about the pointer, which is how every other image viewer on this machine
    /// behaves and the only zoom that keeps the detail you are aiming at under the cursor.
    override func scrollWheel(with event: NSEvent) {
        guard event.modifierFlags.contains(.command) || event.modifierFlags.contains(.option) else {
            return super.scrollWheel(with: event)
        }
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 180 : event.scrollingDeltaY / 18
        guard delta != 0 else { return }
        let point = contentView.convert(event.locationInWindow, from: nil)
        setZoom(zoom * (1 + delta), centeredAt: point)
    }

    override func layout() {
        super.layout()
        // The column the viewer lives in is resizable — the panel's own divider, the tab's window,
        // the thumbnail list opening — and a fitted image that stops fitting when its column grows
        // is the complaint this whole ADR started from.
        if isFitting, abs(fitZoom - zoom) > 0.001 { apply(zoom: fitZoom, centeredAt: nil) }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        // A move to a non-Retina display halves the device pixels a point holds; the zoom the reader
        // chose is in device pixels, so the magnification behind it has to change to keep it.
        applyMagnificationLimits()
        apply(zoom: zoom, centeredAt: nil)
    }
}

// MARK: - SwiftUI

/// The handle SwiftUI holds on the viewer: it reads `zoom` and `isFitting` to draw the zoom control
/// and calls back in for the verbs. The view itself is AppKit's, so the commands are messages rather
/// than state that has to round-trip through a binding.
@MainActor
@Observable
final class ImageZoomModel {
    fileprivate(set) var zoom: CGFloat = 1
    fileprivate(set) var isFitting = true
    @ObservationIgnored fileprivate weak var view: ImageZoomView?

    var percent: Int { Int((zoom * 100).rounded()) }
    var canZoomIn: Bool { zoom < ImageZoomView.maxZoom - 0.001 }
    var canZoomOut: Bool { zoom > ImageZoomView.minZoom + 0.001 }
    func focusViewer() { view?.focusDocument() }
    func fit() { view?.fitToWindow() }
    func actualSize() { view?.setZoom(1) }
    func zoomIn() { view?.step(1) }
    func zoomOut() { view?.step(-1) }
    func set(_ value: CGFloat) { view?.setZoom(value) }
}

struct ImageZoomCanvas: NSViewRepresentable {
    let image: NSImage?
    let pixels: CGSize
    /// Identity of the file on screen: the viewer resets its zoom when this changes and only then.
    let key: String
    let model: ImageZoomModel
    var onStep: (Int) -> Void = { _ in }
    var onCommand: (ImageCommand) -> Void = { _ in }

    func makeNSView(context: Context) -> ImageZoomView {
        let view = ImageZoomView(frame: .zero)
        view.onChange = { [weak model] zoom, fitting in
            model?.zoom = zoom
            model?.isFitting = fitting
        }
        model.view = view
        return view
    }

    func updateNSView(_ view: ImageZoomView, context: Context) {
        model.view = view
        view.onStep = onStep
        view.onCommand = onCommand
        view.show(image: image, pixels: pixels, key: key)
    }
}

/// The viewer's footer: the zoom verbs on the left, the file's facts on the right.
///
/// A real band under the image rather than a control floating over it. A floating one was tried
/// first and is *not clickable*: an `NSViewRepresentable` is a real `NSView` subview of the hosting
/// view, and AppKit's `hitTest` hands the mouse to the topmost **subview** containing the point — so
/// SwiftUI content drawn above the scroll view still loses every click to it. The capsule rendered
/// perfectly and did nothing, which is a worse bug than the one this ADR set out to fix.
struct ImageZoomBar: View {
    let model: ImageZoomModel
    var facts: ImageFacts?

    var body: some View {
        HStack(spacing: 2) {
            button("minus.magnifyingglass", "Zoom out (−)", enabled: model.canZoomOut) { model.zoomOut() }
            Menu {
                Button("Fit") { model.fit() }
                Button("Actual Size (100%)") { model.actualSize() }
                Divider()
                ForEach([0.25, 0.5, 1.0, 2.0, 4.0, 8.0], id: \.self) { level in
                    Button("\(Int(level * 100))%") { model.set(level) }
                }
            } label: {
                Text("\(model.percent)%")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .frame(minWidth: 40)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Zoom level")
            button("plus.magnifyingglass", "Zoom in (+)", enabled: model.canZoomIn) { model.zoomIn() }
            button(model.isFitting ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                   model.isFitting ? "Actual size (1)" : "Fit the image (0)", enabled: true) {
                if model.isFitting { model.actualSize() } else { model.fit() }
            }
            Spacer(minLength: 6)
            if let facts {
                // The detail column is about 210 pt wide at the pane's floor with the list open, so
                // the facts give way to the zoom verbs rather than pushing them off the band
                // (the same fall-through ADR-104 uses for the panel's own tab strip).
                ViewThatFits(in: .horizontal) {
                    factsLabel("\(facts.dimensions)  ·  \(facts.fileSize)")
                    factsLabel(facts.dimensions)
                    EmptyView()
                }
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 28)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    private func factsLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11).monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize()
    }

    private func button(_ symbol: String, _ help: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(enabled ? Color.secondary : Color.secondary.opacity(0.35))
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
    }
}

/// The viewer proper: one image, its caption, and its zoom bar.
///
/// Used by the Images pane's detail column and by an image window, so the two cannot drift — and so
/// a window gets the zoom controls by construction rather than by being wired up twice.
struct ImageDetailView: View {
    let path: String
    let caption: String?
    let image: NSImage?
    let facts: ImageFacts?
    let model: ImageZoomModel
    var onCommand: (ImageCommand) -> Void = { _ in }

    var body: some View {
        VStack(spacing: 0) {
            if let image {
                ImageZoomCanvas(image: image, pixels: facts?.pixels ?? image.size, key: path, model: model,
                                onStep: { onCommand(.step($0)) }, onCommand: onCommand)
            } else {
                ContentUnavailableView("Can't read this image",
                                       systemImage: "exclamationmark.triangle",
                                       description: Text(path).font(.system(size: 11, design: .monospaced)))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let caption, !caption.isEmpty {
                Divider()
                // The agent's words about the image, and often the only thing that says why it is
                // here — so it is on screen rather than in a tooltip, but capped at two lines and
                // set secondary: it is a label for the picture, not a paragraph above it.
                Text(caption)
                    .font(.system(size: PaneMetrics.label))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, PaneMetrics.padding)
                    .padding(.vertical, 6)
                    .background(.bar)
                    .help(caption)
            }
            Divider()
            ImageZoomBar(model: model, facts: facts)
        }
    }
}
