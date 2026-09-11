import Foundation
import Testing
@testable import ClinicCore

@Suite struct RunDeviceTests {
    @Test func parsesADBDevicesIgnoringHeaderAndDaemonChatter() {
        let out = """
        * daemon not running; starting now at tcp:5037
        * daemon started successfully
        List of devices attached
        emulator-5554          device product:sdk_gphone64_arm64 model:sdk_gphone64_arm64 device:emu64a transport_id:1
        1A2B3C4D5E             device usb:1-1 product:husky model:Pixel_8_Pro device:husky transport_id:2
        ZX1G22               unauthorized usb:1-2 transport_id:3

        """
        let c = AndroidDevices.parseDevices(out)
        #expect(c.map(\.serial) == ["emulator-5554", "1A2B3C4D5E", "ZX1G22"])
        #expect(c[1].model == "Pixel_8_Pro")
        #expect(c[2].state == "unauthorized")
        #expect(AndroidDevices.parseDevices("List of devices attached\n\n").isEmpty)
    }

    @Test func parsesAVDListAndAVDName() {
        let list = "INFO    | Storing crashdata in: /tmp/android/emu-crash.db\nPixel_10_Pro_XL\ncampfire-shots-phone\n"
        #expect(AndroidDevices.parseAVDs(list) == ["Pixel_10_Pro_XL", "campfire-shots-phone"])
        #expect(AndroidDevices.parseAVDName("Pixel_10_Pro_XL\r\nOK\r\n") == "Pixel_10_Pro_XL")
        #expect(AndroidDevices.parseAVDName("OK\n") == nil)
    }

    /// A running emulator is listed once, under its AVD's name and as running; the AVDs that are not
    /// running follow, to be booted.
    @Test func combinesConnectionsAndAVDs() {
        let connections = AndroidDevices.parseDevices("""
        List of devices attached
        emulator-5554 device model:sdk_gphone64_arm64
        1A2B3C device model:Pixel_8_Pro
        ZX1 unauthorized
        """)
        let devices = AndroidDevices.devices(connections: connections, runningAVDs: ["emulator-5554": "Pixel_10_Pro_XL"],
                                             avds: ["Pixel_10_Pro_XL", "Pixel_9_Pro_Fold"])
        #expect(devices.map(\.id) == ["avd:Pixel_10_Pro_XL", "1A2B3C", "ZX1", "avd:Pixel_9_Pro_Fold"])
        #expect(devices[0].name == "Pixel 10 Pro XL" && devices[0].isRunning && devices[0].serial == "emulator-5554")
        #expect(devices[1].kind == .physical && devices[1].name == "Pixel 8 Pro")
        #expect(devices[2].problem != nil && !devices[2].isRunning)
        #expect(!devices[3].isRunning && devices[3].avdName == "Pixel_9_Pro_Fold" && devices[3].serial == nil)
    }

    @Test func parsesSimulatorsNewestRuntimeFirstIPhonesFirst() throws {
        let json = """
        {"devices": {
          "com.apple.CoreSimulator.SimRuntime.iOS-18-4": [
            {"name": "iPhone 16 Pro", "udid": "A", "state": "Shutdown", "isAvailable": true}
          ],
          "com.apple.CoreSimulator.SimRuntime.watchOS-11-0": [
            {"name": "Apple Watch Ultra", "udid": "W", "state": "Shutdown", "isAvailable": true}
          ],
          "com.apple.CoreSimulator.SimRuntime.iOS-26-2": [
            {"name": "iPhone 16e", "udid": "E", "state": "Shutdown", "isAvailable": true},
            {"name": "iPad Pro 13-inch", "udid": "C", "state": "Shutdown", "isAvailable": true},
            {"name": "iPhone 17 Pro", "udid": "B", "state": "Booted", "isAvailable": true},
            {"name": "iPhone Gone", "udid": "D", "state": "Shutdown", "isAvailable": false}
          ]
        }}
        """
        let sims = IOSSimulators.devices(listJSON: Data(json.utf8))
        // Newest model first within a runtime: the 17 before the 16e that sorts first by name.
        #expect(sims.map(\.id) == ["B", "E", "C", "A"])
        #expect(sims[0].isRunning && sims[0].detail == "iOS 26.2")
        #expect(sims[2].symbol == "ipad")
        #expect(IOSSimulators.modelNumber("iPhone Air") == -1 && IOSSimulators.modelNumber("iPhone 17 Pro") == 17)
        #expect(IOSSimulators.runtimeName("com.apple.CoreSimulator.SimRuntime.iOS-18-4") == "iOS 18.4")
    }

    @Test func picksRememberedThenRunningThenFirstBootable() {
        let avd = RunDevice(platform: .android, kind: .emulator, id: "avd:A", name: "A", isRunning: false, avdName: "A")
        let phone = RunDevice(platform: .android, kind: .physical, id: "P", name: "Phone", serial: "P", isRunning: true)
        let locked = RunDevice(platform: .android, kind: .physical, id: "L", name: "Locked", serial: "L", isRunning: false, problem: "Unauthorized")
        #expect(RunDeviceChoice.pick([avd, phone], remembered: "avd:A")?.id == "avd:A")
        #expect(RunDeviceChoice.pick([avd, phone], remembered: "gone")?.id == "P")
        #expect(RunDeviceChoice.pick([locked, avd], remembered: nil)?.id == "avd:A")
        #expect(RunDeviceChoice.pick([locked], remembered: nil) == nil)
        #expect(RunDeviceChoice.pick([], remembered: "avd:A") == nil)
    }

    @Test func infersThePlatformFromTheCommand() {
        #expect(RunDevicePlatform.inferred(fromCommand: "./gradlew :app:android:installAlphaDebug") == .android)
        #expect(RunDevicePlatform.inferred(fromCommand: "./gradlew installDebug && adb shell monkey -p a.b 1") == .android)
        #expect(RunDevicePlatform.inferred(fromCommand: #"xcrun simctl launch "$SIMULATOR_UDID" app.campfire"#) == .ios)
        #expect(RunDevicePlatform.inferred(fromCommand: "./gradlew :app:desktop:run") == nil)
        #expect(RunDevicePlatform.inferred(fromCommand: "make install") == nil)
        #expect(RunDevicePlatform.inferred(fromCommand: nil) == nil)
    }

    @Test func readsTheSDKFromLocalPropertiesFirst() {
        #expect(AndroidSDK.sdkDir(localProperties: "## comment\nsdk.dir=/Users/me/Library/Android/sdk\n") == "/Users/me/Library/Android/sdk")
        #expect(AndroidSDK.sdkDir(localProperties: #"sdk.dir=C\:\\Android\\sdk"#) == #"C:\Android\sdk"#)
        #expect(AndroidSDK.sdkDir(localProperties: "org.gradle.jvmargs=-Xmx2g") == nil)
        let home = URL(fileURLWithPath: "/Users/me")
        let found = AndroidSDK.locate(projectRoot: nil, environment: ["ANDROID_HOME": "/opt/sdk"], home: home) { $0 == "/opt/sdk/platform-tools" }
        #expect(found?.path == "/opt/sdk")
        let fallback = AndroidSDK.locate(projectRoot: nil, environment: [:], home: home) { $0 == "/Users/me/Library/Android/sdk/platform-tools" }
        #expect(fallback?.path == "/Users/me/Library/Android/sdk")
    }

    @Test func deviceRoundTripsAndUnknownPlatformsReadAsNone() throws {
        let file = try RunConfigurationFile.decode(Data("""
        {"version": 1, "configurations": [
          {"id": "a", "name": "Android", "command": "./gradlew installDebug", "device": "android"},
          {"id": "w", "name": "Watch", "command": "x", "device": "watchos"}
        ]}
        """.utf8))
        #expect(file.configurations[0].device == .android)
        #expect(file.configurations[1].device == nil)
        let again = try RunConfigurationFile.decode(file.encoded())
        #expect(again.configurations[0].device == .android)
    }
}
