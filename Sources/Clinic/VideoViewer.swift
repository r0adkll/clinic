import AppKit
import AVFoundation
import AVKit
import SwiftUI
import UniformTypeIdentifiers

/// Videos in the Media pane (ADR-174): AVKit's own player, beside the image viewer rather than
/// inside it.
///
/// `AVPlayerView` rather than a player layer on the zoom canvas: it arrives with the scrubber and its
/// thumbnails, volume, speed, frame stepping, full screen and picture in picture, and pinch to zoom —
/// every verb a reader of a screen recording wants, none of which Clinic would draw as well.

enum VideoFile {
    /// Decided by the file's type, not by opening it: the pane has to choose a viewer in a view body,
    /// and an `AVAsset` answers "is this playable" only asynchronously.
    static func isVideo(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension
        return !ext.isEmpty && UTType(filenameExtension: ext)?.conforms(to: .movie) == true
    }

    /// Pixel dimensions (after the track's rotation), length and size on disk.
    static func facts(_ path: String) async -> ImageFacts? {
        let url = URL(fileURLWithPath: path)
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let (size, transform) = try? await track.load(.naturalSize, .preferredTransform)
        else { return nil }
        let pixels = CGRect(origin: .zero, size: size).applying(transform).size
        let duration = try? await asset.load(.duration)
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return ImageFacts(pixels: CGSize(width: abs(pixels.width), height: abs(pixels.height)), bytes: bytes,
                          kind: .video, duration: duration.map(\.seconds).flatMap { $0.isFinite ? $0 : nil })
    }

    /// A frame a moment in rather than the very first, which in a screen recording is often black or
    /// the window still settling.
    static func thumbnail(_ path: String, maxPixel: CGFloat) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: URL(fileURLWithPath: path)))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        generator.requestedTimeToleranceAfter = .positiveInfinity
        if let (image, _) = try? await generator.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)) { return image }
        return try? await generator.image(at: .zero).image
    }
}

/// The player, answering the pane's keyboard (ADR-107) where the player has no use for a key.
///
/// Space, ← / → and J K L are the player's own — play, step a frame, shuttle — as they are in
/// QuickTime. ↑ / ↓ still walk the gallery, return still opens a window, ⌘C and ⌘⌫ still copy and
/// remove, so the pane has one keyboard whichever kind of file is selected.
@MainActor
final class VideoPlayerView: AVPlayerView {
    private(set) var path: String?
    var onCommand: ((ImageCommand) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    func load(_ path: String) {
        guard path != self.path else { return }
        self.path = path
        player?.pause()
        // Not played on arrival, unlike an animation: a video can have sound, and the agent showing
        // one should not start talking over the reader's work.
        player = AVPlayer(url: URL(fileURLWithPath: path))
    }

    func unload() {
        player?.pause()
        player = nil
        path = nil
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if let key = event.specialKey {
            if key == .upArrow { onCommand?(.step(-1)); return }
            if key == .downArrow { onCommand?(.step(1)); return }
            if event.modifierFlags.contains(.command), key == .delete || key == .backspace {
                onCommand?(.remove)
                return
            }
        }
        if event.charactersIgnoringModifiers == "\r" { onCommand?(.openWindow); return }
        super.keyDown(with: event)
    }

    @objc func copy(_ sender: Any?) { onCommand?(.copy) }
}

struct VideoCanvas: NSViewRepresentable {
    let path: String
    let model: ImageZoomModel
    var onCommand: (ImageCommand) -> Void = { _ in }

    func makeNSView(context: Context) -> VideoPlayerView {
        let view = VideoPlayerView()
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = true
        view.showsFrameSteppingButtons = true
        view.allowsPictureInPicturePlayback = true
        view.allowsMagnification = true
        return view
    }

    func updateNSView(_ view: VideoPlayerView, context: Context) {
        model.keyView = view
        view.onCommand = onCommand
        view.load(path)
    }

    /// The pane hidden, the tab switched, another file selected: the player stops with its view
    /// rather than playing on, unheard and unseen.
    static func dismantleNSView(_ view: VideoPlayerView, coordinator: ()) {
        view.unload()
    }
}
