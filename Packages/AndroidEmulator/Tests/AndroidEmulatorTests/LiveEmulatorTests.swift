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
        let size = try await connection.displaySize()
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
}
