import Testing
@testable import AndroidEmulator

@Suite struct RunningEmulatorTests {
    @Test func parsesADiscoveryFile() throws {
        let ini = """
        emulator.build=15507667
        avd.id=campfire-shots-phone
        port.serial=5558
        port.adb=5559
        avd.name=campfire shots phone
        grpc.token=abc123=
        grpc.port=8558
        """
        let emulator = try #require(RunningEmulator(ini: ini, pid: 42))
        #expect(emulator.avdId == "campfire-shots-phone")
        #expect(emulator.name == "campfire shots phone")
        #expect(emulator.serial == "emulator-5558")
        #expect(emulator.grpcPort == 8558)
        // A token is base64, so only the first `=` splits the line.
        #expect(emulator.token == "abc123=")
    }

    @Test func namesAnAVDWithoutADisplayNameFromItsId() throws {
        let emulator = try #require(RunningEmulator(ini: "avd.id=Pixel_10_Pro_XL\ngrpc.port=8554", pid: 1))
        #expect(emulator.name == "Pixel 10 Pro XL")
        #expect(emulator.token == nil)
    }

    @Test func rejectsAFileWithoutAGRPCPort() {
        #expect(RunningEmulator(ini: "avd.id=x\nport.serial=5554", pid: 1) == nil)
    }
}
