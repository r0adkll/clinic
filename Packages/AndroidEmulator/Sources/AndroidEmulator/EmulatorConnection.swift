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

    /// The display's size in device pixels, which touch coordinates are given in.
    public func displaySize() async throws -> (width: Int, height: Int) {
        let status = try await controller.getStatus(Google_Protobuf_Empty(), metadata: metadata)
        let config = Dictionary(status.hardwareConfig.entry.map { ($0.key, $0.value) }, uniquingKeysWith: { a, _ in a })
        guard let width = config["hw.lcd.width"].flatMap(Int.init), let height = config["hw.lcd.height"].flatMap(Int.init) else {
            throw EmulatorError("\(emulator.name) did not report its display size.")
        }
        return (width, height)
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
                            continuation.yield(EmulatorFrame(width: w, height: h, seq: image.seq, buffer: buffer))
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

    /// A scroll, in the emulator's units: 120 per wheel click.
    public func wheel(dx: Int, dy: Int) {
        var wheel = Android_Emulation_Control_WheelEvent()
        wheel.dx = Int32(dx); wheel.dy = Int32(dy)
        var event = EmulatorInputEvent()
        event.wheelEvent = wheel
        send(event)
    }
}

/// One screen frame: its size and the shared file holding its pixels, RGBA, rows packed.
public struct EmulatorFrame: Sendable {
    public let width: Int
    public let height: Int
    public let seq: UInt32
    public let buffer: SharedFrameBuffer
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
