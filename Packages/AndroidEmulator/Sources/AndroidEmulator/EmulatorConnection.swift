import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import GRPCProtobuf
import SwiftProtobuf

public typealias EmulatorInputEvent = Android_Emulation_Control_InputEvent

/// A gRPC connection to one running emulator: its screen as a stream of frames, and input sent back in
/// order. This is how Android Studio's Running Devices panel draws an emulator whose own window is hidden.
public final class EmulatorConnection: Sendable {
    public let emulator: RunningEmulator
    private let client: GRPCClient<HTTP2ClientTransport.Posix>
    private let controller: Android_Emulation_Control_EmulatorController.Client<HTTP2ClientTransport.Posix>
    private let ui: Android_Emulation_Control_UiController.Client<HTTP2ClientTransport.Posix>
    private let snapshots: Android_Emulation_Control_SnapshotService.Client<HTTP2ClientTransport.Posix>
    private let metadata: Metadata
    /// Every input event goes down one client stream, so a touch's down, moves and up arrive in the
    /// order they happened; separate unary calls could overtake each other.
    private let input: AsyncStream<EmulatorInputEvent>.Continuation
    private let tasks: [Task<Void, Never>]

    public init(_ emulator: RunningEmulator) throws {
        self.emulator = emulator
        let transport = try HTTP2ClientTransport.Posix(
            target: .ipv4(address: "127.0.0.1", port: emulator.grpcPort),
            transportSecurity: .plaintext
        )
        let client = GRPCClient(transport: transport)
        self.client = client
        self.controller = .init(wrapping: client)
        self.ui = .init(wrapping: client)
        self.snapshots = .init(wrapping: client)
        var metadata = Metadata()
        if let token = emulator.token { metadata.addString("Bearer \(token)", forKey: "authorization") }
        self.metadata = metadata

        let (events, continuation) = AsyncStream<EmulatorInputEvent>.makeStream(bufferingPolicy: .unbounded)
        self.input = continuation
        let controller = self.controller
        tasks = [
            Task { try? await client.runConnections() },
            Task {
                _ = try? await controller.streamInputEvent(metadata: metadata, requestProducer: { writer in
                    for await event in events { try await writer.write(event) }
                })
            },
        ]
    }

    deinit { close() }

    public func close() {
        input.finish()
        client.beginGracefulShutdown()
        for task in tasks { task.cancel() }
    }

    // MARK: Screen

    /// The display's size in device pixels — in its natural orientation, which touch coordinates are
    /// always given in, however the device is turned — and the postures a foldable can take.
    public func hardware() async throws -> EmulatorHardware {
        let status = try await controller.getStatus(Google_Protobuf_Empty(), metadata: metadata)
        let config = Dictionary(status.hardwareConfig.entry.map { ($0.key, $0.value) }, uniquingKeysWith: { a, _ in a })
        guard let width = config["hw.lcd.width"].flatMap(Int.init), let height = config["hw.lcd.height"].flatMap(Int.init) else {
            throw EmulatorError("\(emulator.name) did not report its display size.")
        }
        let postures = (config["hw.sensor.posture_list"] ?? "")
            .split(whereSeparator: { $0 == "," || $0 == " " })
            .compactMap { Int($0).flatMap(EmulatorPosture.init(rawValue:)) }
        return EmulatorHardware(width: width, height: height, postures: postures)
    }

    /// The screen, scaled by the emulator to fit `width`×`height` with its aspect kept, as RGBA frames
    /// written into a shared memory file rather than sent over the socket. A frame arrives only when the
    /// screen changed, so an idle device costs nothing.
    ///
    /// Width and height are always sent and the file is exactly the size they need: a request with
    /// neither, and a padded file, killed a headless emulator during the spike (docs/Research).
    public func frames(width: Int, height: Int) -> AsyncThrowingStream<EmulatorFrame, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let buffer = try SharedFrameBuffer(byteCount: width * height * 4)
                    var format = Android_Emulation_Control_ImageFormat()
                    format.format = .rgba8888
                    format.width = UInt32(width)
                    format.height = UInt32(height)
                    format.transport.channel = .mmap
                    format.transport.handle = buffer.url.absoluteString
                    try await controller.streamScreenshot(format, metadata: metadata) { response in
                        for try await image in response.messages {
                            let w = Int(image.format.width), h = Int(image.format.height)
                            guard w > 0, h > 0, w * h * 4 <= buffer.byteCount else { continue }
                            let fold = image.format.foldedDisplay
                            continuation.yield(EmulatorFrame(
                                width: w, height: h, seq: image.seq, buffer: buffer,
                                quarterTurns: image.format.rotation.rotation.rawValue,
                                folded: fold.width > 0 && fold.height > 0
                                    ? EmulatorFrame.Region(x: Int(fold.xOffset), y: Int(fold.yOffset), width: Int(fold.width), height: Int(fold.height))
                                    : nil))
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Input

    public func send(_ event: EmulatorInputEvent) { input.yield(event) }

    /// One finger, in device pixels; `down` false lifts it.
    public func touch(x: Int, y: Int, down: Bool) {
        var touch = Android_Emulation_Control_Touch()
        touch.x = Int32(x); touch.y = Int32(y); touch.identifier = 0; touch.pressure = down ? 1 : 0
        var event = EmulatorInputEvent()
        event.touchEvent.touches = [touch]
        send(event)
    }

    /// A Mac virtual key code (`NSEvent.keyCode`), which the emulator translates to the device's own.
    public func key(macKeyCode: UInt16, down: Bool) {
        var key = Android_Emulation_Control_KeyboardEvent()
        key.codeType = .mac
        key.eventType = down ? .keydown : .keyup
        key.keyCode = Int32(macKeyCode)
        var event = EmulatorInputEvent()
        event.keyEvent = key
        send(event)
    }

    /// A key by its W3C name, pressed and released: `GoBack`, `GoHome`, `AppSwitch`, `Power`.
    public func press(_ name: String) {
        var key = Android_Emulation_Control_KeyboardEvent()
        key.eventType = .keypress
        key.key = name
        var event = EmulatorInputEvent()
        event.keyEvent = key
        send(event)
    }

    /// A key held down for `seconds` and released: a long press of Power opens the power menu.
    public func hold(_ name: String, for seconds: Double) {
        var key = Android_Emulation_Control_KeyboardEvent()
        key.key = name
        key.eventType = .keydown
        var down = EmulatorInputEvent(); down.keyEvent = key
        send(down)
        Task { [input] in
            try? await Task.sleep(for: .seconds(seconds))
            key.eventType = .keyup
            var up = EmulatorInputEvent(); up.keyEvent = key
            input.yield(up)
        }
    }

    /// A scroll, in the emulator's units: 120 per wheel click.
    public func wheel(dx: Int, dy: Int) {
        var wheel = Android_Emulation_Control_WheelEvent()
        wheel.dx = Int32(dx); wheel.dy = Int32(dy)
        var event = EmulatorInputEvent()
        event.wheelEvent = wheel
        send(event)
    }

    // MARK: Device controls

    /// Turns the device to `quarterTurns` × 90° counter-clockwise from its natural orientation, as
    /// tilting a real one would; an app that follows the sensor rotates with it.
    public func rotate(toQuarterTurns quarterTurns: Int) async throws {
        var value = Android_Emulation_Control_PhysicalModelValue()
        value.target = .rotation
        value.value.data = [0, 0, Float(((quarterTurns % 4) + 4) % 4 * 90)]
        _ = try await controller.setPhysicalModel(value, metadata: metadata)
    }

    public func setPosture(_ posture: EmulatorPosture) async throws {
        var value = Android_Emulation_Control_Posture()
        value.value = .init(rawValue: posture.rawValue) ?? .postureUnknown
        _ = try await controller.setPosture(value, metadata: metadata)
    }

    /// The screen at full resolution, as a PNG.
    public func screenshotPNG() async throws -> Data {
        var format = Android_Emulation_Control_ImageFormat()
        format.format = .png
        var options = CallOptions.defaults
        options.maxResponseMessageBytes = 64 << 20
        return try await controller.getScreenshot(format, metadata: metadata, options: options).image
    }

    /// The emulator's own Extended Controls window — location, battery, camera, sensors and the rest —
    /// which it can show even while its main window is hidden.
    public func showExtendedControls() async throws {
        _ = try await ui.showExtendedControls(Android_Emulation_Control_PaneEntry(), metadata: metadata)
    }

    /// Shuts the emulator down, as its own window's close button would.
    public func shutDown() async throws {
        var state = Android_Emulation_Control_VmRunState()
        state.state = .shutdown
        _ = try await controller.setVmState(state, metadata: metadata)
    }

    // MARK: Snapshots

    public func listSnapshots() async throws -> [EmulatorSnapshot] {
        let list = try await snapshots.listSnapshots(Android_Emulation_Control_SnapshotFilter(), metadata: metadata)
        return list.snapshots.map {
            EmulatorSnapshot(id: $0.snapshotID, name: $0.details.logicalName.isEmpty ? $0.snapshotID : $0.details.logicalName,
                             created: Date(timeIntervalSince1970: TimeInterval($0.details.creationTime)))
        }
        .sorted { $0.created > $1.created }
    }

    public func saveSnapshot(named id: String) async throws {
        var package = Android_Emulation_Control_SnapshotPackage(); package.snapshotID = id
        let result = try await snapshots.saveSnapshot(package, metadata: metadata)
        if !result.success { throw EmulatorError(String(decoding: result.err, as: UTF8.self)) }
    }

    public func loadSnapshot(_ id: String) async throws {
        var package = Android_Emulation_Control_SnapshotPackage(); package.snapshotID = id
        let result = try await snapshots.loadSnapshot(package, metadata: metadata)
        if !result.success { throw EmulatorError(String(decoding: result.err, as: UTF8.self)) }
    }
}

/// What a device is: its natural display size and, for a foldable, its postures.
public struct EmulatorHardware: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let postures: [EmulatorPosture]
    public var isFoldable: Bool { !postures.isEmpty }
}

public enum EmulatorPosture: Int, Sendable, CaseIterable {
    case closed = 1, halfOpen, open, flipped, tent

    public var name: String {
        switch self {
        case .closed: "Closed"
        case .halfOpen: "Half Open"
        case .open: "Open"
        case .flipped: "Flipped"
        case .tent: "Tent"
        }
    }
}

public struct EmulatorSnapshot: Sendable, Identifiable, Hashable {
    public let id: String
    public let name: String
    public let created: Date
}

/// One screen frame: its size and the shared file holding its pixels, RGBA, rows packed.
public struct EmulatorFrame: Sendable {
    public struct Region: Sendable, Equatable { public let x, y, width, height: Int }

    public let width: Int
    public let height: Int
    public let seq: UInt32
    public let buffer: SharedFrameBuffer
    /// How far the device is turned: the frame shows its natural screen turned this many quarter turns
    /// counter-clockwise. Touches are still given in the natural orientation, so they are turned back.
    public let quarterTurns: Int
    /// A folded foldable's active screen, in display pixels; nil when unfolded or not a foldable.
    public let folded: Region?
}

/// A file the emulator writes frames into and Clinic maps to read them. Removed when released.
public final class SharedFrameBuffer: @unchecked Sendable {
    public let url: URL
    public let byteCount: Int
    /// The mapped file. The emulator may be writing the next frame while it is read, so a frame can
    /// tear; Android Studio accepts the same.
    public let bytes: UnsafeRawPointer
    private let mapped: UnsafeMutableRawPointer

    init(byteCount: Int) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ClinicEmulatorFrames", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent(UUID().uuidString + ".rgba")
        self.byteCount = byteCount
        let fd = open(url.path, O_RDWR | O_CREAT | O_TRUNC, 0o600)
        guard fd >= 0 else { throw EmulatorError("Could not create the frame file (\(errno)).") }
        defer { Darwin.close(fd) }
        guard ftruncate(fd, off_t(byteCount)) == 0,
              let map = mmap(nil, byteCount, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0), map != MAP_FAILED else {
            throw EmulatorError("Could not map the frame file (\(errno)).")
        }
        mapped = map
        bytes = UnsafeRawPointer(map)
    }

    deinit {
        munmap(mapped, byteCount)
        try? FileManager.default.removeItem(at: url)
    }
}

public struct EmulatorError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}
