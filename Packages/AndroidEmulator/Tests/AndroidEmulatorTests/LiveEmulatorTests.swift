import Foundation
import Testing
@testable import AndroidEmulator

/// Against a real emulator, named by `CLINIC_TEST_AVD` (an AVD id that is running); skipped otherwise.
/// It sends no input, so it is safe against a device someone is using.
@Suite struct LiveEmulatorTests {
    static let avd = ProcessInfo.processInfo.environment["CLINIC_TEST_AVD"]

    @Test(.enabled(if: avd != nil)) func streamsFramesThroughSharedMemory() async throws {
        let emulator = try #require(RunningEmulator.scan().first { $0.avdId == Self.avd })
        let connection = try EmulatorConnection(emulator)
        defer { connection.close() }
        let hardware = try await connection.hardware()
        let size = (width: hardware.width, height: hardware.height)
        #expect(size.width > 0 && size.height > 0)
        var frames = 0
        for try await frame in connection.frames(width: size.width / 2, height: size.height / 2) {
            #expect(frame.width <= size.width / 2 && frame.height <= size.height / 2)
            // Opaque pixels mean the emulator really wrote into the file.
            #expect(frame.buffer.bytes.load(fromByteOffset: 3, as: UInt8.self) == 255)
            frames += 1
            break
        }
        #expect(frames == 1)
    }

    /// Android Studio's emulators write no `grpc.token`, only a key directory, so Clinic must sign in with
    /// its own key. The discovery file is read without its token to force that path.
    @Test(.enabled(if: avd != nil)) func signsInWithItsOwnKeyWhenThereIsNoToken() async throws {
        let directory = RunningEmulator.discoveryDirectory
        let found = try #require(RunningEmulator.scan().first { $0.avdId == Self.avd })
        let ini = try String(contentsOf: directory.appendingPathComponent("pid_\(found.pid).ini"), encoding: .utf8)
            .split(whereSeparator: \.isNewline).filter { !$0.hasPrefix("grpc.token=") }.joined(separator: "\n")
        let emulator = try #require(RunningEmulator(ini: ini, pid: found.pid))
        #expect(emulator.token == nil && emulator.jwksDirectory != nil)
        let connection = try EmulatorConnection(emulator)
        defer { connection.close() }
        let hardware = try await connection.hardware()
        #expect(hardware.width > 0)
    }
}
