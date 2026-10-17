import AppKit
import Observation
import SwiftUI
import AndroidEmulator

// PROTOTYPE (docs/Research/Embedded Android Emulator.md): an Android emulator drawn in a workspace pane
// the way Android Studio's Running Devices panel draws it — the emulator's own window hidden, its screen
// streamed over gRPC into shared memory, the mouse and keyboard sent back as touches and keys.

/// The emulators running now, for the `+` menu and the empty panel. Rescanned every two seconds while
/// anything is watching; a scan is one directory listing.
@MainActor
@Observable
final class EmulatorDirectory {
    static let shared = EmulatorDirectory()
    private(set) var running: [RunningEmulator] = []
    @ObservationIgnored private var task: Task<Void, Never>?

    private init() {
        running = RunningEmulator.scan()
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                let found = await Task.detached { RunningEmulator.scan() }.value
                guard let self else { return }
                if found != self.running { self.running = found }
            }
        }
    }

    func emulator(_ avdId: String) -> RunningEmulator? { running.first { $0.avdId == avdId } }
}

/// One Device pane's connection to its emulator. Long-lived on the pane, so moving the pane between
/// areas keeps the connection; the stream itself runs only while the screen view is in a window.
@MainActor
@Observable
final class DeviceScreenModel {
    enum Status: Equatable { case connecting, live, notRunning, failed(String) }

    let avdId: String
    private(set) var status: Status = .connecting
    /// Device pixels, which touches are given in.
    private(set) var displaySize: CGSize?
    @ObservationIgnored private(set) var connection: EmulatorConnection?
    @ObservationIgnored private var stream: Task<Void, Never>?
    @ObservationIgnored private var streamSize: (Int, Int)?
    @ObservationIgnored weak var screen: DeviceScreenNSView?

    init(avdId: String) { self.avdId = avdId }

    var name: String { EmulatorDirectory.shared.emulator(avdId)?.name ?? avdId.replacingOccurrences(of: "_", with: " ") }

    /// Streams frames sized to `pixels` (the view's size in backing pixels), restarting the stream when
    /// that size changes, since the emulator scales each frame to the size asked for.
    func show(at pixels: CGSize) {
        guard pixels.width >= 16, pixels.height >= 16 else { return }
        Task { await connectIfNeeded(); startStream(pixels) }
    }

    func hide() {
        stream?.cancel(); stream = nil; streamSize = nil
    }

    func stop() {
        hide()
        connection?.close(); connection = nil
    }

    private func connectIfNeeded() async {
        guard connection == nil else { return }
        guard let emulator = EmulatorDirectory.shared.emulator(avdId) ?? RunningEmulator.scan().first(where: { $0.avdId == avdId }) else {
            status = .notRunning; return
        }
        do {
            let connection = try EmulatorConnection(emulator)
            let size = try await connection.displaySize()
            self.connection = connection
            displaySize = CGSize(width: size.width, height: size.height)
            status = .live
        } catch {
            status = .failed("\(error)")
        }
    }

    private func startStream(_ pixels: CGSize) {
        guard let connection, let display = displaySize else { return }
        // Never ask for more than the display has: the emulator would only scale back down.
        let scale = min(1, pixels.width / display.width, pixels.height / display.height)
        let size = (Int(display.width * scale), Int(display.height * scale))
        if stream != nil, let current = streamSize, current == size { return }
        stream?.cancel()
        streamSize = size
        stream = Task { [weak self] in
            do {
                for try await frame in connection.frames(width: size.0, height: size.1) {
                    self?.screen?.draw(frame)
                }
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled, let self else { return }
                // The emulator went away, or the stream failed; the next show() reconnects.
                self.connection?.close(); self.connection = nil; self.stream = nil
                self.status = EmulatorDirectory.shared.emulator(self.avdId) == nil ? .notRunning : .failed("\(error)")
            }
        }
    }

    func press(_ key: String) { connection?.press(key) }

    /// Tries again once the emulator is (back) in the running list: putting the screen back on screen
    /// makes it ask for frames, which connects.
    func retry() { if status != .live { status = .connecting } }
}

/// The emulator's screen: frames drawn aspect-fit into a layer; clicks and drags become one finger,
/// the scroll wheel scrolls, and keys typed while it has the keyboard go to the device — except ⌘
/// chords, which reach Clinic's menus first.
final class DeviceScreenNSView: NSView {
    let model: DeviceScreenModel
    private let screenLayer = CALayer()
    private var frameSize: CGSize?
    private var scrollRemainder = CGPoint.zero

    init(model: DeviceScreenModel) {
        self.model = model
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        screenLayer.contentsGravity = .resizeAspect
        screenLayer.magnificationFilter = .linear
        screenLayer.minificationFilter = .trilinear
        layer?.addSublayer(screenLayer)
        model.screen = self
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { model.hide() } else { requestFrames() }
    }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        screenLayer.frame = bounds
        CATransaction.commit()
        requestFrames()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        screenLayer.contentsScale = window?.backingScaleFactor ?? 2
        requestFrames()
    }

    private func requestFrames() {
        guard window != nil else { return }
        let scale = window?.backingScaleFactor ?? 2
        model.show(at: CGSize(width: bounds.width * scale, height: bounds.height * scale))
    }

    /// Copies the frame out of shared memory into an image for the layer.
    func draw(_ frame: EmulatorFrame) {
        let count = frame.width * frame.height * 4
        guard let data = CFDataCreate(nil, frame.buffer.bytes.assumingMemoryBound(to: UInt8.self), count),
              let provider = CGDataProvider(data: data),
              let image = CGImage(width: frame.width, height: frame.height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: frame.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return }
        frameSize = CGSize(width: frame.width, height: frame.height)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        screenLayer.contents = image
        CATransaction.commit()
    }

    // MARK: Input

    /// The rectangle the frame is drawn in: aspect-fit, centred.
    private var screenRect: CGRect {
        guard let size = frameSize, size.width > 0, size.height > 0 else { return bounds }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let w = size.width * scale, h = size.height * scale
        return CGRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
    }

    private func devicePoint(_ event: NSEvent) -> (Int, Int)? {
        guard let display = model.displaySize else { return nil }
        let p = convert(event.locationInWindow, from: nil), r = screenRect
        let x = (p.x - r.minX) / r.width, y = (p.y - r.minY) / r.height
        return (Int((min(max(x, 0), 1) * (display.width - 1)).rounded()), Int((min(max(y, 0), 1) * (display.height - 1)).rounded()))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if let (x, y) = devicePoint(event) { model.connection?.touch(x: x, y: y, down: true) }
    }

    override func mouseDragged(with event: NSEvent) {
        if let (x, y) = devicePoint(event) { model.connection?.touch(x: x, y: y, down: true) }
    }

    override func mouseUp(with event: NSEvent) {
        if let (x, y) = devicePoint(event) { model.connection?.touch(x: x, y: y, down: false) }
    }

    override func scrollWheel(with event: NSEvent) {
        // The emulator counts 120 per wheel click; a trackpad's deltas are points, so they are scaled
        // and the fractions carried over to the next event.
        let factor: CGFloat = event.hasPreciseScrollingDeltas ? 6 : 120
        scrollRemainder.x += event.scrollingDeltaX * factor
        scrollRemainder.y += event.scrollingDeltaY * factor
        let dx = Int(scrollRemainder.x), dy = Int(scrollRemainder.y)
        guard dx != 0 || dy != 0 else { return }
        scrollRemainder.x -= CGFloat(dx); scrollRemainder.y -= CGFloat(dy)
        model.connection?.wheel(dx: dx, dy: dy)
    }

    override func keyDown(with event: NSEvent) { model.connection?.key(macKeyCode: event.keyCode, down: true) }
    override func keyUp(with event: NSEvent) { model.connection?.key(macKeyCode: event.keyCode, down: false) }

    override func flagsChanged(with event: NSEvent) {
        let flag: NSEvent.ModifierFlags? = switch event.keyCode {
        case 56, 60: .shift
        case 59, 62: .control
        case 58, 61: .option
        default: nil
        }
        guard let flag else { return }
        model.connection?.key(macKeyCode: event.keyCode, down: event.modifierFlags.contains(flag))
    }
}

private struct DeviceScreen: NSViewRepresentable {
    let model: DeviceScreenModel
    func makeNSView(context: Context) -> DeviceScreenNSView { DeviceScreenNSView(model: model) }
    func updateNSView(_ view: DeviceScreenNSView, context: Context) {}
}

/// The Device pane: the screen, and Android's three navigation buttons under it.
struct DevicePane: View {
    let model: DeviceScreenModel

    var body: some View {
        VStack(spacing: 0) {
            switch model.status {
            case .connecting, .live:
                DeviceScreen(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
            case .notRunning:
                ContentUnavailableView("\(model.name) is not running", systemImage: "candybarphone",
                                       description: Text("Boot it from a run configuration or Android Studio's Device Manager, and it appears here."))
            case .failed(let message):
                ContentUnavailableView("Could not reach \(model.name)", systemImage: "exclamationmark.triangle",
                                       description: Text(message))
            }
            Divider()
            HStack(spacing: 28) {
                navButton("chevron.backward", "Back", key: "GoBack")
                navButton("circle", "Home", key: "GoHome")
                navButton("square", "Recent Apps", key: "AppSwitch")
            }
            .frame(maxWidth: .infinity)
            .frame(height: 32)
            .disabled(model.status != .live)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: EmulatorDirectory.shared.emulator(model.avdId)) { _, emulator in
            if emulator != nil { model.retry() }
        }
    }

    private func navButton(_ symbol: String, _ label: String, key: String) -> some View {
        Button { model.press(key) } label: {
            Image(systemName: symbol).font(.system(size: 12, weight: .medium)).frame(width: 36, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(label)
        .accessibilityLabel(label)
    }
}
