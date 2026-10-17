import AppKit
import Observation
import os
import SwiftUI
import AndroidEmulator
import ClinicCore

// An Android emulator drawn in a workspace pane the way Android Studio's Running Devices panel draws it
// (docs/Research/Embedded Android Emulator.md): the emulator's own window hidden, its screen streamed
// over gRPC into shared memory, the mouse and keyboard sent back as touches and keys, and Studio's
// device controls in a toolbar over the screen. Each pane holds its own connection, so any number of
// devices can be open side by side, in either area.

/// This Mac's emulators, for the `+` menu, the empty panel, the device capsule and each Device pane:
/// every AVD, which are running, and the starts and stops Clinic asked for. The running list is one
/// directory listing, rescanned every two seconds (every second while a start or stop is pending);
/// the AVDs are `emulator -list-avds`, every 30 seconds.
@MainActor
@Observable
final class EmulatorDirectory {
    static let shared = EmulatorDirectory()

    /// How an AVD that was running stopped, kept while it stays stopped.
    enum Ending: Equatable {
        /// Shut down: from its pane, Android Studio, or `adb emu kill`.
        case stopped(Date)
        /// Exited without shutting down, which leaves its discovery file behind, or failed to start.
        case quit(Date)
    }

    private(set) var running: [RunningEmulator] = []
    /// Every AVD by id, running or not.
    private(set) var avds: [String] = []
    /// Starts Clinic asked for whose emulator has not appeared yet, by AVD id.
    private(set) var starting: [String: Date] = [:]
    /// Stops Clinic asked for whose emulator is still running.
    private(set) var stopping: Set<String> = []
    private(set) var endings: [String: Ending] = [:]
    @ObservationIgnored private var launchers: [String: Process] = [:]
    @ObservationIgnored private var lastAVDScan = Date.distantPast
    @ObservationIgnored private var task: Task<Void, Never>?
    private static let log = Logger(subsystem: "com.r0adkll.clinic", category: "device")

    private init() {
        running = RunningEmulator.scan()
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.scan()
                let busy = !self.starting.isEmpty || !self.stopping.isEmpty
                try? await Task.sleep(for: .seconds(busy ? 1 : 2))
            }
        }
    }

    /// By a Device pane's id, `avd:<id>`.
    func emulator(_ deviceId: String) -> RunningEmulator? { running.first { $0.deviceId == deviceId } }

    /// Every AVD as a Device pane id, the running ones first.
    var deviceIds: [String] {
        let live = running.map(\.deviceId)
        return live + avds.map { "avd:" + $0 }.filter { !live.contains($0) }
    }

    /// An AVD's name before it runs, when only its id is known.
    static func name(of deviceId: String) -> String {
        AndroidDevices.displayName(deviceId.hasPrefix("avd:") ? String(deviceId.dropFirst(4)) : deviceId)
    }

    /// Reads the directory now, for a caller that just booted one and cannot wait for the next scan.
    func rescan() { apply(RunningEmulator.scan()) }

    private func scan() async {
        apply(await Task.detached { RunningEmulator.scan() }.value)
        guard Date().timeIntervalSince(lastAVDScan) > 30 else { return }
        lastAVDScan = Date()
        let list = await RunDeviceProbe.avds(projectRoot: nil)
        if list != avds { avds = list }
    }

    private func apply(_ found: [RunningEmulator]) {
        let live = Set(found.map(\.avdId))
        for gone in running where !live.contains(gone.avdId) {
            let asked = stopping.remove(gone.avdId) != nil
            let quit = !asked && gone.leftDiscoveryFile()
            endings[gone.avdId] = quit ? .quit(Date()) : .stopped(Date())
            Self.log.info("\(gone.avdId, privacy: .public) \(quit ? "quit" : "stopped", privacy: .public)")
        }
        for id in live { starting[id] = nil; launchers[id] = nil; endings[id] = nil }
        for (id, since) in starting {
            // The launcher stays up while its emulator runs, so one that exited with an error failed.
            if let launcher = launchers[id], !launcher.isRunning, launcher.terminationStatus != 0 {
                starting[id] = nil; launchers[id] = nil; endings[id] = .quit(Date())
            } else if Date().timeIntervalSince(since) > 240 {
                starting[id] = nil; launchers[id] = nil
            }
        }
        if found != running { running = found }
    }

    /// Starts an AVD, with its window hidden unless `embedded` is false; it outlives Clinic, as Android
    /// Studio's do. Throws when the emulator cannot be launched at all.
    func start(_ deviceId: String, coldBoot: Bool = false, wipeData: Bool = false, embedded: Bool = true) throws {
        let avd = deviceId.hasPrefix("avd:") ? String(deviceId.dropFirst(4)) : deviceId
        guard emulator("avd:" + avd) == nil, starting[avd] == nil else { return }
        launchers[avd] = try RunDeviceProbe.startEmulator(avd: avd, projectRoot: nil, embedded: embedded,
                                                          coldBoot: coldBoot, wipeData: wipeData)
        starting[avd] = Date()
        endings[avd] = nil
        Self.log.info("starting \(avd, privacy: .public)\(coldBoot ? " cold" : "")\(wipeData ? " wiped" : "")")
    }

    /// Shuts an emulator down as its own window's close button would, over `connection` when the caller
    /// has one. One that has not gone after 20 seconds, or cannot be reached, is killed through adb.
    func stop(_ emulator: RunningEmulator, using connection: EmulatorConnection? = nil) {
        guard !stopping.contains(emulator.avdId) else { return }
        stopping.insert(emulator.avdId)
        Task {
            do {
                if let connection {
                    try await connection.shutDown()
                } else {
                    let own = try EmulatorConnection(emulator)
                    defer { own.close() }
                    try await own.shutDown()
                }
                try await Task.sleep(for: .seconds(20))
            } catch {
                Self.log.error("could not shut down \(emulator.avdId, privacy: .public): \(error, privacy: .public)")
            }
            guard running.contains(where: { $0.pid == emulator.pid }) else { return }
            _ = await DeviceScreenModel.adb(emulator, ["emu", "kill"])
        }
    }
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
    var name: String { emulator?.name ?? EmulatorDirectory.name(of: deviceId) }
    var avdId: String { String(deviceId.dropFirst(4)) }
    /// Stop Emulator was chosen in this pane, so the pane closes once the emulator has gone.
    private(set) var closesWhenStopped = false

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
        guard let emulator else { return }
        closesWhenStopped = true
        EmulatorDirectory.shared.stop(emulator, using: connection)
    }

    /// Starts the AVD again from the pane's *off* or *quit* state; the pane reconnects when it appears.
    func start(coldBoot: Bool = false) {
        do {
            try EmulatorDirectory.shared.start(deviceId, coldBoot: coldBoot)
        } catch {
            say("Could not start \(name): \(error.localizedDescription)")
        }
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

    static func adb(_ emulator: RunningEmulator, _ arguments: [String]) async -> String? {
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
    @Environment(TabStore.self) private var tabs
    let model: DeviceScreenModel
    private var directory: EmulatorDirectory { .shared }

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
                status
                if let notice = model.notice { NoticeCapsule(notice: notice).padding(.bottom, 20) }
            }
            .animation(.easeOut(duration: 0.2), value: model.notice)
        }
        .background(Color(nsColor: .underPageBackgroundColor))
        .onChange(of: model.emulator) { _, emulator in
            if emulator != nil { model.retry() }
        }
        // Stopped from this pane: the tab goes with the emulator, as a window would.
        .onChange(of: directory.endings[model.avdId]) { _, ending in
            if ending != nil, model.closesWhenStopped { tabs.closeDevicePane(model) }
        }
    }

    /// What draws over the screen: nothing while it is live; otherwise starting, shutting down,
    /// connecting, or the emulator being off.
    @ViewBuilder private var status: some View {
        if directory.stopping.contains(model.avdId) {
            ProgressView("Shutting down \(model.name)…").controlSize(.small)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(0.35))
        } else if model.emulator != nil {
            switch model.status {
            case .live:
                EmptyView()
            case .connecting, .notRunning:
                ProgressView("Connecting to \(model.name)…").controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                ContentUnavailableView("Could not reach \(model.name)", systemImage: "exclamationmark.triangle",
                                       description: Text("\(message)\nTrying again…"))
                    .background(Color(nsColor: .underPageBackgroundColor))
            }
        } else if directory.starting[model.avdId] != nil {
            ProgressView("Starting \(model.name)…").controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .underPageBackgroundColor))
        } else {
            DeviceOffView(name: model.name, ending: directory.endings[model.avdId],
                          start: { model.start() }, coldBoot: { model.start(coldBoot: true) },
                          close: { tabs.closeDevicePane(model) })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .underPageBackgroundColor))
        }
    }
}

/// A Device pane whose emulator is not running: stopped (here or elsewhere), never started, or quit.
private struct DeviceOffView: View {
    let name: String
    let ending: EmulatorDirectory.Ending?
    let start: () -> Void
    let coldBoot: () -> Void
    let close: () -> Void

    var body: some View {
        if case .quit = ending {
            ContentUnavailableView {
                Label("\(name) quit", systemImage: "exclamationmark.triangle")
            } description: {
                Text("The emulator exited without being stopped.")
            } actions: {
                Button("Start Again", action: start).buttonStyle(.borderedProminent)
                Button("Cold Boot", action: coldBoot)
            }
        } else {
            ContentUnavailableView {
                Label("\(name) is off", systemImage: "candybarphone")
            } description: {
                if case .stopped(let at) = ending {
                    Text("Stopped at \(at.formatted(date: .omitted, time: .shortened)).")
                } else {
                    Text("Start it here, or from a run or Android Studio, and it shows in this tab.")
                }
            } actions: {
                Button("Start", action: start).buttonStyle(.borderedProminent)
                Button("Close Tab", action: close)
            }
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

/// The `+` menu's devices (ADR-226): every AVD, running or not. Choosing one that is not running starts
/// it with its window hidden and opens its tab, which shows it starting. *More Devices* starts one cold,
/// or wiped back to a factory state after asking.
struct DeviceMenuSection: View {
    @Environment(TabStore.self) private var tabs
    let deviceIds: [String]
    let tab: Tab
    let area: Tab.Area

    var body: some View {
        let directory = EmulatorDirectory.shared
        let off = deviceIds.filter { directory.emulator($0) == nil && directory.starting[String($0.dropFirst(4))] == nil }
        Section("Devices") {
            ForEach(deviceIds, id: \.self) { id in
                Button { tabs.openDevice(id, in: tab, area: area) } label: {
                    Text(tabs.paneTitle(.device(id), in: tab))
                    Text(subtitle(id))
                    Image(systemName: "candybarphone")
                }
            }
            if !off.isEmpty {
                Menu("More Devices") {
                    Section("Cold Boot") {
                        ForEach(off, id: \.self) { id in
                            Button(EmulatorDirectory.name(of: id)) { tabs.openDevice(id, in: tab, area: area, coldBoot: true) }
                        }
                    }
                    Section("Wipe Data") {
                        ForEach(off, id: \.self) { id in
                            Button(EmulatorDirectory.name(of: id) + "…") {
                                if confirmWipeData(EmulatorDirectory.name(of: id)) { tabs.openDevice(id, in: tab, area: area, wipeData: true) }
                            }
                        }
                    }
                }
            }
        }
    }

    private func subtitle(_ id: String) -> String {
        let directory = EmulatorDirectory.shared
        if let emulator = directory.emulator(id) { return tab.isOpen(.device(id)) ? "Open · \(emulator.serial)" : "Running · \(emulator.serial)" }
        if directory.starting[String(id.dropFirst(4))] != nil { return "Starting…" }
        return "Not running · starts it"
    }
}

/// Wiping an AVD's data cannot be undone, so it is asked first, as Android Studio's Device Manager asks.
@MainActor
func confirmWipeData(_ name: String) -> Bool {
    let alert = NSAlert()
    alert.messageText = "Wipe \(name)'s data?"
    alert.informativeText = "Everything on the emulator is erased: apps, accounts, files and settings. It then starts as a new device."
    alert.alertStyle = .warning
    alert.addButton(withTitle: "Wipe Data")
    alert.addButton(withTitle: "Cancel")
    alert.buttons.first?.hasDestructiveAction = true
    return alert.runModal() == .alertFirstButtonReturn
}
