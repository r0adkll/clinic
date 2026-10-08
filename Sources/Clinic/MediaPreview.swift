import AppKit
import CryptoKit
import SwiftUI
import UniformTypeIdentifiers
import ClinicCore

/// Files the Files pane and the Diff panel show as pictures rather than as text (ADR-189): every
/// image type the system can decode, SVG and PDF among them, and every movie type AVKit can play.
///
/// Decided by the file's type, as `VideoFile.isVideo` is: the pane chooses a viewer in a view body,
/// and a file is a picture by what it is, not by whether it happens to decode.
enum MediaFile {
    static func isMedia(_ path: String) -> Bool { type(of: path) != nil }

    /// Vector formats are drawn by the system at whatever size they are asked for, and have no pixels
    /// of their own — so the canvas rasterises them larger than they say (see `ImageFile.open`).
    static func isVector(_ path: String) -> Bool {
        guard let type = type(of: path) else { return false }
        return type.conforms(to: .svg) || type.conforms(to: .pdf)
    }

    /// What the header calls it where a code file's language goes: *PNG image*, *SVG image*,
    /// *QuickTime movie*.
    static func label(_ path: String) -> String {
        type(of: path)?.localizedDescription ?? "Image"
    }

    private static func type(of path: String) -> UTType? {
        let ext = (path as NSString).pathExtension
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return nil }
        return type.conforms(to: .image) || type.conforms(to: .pdf) || type.conforms(to: .movie) ? type : nil
    }
}

/// One file read for a viewer: the picture and its facts. A video has no picture here — its player
/// reads the file itself — and its facts arrive later, because AVFoundation answers asynchronously.
struct MediaLoad: Sendable {
    var image: NSImage?
    var facts: ImageFacts?
    var isVideo: Bool
}

extension ImageFile {
    /// Reads a file for the Files pane (ADR-189). A raster image comes back as the Media pane reads it.
    /// A vector image is rasterised so that its long edge is at least 1024 device pixels: the system
    /// would otherwise draw a 24 pt icon as 24 pixels, and zooming in on it would show nothing but
    /// the zoom.
    static func open(_ path: String) -> MediaLoad {
        if VideoFile.isVideo(path) { return MediaLoad(image: nil, facts: nil, isVideo: true) }
        guard let image = full(path) else { return MediaLoad(image: nil, facts: nil, isVideo: false) }
        if MediaFile.isVector(path) {
            let bytes = (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let (raster, pixels) = rasterise(image)
            return MediaLoad(image: raster, facts: ImageFacts(pixels: image.size, bytes: bytes, raster: pixels), isVideo: false)
        }
        return MediaLoad(image: image, facts: facts(path), isVideo: false)
    }

    /// A vector image drawn into a bitmap: at least 1024 pixels on its long edge, at most 4096, and
    /// never less than twice its point size.
    private static func rasterise(_ image: NSImage) -> (NSImage, CGSize) {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return (image, size) }
        let long = max(size.width, size.height)
        let scale = min(4096 / long, max(2, 1024 / long))
        let pixels = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(pixels.width), pixelsHigh: Int(pixels.height),
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return (image, size) }
        bitmap.size = pixels
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return (image, size) }
        NSGraphicsContext.current = context
        context.cgContext.interpolationQuality = .high
        image.draw(in: NSRect(origin: .zero, size: pixels), from: .zero, operation: .copy, fraction: 1)
        let out = NSImage(size: pixels)
        out.addRepresentation(bitmap)
        return (out, pixels)
    }
}

/// The switch between a picture and its source, for a file that is both — an SVG (ADR-189). One
/// button in the file bar of the Files pane and the Diff panel, so the two read the same.
struct MediaSourceToggle: View {
    @Binding var showsSource: Bool

    var body: some View {
        PaneIconButton(symbol: showsSource ? "photo" : "chevron.left.forwardslash.chevron.right",
                       help: showsSource ? "Show the image" : "Show the source",
                       isOn: showsSource) { showsSource.toggle() }
    }
}

// MARK: - The Files pane

/// The Files pane's viewer for a picture (ADR-189): the Media pane's own detail view — zoom canvas,
/// player, facts bar — over the file the pane has open.
struct MediaFileView: View {
    let path: String
    let media: MediaLoad
    @State private var zoom = ImageZoomModel()

    var body: some View {
        ImageDetailView(path: path, caption: nil, image: media.image, facts: media.facts, model: zoom)
            .background(Color(nsColor: .textBackgroundColor))
    }
}

// MARK: - The Diff panel

/// Where the Diff panel's pictures come from (ADR-189). A side of a diff is a blob in a tree, not a
/// file on disk, and both the animation player and AVKit read from a path — so each blob is written
/// once to the app's caches, named by its contents, and shown from there. The Dev flavor has its own
/// caches folder, like everything else it owns (ADR-176).
enum DiffMediaCache {
    private static var directory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let bundle = Bundle.main.bundleIdentifier ?? "com.r0adkll.clinic"
        return caches.appendingPathComponent(bundle, isDirectory: true).appendingPathComponent("DiffMedia", isDirectory: true)
    }

    /// The path `data` can be read from, under the file's own extension so every type check still
    /// answers for it. Written only when it is not there already.
    static func path(for data: Data, extension ext: String) -> String? {
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let name = ext.isEmpty ? digest : "\(digest).\(ext)"
        let url = directory.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: url.path) { return url.path }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return url.path
        } catch { return nil }
    }
}

/// One side of a picture's diff, loaded: its file in the cache and what the viewer needs of it.
struct DiffMediaSide: Identifiable, Sendable {
    let id: DiffContentSource.Side
    let path: String
    let media: MediaLoad
}

/// A picture's diff (ADR-189): the file as it was and as it is, each in its own viewer, beside each
/// other where the panel is wide enough and one above the other where it is not. An added file shows
/// one side, a deleted file the other.
struct DiffMediaView: View {
    let browser: DiffBrowser
    let file: UnifiedDiffFile
    @State private var sides: [DiffMediaSide]?
    @State private var oldZoom = ImageZoomModel()
    @State private var newZoom = ImageZoomModel()

    var body: some View {
        Group {
            if let sides {
                if sides.isEmpty {
                    ContentUnavailableView("Can't read this image", systemImage: "exclamationmark.triangle",
                                           description: Text(file.path).font(.system(size: 11, design: .monospaced)))
                } else {
                    GeometryReader { geo in
                        let stacked = sides.count > 1 && geo.size.width < 640
                        let layout = stacked ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: 0))
                        layout {
                            ForEach(sides) { side in
                                self.side(side, stacked: stacked)
                                if side.id == .old, sides.count > 1 { Divider() }
                            }
                        }
                        .frame(width: geo.size.width, height: geo.size.height)
                    }
                }
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .task(id: file.contentKey) { await load() }
    }

    private func side(_ side: DiffMediaSide, stacked: Bool) -> some View {
        VStack(spacing: 0) {
            // Named only when there are two: one picture under *After* says the other is missing,
            // when the chip in the file bar already says the file is new or gone.
            if sides?.count ?? 0 > 1 {
                HStack(spacing: 6) {
                    Text(side.id == .old ? "Before" : "After")
                        .font(.system(size: PaneMetrics.label, weight: .medium))
                        .foregroundStyle(side.id == .old ? Color.red : Color.green)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, PaneMetrics.padding)
                .frame(height: 24)
                .background(.bar)
                Divider()
            }
            ImageDetailView(path: side.path, caption: nil, image: side.media.image, facts: side.media.facts,
                            model: side.id == .old ? oldZoom : newZoom)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Both sides at once: each is a `git cat-file`, and the old one is usually in the repository's
    /// own objects rather than the scratch store, so neither waits on the other.
    private func load() async {
        let ext = (file.path as NSString).pathExtension
        async let old: DiffMediaSide? = file.isNew ? nil : read(.old, extension: ext)
        async let new: DiffMediaSide? = file.isDeleted ? nil : read(.new, extension: ext)
        let loaded = await [old, new].compactMap { $0 }
        guard !Task.isCancelled else { return }
        sides = loaded
    }

    private func read(_ side: DiffContentSource.Side, extension ext: String) async -> DiffMediaSide? {
        guard let data = await browser.data(of: file, side: side), !data.isEmpty,
              let path = DiffMediaCache.path(for: data, extension: ext) else { return nil }
        var media = await Task.detached(priority: .userInitiated) { ImageFile.open(path) }.value
        if media.isVideo { media.facts = await VideoFile.facts(path) }
        return DiffMediaSide(id: side, path: path, media: media)
    }
}
