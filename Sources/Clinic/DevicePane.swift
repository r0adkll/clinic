import AppKit
import Observation
import os
import SwiftUI
import AndroidEmulator

// An Android emulator drawn in a workspace pane the way Android Studio's Running Devices panel draws it
// (docs/Research/Embedded Android Emulator.md): the emulator's own window hidden, its screen streamed
// over gRPC into shared memory, the mouse and keyboard sent back as touches and keys, and Studio's
// device controls in a toolbar over the screen. Each pane holds its own connection, so any number of
// devices can be open side by side, in either area.

/// The emulators running now, for the `+` menu and the empty panel. Rescanned every two seconds; a scan
/// is one directory listing.
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

    /// By a Device pane's id, `avd:<id>`.
    func emulator(_ deviceId: String) -> RunningEmulator? { running.first { $0.deviceId == deviceId } }

    /// Reads the directory now, for a caller that just booted one and cannot wait for the next scan.
    func rescan() { running = RunningEmulator.scan() }
}

/// One Device pane's connection to its emulator. Long-lived on the pane, so moving the pane between
/// areas keeps the connection; the screen streams only while the pane is on screen.
@MainActor
@Observable
final class DeviceScreenModel {
    enum Status: Equatable { case connecting, live, notRunning, failed(String) }

    /// Something the pane did that the reader should hear about: a capture saved, or a control failing.
    struct Notice: Equatable { let text: String; var file: URL? }

    let deviceId: String
    private(set) var status: Status = .connecting
    private(set) var hardware: EmulatorHardware?
    /// How the device is turned, from the newest frame.
    private(set) var quarterTurns = 0
    private(set) var recording: (file: URL, scratch: URL, since: Date)?
    private(set) var notice: Notice?
    private(set) var snapshots: [EmulatorSnapshot] = []
    @ObservationIgnored private(set) var connection: EmulatorConnection?
    @ObservationIgnored private var stream: Task<Void, Never>?
    @ObservationIgnored private var streamBox: (Int, Int)?
    @ObservationIgnored private var restart: Task<Void, Never>?
    @ObservationIgnored private var connecting: Task<Bool, Never>?
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    /// The size the screen view last asked for; nil while it is off screen.
    @ObservationIgnored private var wantedPixels: CGSize?
    private static let log = Logger(subsystem: "com.r0adkll.clinic", category: "device")
    @ObservationIgnored private var noticeTimer: Task<Void, Never>?
    @ObservationIgnored weak var screen: DeviceScreenNSView?

    init(deviceId: String) { self.deviceId = deviceId }

    var emulator: RunningEmulator? { EmulatorDirectory.shared.emulator(deviceId) }
    var name: String { emulator?.name ?? String(deviceId.dropFirst(4)).replacingOccurrences(of: "_", with: " ") }

    // MARK: Streaming

    /// Streams frames that fit `pixels` (the view's size in backing pixels) while the screen is on
    /// screen. The emulator scales each frame into the box it is asked for, keeping the aspect, so the
    /// box is all it needs; a new box restarts the stream once the size has settled, rather than on
    /// every step of a resize. Connecting is not part of that debounce: a resize arriving mid-connect
    /// must not cancel it, or the pane is left with no connection and nothing asking for one.
    func show(at pixels: CGSize) {
        guard pixels.width >= 16, pixels.height >= 16 else { return }
        wantedPixels = pixels
        restart?.cancel()
        restart = Task { [weak self] in
            guard let self, await self.connect() else { return }
            if self.stream != nil { try? await Task.sleep(for: .milliseconds(150)) }
            guard !Task.isCancelled, let pixels = self.wantedPixels else { return }
            self.startStream(pixels)
        }
    }

    /// Off screen: the stream stops, the connection stays for when the pane comes back.
    func hide() {
        wantedPixels = nil
        restart?.cancel(); restart = nil
        retryTask?.cancel(); retryTask = nil
        stream?.cancel(); stream = nil; streamBox = nil
    }

    /// The pane closed.
    func stop() {
        hide()
        if recording != nil { toggleRecording() }
        dropConnection()
    }

    /// The emulator is (back) in the running list: reconnect now rather than at the next retry.
    func retry() {
        guard status != .live, let pixels = wantedPixels else { return }
        retryTask?.cancel(); retryTask = nil
        show(at: pixels)
    }

    /// One connection attempt at a time, whoever asks; true once connected.
    private func connect() async -> Bool {
        if connection != nil { return true }
        if let connecting { return await connecting.value }
        // Unstructured on purpose, so cancelling the caller (a newer resize) does not cancel the RPCs.
        let attempt = Task { await self.openConnection() }
        connecting = attempt
        let connected = await attempt.value
        connecting = nil
        if !connected { scheduleRetry() }
        return connected
    }

    private func openConnection() async -> Bool {
        if status != .live { status = .connecting }
        guard let emulator = emulator ?? RunningEmulator.scan().first(where: { $0.deviceId == deviceId }) else {
            status = .notRunning
            return false
        }
        do {
            let connection = try EmulatorConnection(emulator)
            do {
                hardware = try await connection.hardware()
            } catch {
                connection.close()
                throw error
            }
            self.connection = connection
            status = .live
            Self.log.info("connected to \(emulator.avdId, privacy: .public) on \(emulator.grpcPort)")
            return true
        } catch {
            Self.log.error("could not connect to \(emulator.avdId, privacy: .public): \(error, privacy: .public)")
            status = .failed("\(error)")
            return false
        }
    }

    private func dropConnection() {
        connection?.close(); connection = nil
    }

    /// While the pane is on screen and its emulator is listed, keeps trying: a connection refused while
    /// an emulator boots, or a stream cut by a snapshot load, comes back on its own.
    private func scheduleRetry() {
        guard wantedPixels != nil, retryTask == nil else { return }
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled, let self else { return }
            self.retryTask = nil
            guard let pixels = self.wantedPixels, self.emulator != nil else { return }
            self.show(at: pixels)
        }
    }

    private func startStream(_ pixels: CGSize) {
        guard let connection, let hardware else { return }
        // Never more than the display has: the emulator would only scale back down.
        let longest = CGFloat(max(hardware.width, hardware.height))
        let box = (Int(min(pixels.width, longest)), Int(min(pixels.height, longest)))
        if stream != nil, let current = streamBox, current == box { return }
        stream?.cancel()
        streamBox = box
        stream = Task { [weak self] in
            var failure: (any Error)?
            do {
                for try await frame in connection.frames(width: box.0, height: box.1) {
                    guard let self else { return }
                    if frame.quarterTurns != self.quarterTurns { self.quarterTurns = frame.quarterTurns }
                    self.screen?.draw(frame, geometry: ScreenGeometry(displayWidth: hardware.width, displayHeight: hardware.height,
                                                                      quarterTurns: frame.quarterTurns, folded: frame.folded))
                }
            } catch {
                failure = error
            }
            // Cancelled by hide() or a newer stream: nothing to repair.
            guard !Task.isCancelled, let self else { return }
            // Otherwise the stream ended under us, with an error or without one. Either way the
            // connection is suspect: drop it, and reconnect while the pane is still on screen.
            Self.log.error("stream from \(self.deviceId, privacy: .public) ended: \(String(describing: failure), privacy: .public)")
            self.stream = nil; self.streamBox = nil
            if self.connection === connection { self.dropConnection() }
            self.status = self.emulator == nil ? .notRunning : .connecting
            self.screen?.clear()
            self.scheduleRetry()
        }
    }

    // MARK: Controls

    func press(_ key: String) { connection?.press(key) }
    func holdPower() { connection?.hold("Power", for: 1.5) }

    /// Turns the device a quarter turn left (counter-clockwise) or right.
    func rotate(by turns: Int) {
        perform("Could not rotate \(name)") { try await $0.rotate(toQuarterTurns: self.quarterTurns + turns) }
    }

    func setPosture(_ posture: EmulatorPosture) {
        perform("Could not fold \(name)") { try await $0.setPosture(posture) }
    }

    func showExtendedControls() {
        perform("Could not open Extended Controls") { try await $0.showExtendedControls() }
    }

    func shutDown() {
        perform("Could not stop \(name)") { try await $0.shutDown() }
    }

    func takeScreenshot() {
        perform("Could not take a screenshot") { connection in
            let png = try await connection.screenshotPNG()
            let file = Self.captureFile(for: self.name, kind: "Screenshot", ext: "png")
            try png.write(to: file)
            self.say("Screenshot saved to \(Self.folderName(file))", file: file)
        }
    }

    /// Starts or stops a screen recording. The emulator records it itself, through its console's
    /// `screenrecord` (there is no gRPC call), as Android Studio does; three minutes at most.
    func toggleRecording() {
        guard let emulator else { return }
        if let recording {
            self.recording = nil
            Task {
                _ = await Self.adb(emulator, ["emu", "screenrecord", "stop"])
                // The emulator finishes writing after it answers.
                try? await Task.sleep(for: .milliseconds(800))
                do {
                    try FileManager.default.moveItem(at: recording.scratch, to: recording.file)
                    say("Recording saved to \(Self.folderName(recording.file))", file: recording.file)
                } catch {
                    say("Could not save the recording: \(error.localizedDescription)")
                }
            }
            return
        }
        // The console splits its command line on spaces, so the emulator writes to a path with none and
        // the file moves to its real name once it is finished.
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("clinic-recording-\(UUID().uuidString).webm")
        recording = (Self.captureFile(for: name, kind: "Screen Recording", ext: "webm"), scratch, Date())
        Task {
            let out = await Self.adb(emulator, ["emu", "screenrecord", "start", "--time-limit", "180", scratch.path])
            if !(out?.contains("OK") ?? false) { recording = nil; say("Could not start recording: \(out ?? "adb failed")") }
        }
    }

    func refreshSnapshots() {
        perform("Could not list snapshots") { self.snapshots = try await $0.listSnapshots() }
    }

    func saveSnapshot() {
        let id = "clinic_" + Self.stamp.string(from: Date()).replacingOccurrences(of: " ", with: "_")
        perform("Could not save a snapshot") { connection in
            try await connection.saveSnapshot(named: id)
            self.say("Saved snapshot \(id)")
            self.snapshots = try await connection.listSnapshots()
        }
    }

    func loadSnapshot(_ snapshot: EmulatorSnapshot) {
        perform("Could not load \(snapshot.name)") { connection in
            try await connection.loadSnapshot(snapshot.id)
            self.say("Loaded snapshot \(snapshot.name)")
        }
    }

    private func perform(_ failure: String, _ action: @escaping @MainActor (EmulatorConnection) async throws -> Void) {
        guard let connection else { return }
        Task {
            do { try await action(connection) } catch { say("\(failure): \(error)") }
        }
    }

    func say(_ text: String, file: URL? = nil) {
        notice = Notice(text: text, file: file)
        noticeTimer?.cancel()
        noticeTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(file == nil ? 4 : 6))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    // MARK: Files

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return f
    }()

    /// Where macOS puts screenshots (Screenshot.app's choice, else the Desktop), named the way it names them.
    private static func captureFile(for device: String, kind: String, ext: String) -> URL {
        let chosen = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location")
            .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
        let folder = chosen.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
        return folder.appendingPathComponent("\(device) \(kind) \(stamp.string(from: Date())).\(ext)")
    }

    private static func folderName(_ file: URL) -> String {
        FileManager.default.displayName(atPath: file.deletingLastPathComponent().path)
    }

    private static func adb(_ emulator: RunningEmulator, _ arguments: [String]) async -> String? {
        await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: emulator.adb.hasPrefix("/") ? emulator.adb : "/usr/bin/env")
            p.arguments = (emulator.adb.hasPrefix("/") ? [] : ["adb"]) + ["-s", emulator.serial] + arguments
            let pipe = Pipe()
            p.standardOutput = pipe; p.standardError = pipe
            do { try p.run() } catch { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
        }.value
    }
}

/// The emulator's screen: frames drawn aspect-fit into a layer; clicks and drags become one finger,
/// the scroll wheel scrolls, and keys typed while it has the keyboard go to the device — except ⌘
/// chords, which reach Clinic's menus first.
final class DeviceScreenNSView: NSView {
    private(set) var model: DeviceScreenModel
    private let screenLayer = CALayer()
    /// The size of the image last drawn, and how its pixels map to the device.
    private var imageSize: CGSize?
    private var geometry: ScreenGeometry?
    private var scrollRemainder = CGPoint.zero

    init(model: DeviceScreenModel) {
        self.model = model
        super.init(frame: .zero)
        wantsLayer = true
        screenLayer.contentsGravity = .resizeAspect
        screenLayer.magnificationFilter = .linear
        screenLayer.minificationFilter = .trilinear
        layer?.addSublayer(screenLayer)
        model.screen = self
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// Shows another pane's device: the old one stops streaming into this view, and the new one starts.
    func attach(_ newModel: DeviceScreenModel) {
        guard newModel !== model else { return }
        if model.screen === self { model.hide() }
        model = newModel
        model.screen = self
        clear()
        requestFrames()
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // A view SwiftUI replaced can leave its window after the new one asked for frames; only the
        // model's current view may stop the stream.
        if window == nil {
            if model.screen === self { model.hide() }
        } else {
            model.screen = self
            requestFrames()
        }
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

    /// Copies the frame out of shared memory into an image for the layer, cropped to a folded
    /// foldable's active screen.
    func draw(_ frame: EmulatorFrame, geometry: ScreenGeometry) {
        let count = frame.width * frame.height * 4
        guard let data = CFDataCreate(nil, frame.buffer.bytes.assumingMemoryBound(to: UInt8.self), count),
              let provider = CGDataProvider(data: data),
              var image = CGImage(width: frame.width, height: frame.height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: frame.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return }
        let visible = geometry.crop(frameWidth: frame.width, frameHeight: frame.height)
        if visible.width < 1 || visible.height < 1 {
            let w = Double(frame.width), h = Double(frame.height)
            let crop = CGRect(x: visible.x * w, y: visible.y * h, width: visible.width * w, height: visible.height * h).integral
            image = image.cropping(to: crop) ?? image
        }
        imageSize = CGSize(width: image.width, height: image.height)
        self.geometry = geometry
        CATransaction.begin(); CATransaction.setDisableActions(true)
        screenLayer.contents = image
        CATransaction.commit()
    }

    /// Blank until the next frame, so a dropped connection never leaves a stale screen that looks live.
    func clear() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        screenLayer.contents = nil
        CATransaction.commit()
        imageSize = nil; geometry = nil
    }

    // MARK: Input

    /// The rectangle the image is drawn in: aspect-fit, centred.
    private var screenRect: CGRect {
        guard let size = imageSize, size.width > 0, size.height > 0 else { return bounds }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let w = size.width * scale, h = size.height * scale
        return CGRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
    }

    private func devicePoint(_ event: NSEvent) -> (x: Int, y: Int)? {
        guard let geometry else { return nil }
        let p = convert(event.locationInWindow, from: nil), r = screenRect
        return geometry.devicePoint(u: (p.x - r.minX) / r.width, v: (p.y - r.minY) / r.height)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if let p = devicePoint(event) { model.connection?.touch(x: p.x, y: p.y, down: true) }
    }

    override func mouseDragged(with event: NSEvent) {
        if let p = devicePoint(event) { model.connection?.touch(x: p.x, y: p.y, down: true) }
    }

    override func mouseUp(with event: NSEvent) {
        if let p = devicePoint(event) { model.connection?.touch(x: p.x, y: p.y, down: false) }
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
    /// SwiftUI hands a view made for one pane to the next pane shown in the same place (a device tab
    /// closed and another opened, or two device tabs switched), so the view is moved to this model.
    func updateNSView(_ view: DeviceScreenNSView, context: Context) { view.attach(model) }
}

/// The Device pane: Android Studio's device toolbar over the screen.
struct DevicePane: View {
    let model: DeviceScreenModel

    var body: some View {
        VStack(spacing: 0) {
            DeviceToolbar(model: model)
            Divider()
            ZStack(alignment: .bottom) {
                // The screen stays mounted whatever the status, so it keeps its size and the model
                // keeps reconnecting; the status draws over it.
                DeviceScreen(model: model)
                    // One screen view per pane, rather than SwiftUI's one per place (see `attach`).
                    .id(ObjectIdentifier(model))
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                switch model.status {
                case .live:
                    EmptyView()
                case .connecting:
                    ProgressView("Connecting to \(model.name)…").controlSize(.small)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .notRunning:
                    ContentUnavailableView("\(model.name) is not running", systemImage: "candybarphone",
                                           description: Text("Start it from a run configuration or Android Studio's Device Manager, and it shows here."))
                        .background(Color(nsColor: .underPageBackgroundColor))
                case .failed(let message):
                    ContentUnavailableView("Could not reach \(model.name)", systemImage: "exclamationmark.triangle",
                                           description: Text("\(message)\nTrying again…"))
                        .background(Color(nsColor: .underPageBackgroundColor))
                }
                if let notice = model.notice { NoticeCapsule(notice: notice).padding(.bottom, 20) }
            }
            .animation(.easeOut(duration: 0.2), value: model.notice)
        }
        .background(Color(nsColor: .underPageBackgroundColor))
        .onChange(of: model.emulator) { _, emulator in
            if emulator != nil { model.retry() }
        }
    }
}

/// A capture saved or a control failing, over the bottom of the screen for a few seconds.
private struct NoticeCapsule: View {
    let notice: DeviceScreenModel.Notice

    var body: some View {
        HStack(spacing: 10) {
            Text(notice.text).font(.system(size: 12)).lineLimit(2)
            if let file = notice.file {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                    .buttonStyle(.link).font(.system(size: 12, weight: .medium))
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
        .padding(.horizontal, 16)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

/// Android Studio's Running Devices toolbar: power and volume, rotation (and posture for a foldable),
/// back, home and overview, then screenshot, recording and snapshots. The groups that do not fit the
/// pane's width fold into the trailing ⋯ menu, rightmost first, so a narrow panel keeps navigation.
private struct DeviceToolbar: View {
    let model: DeviceScreenModel

    /// The groups, in the order they give way: capture first, navigation never.
    private enum Group: CaseIterable { case hardware, orientation, navigation, capture }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            bar(showing: [.hardware, .orientation, .navigation, .capture])
            bar(showing: [.hardware, .orientation, .navigation])
            bar(showing: [.orientation, .navigation])
            bar(showing: [.navigation])
        }
        .frame(height: 34)
        .frame(maxWidth: .infinity)
        .disabled(model.status != .live)
    }

    private func bar(showing groups: [Group]) -> some View {
        HStack(spacing: 2) {
            ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
                if index > 0 { Divider().frame(height: 16).padding(.horizontal, 5) }
                buttons(group)
            }
            Divider().frame(height: 16).padding(.horizontal, 5)
            moreMenu(folded: Group.allCases.filter { !groups.contains($0) })
        }
        .padding(.horizontal, 8)
        .fixedSize()
    }

    @ViewBuilder
    private func buttons(_ group: Group) -> some View {
        switch group {
        case .hardware:
            DeviceControlButton("power", "Power") { model.press("Power") }
            DeviceControlButton("speaker.plus", "Volume Up") { model.press("AudioVolumeUp") }
            DeviceControlButton("speaker.minus", "Volume Down") { model.press("AudioVolumeDown") }
        case .orientation:
            DeviceControlButton("rotate.left", "Rotate Left") { model.rotate(by: 1) }
            DeviceControlButton("rotate.right", "Rotate Right") { model.rotate(by: -1) }
            if let hardware = model.hardware, hardware.isFoldable {
                Menu {
                    postureItems(hardware)
                } label: {
                    Image(systemName: "book").font(.system(size: 12))
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .frame(width: 28, height: 24).help("Fold").accessibilityLabel("Fold")
            }
        case .navigation:
            DeviceControlButton("chevron.backward", "Back") { model.press("GoBack") }
            DeviceControlButton("circle", "Home") { model.press("GoHome") }
            DeviceControlButton("square", "Overview") { model.press("AppSwitch") }
        case .capture:
            DeviceControlButton("camera", "Take Screenshot") { model.takeScreenshot() }
            RecordButton(model: model)
            Menu {
                snapshotItems
            } label: {
                Image(systemName: "clock.arrow.circlepath").font(.system(size: 12))
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .frame(width: 28, height: 24).help("Snapshots").accessibilityLabel("Snapshots")
            .simultaneousGesture(TapGesture().onEnded { model.refreshSnapshots() })
        }
    }

    @ViewBuilder
    private func postureItems(_ hardware: EmulatorHardware) -> some View {
        ForEach(hardware.postures, id: \.self) { posture in
            Button(posture.name) { model.setPosture(posture) }
        }
    }

    @ViewBuilder
    private var snapshotItems: some View {
        Button("Take Snapshot") { model.saveSnapshot() }
        if !model.snapshots.isEmpty {
            Divider()
            Section("Load") {
                ForEach(model.snapshots) { snapshot in
                    Button(snapshot.name) { model.loadSnapshot(snapshot) }
                }
            }
        }
    }

    /// The trailing ⋯: whatever did not fit, then what Studio keeps behind its own overflow.
    private func moreMenu(folded: [Group]) -> some View {
        Menu {
            if folded.contains(.hardware) {
                Button("Power") { model.press("Power") }
                Button("Volume Up") { model.press("AudioVolumeUp") }
                Button("Volume Down") { model.press("AudioVolumeDown") }
                Divider()
            }
            if folded.contains(.orientation) {
                Button("Rotate Left") { model.rotate(by: 1) }
                Button("Rotate Right") { model.rotate(by: -1) }
                if let hardware = model.hardware, hardware.isFoldable {
                    Menu("Fold") { postureItems(hardware) }
                }
                Divider()
            }
            if folded.contains(.capture) {
                Button("Take Screenshot") { model.takeScreenshot() }
                Button(model.recording == nil ? "Record Screen" : "Stop Recording") { model.toggleRecording() }
                Menu("Snapshots") { snapshotItems }
                Divider()
            }
            Button("Hold Power") { model.holdPower() }
            Button("Extended Controls…") { model.showExtendedControls() }
            Divider()
            Button("Stop Emulator") { model.shutDown() }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 12))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .frame(width: 28, height: 24).help("More").accessibilityLabel("More")
        .simultaneousGesture(TapGesture().onEnded { if folded.contains(.capture) { model.refreshSnapshots() } })
    }
}

/// Record and stop, showing how long it has been recording while it is.
private struct RecordButton: View {
    let model: DeviceScreenModel

    var body: some View {
        if let recording = model.recording {
            Button { model.toggleRecording() } label: {
                HStack(spacing: 4) {
                    Image(systemName: "stop.circle.fill").foregroundStyle(.red)
                    Text(timerInterval: recording.since...Date.distantFuture, countsDown: false)
                        .monospacedDigit().font(.system(size: 11))
                }
                .padding(.horizontal, 6).frame(height: 24).contentShape(Rectangle())
            }
            .buttonStyle(.plain).help("Stop Recording").accessibilityLabel("Stop Recording")
        } else {
            DeviceControlButton("record.circle", "Record Screen") { model.toggleRecording() }
        }
    }
}

private struct DeviceControlButton: View {
    let symbol: String
    let label: String
    let action: () -> Void
    @State private var hovering = false

    init(_ symbol: String, _ label: String, action: @escaping () -> Void) {
        self.symbol = symbol; self.label = label; self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12))
                .frame(width: 28, height: 24)
                .background(hovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .onHover { hovering = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}
