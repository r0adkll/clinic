import Foundation

/// What a run configuration installs onto (ADR-124). A configuration that names one runs only once
/// Clinic has a device of that kind ready: connected, or an emulator or simulator it has booted.
public enum RunDevicePlatform: String, Codable, Sendable, CaseIterable, Identifiable {
    case android, ios

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .android: "Android device"
        case .ios: "iOS Simulator"
        }
    }

    /// The variable the run's command gets, naming the device it should use. Gradle's install tasks
    /// and `adb` read `ANDROID_SERIAL` themselves; an iOS command passes `$SIMULATOR_UDID` on.
    public var environmentKey: String {
        switch self {
        case .android: "ANDROID_SERIAL"
        case .ios: "SIMULATOR_UDID"
        }
    }

    /// A guess from the command alone, for detected and imported configurations: an install task or
    /// `adb` means Android, `simctl` or an iOS Simulator destination means iOS.
    public static func inferred(fromCommand command: String?) -> RunDevicePlatform? {
        guard let command else { return nil }
        if command.contains("simctl") || command.contains("iOS Simulator") || command.contains("SIMULATOR_UDID") { return .ios }
        if command.range(of: #"\binstall[A-Za-z0-9]*(Debug|Release)\b"#, options: .regularExpression) != nil
            || command.range(of: #"(^|[\s;&|(])adb\s"#, options: .regularExpression) != nil { return .android }
        return nil
    }
}

/// One device a run can target.
public struct RunDevice: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable { case physical, emulator, simulator }

    public var platform: RunDevicePlatform
    public var kind: Kind
    /// What a remembered choice is keyed by: a physical device's serial, `avd:<name>` for an
    /// emulator (its serial changes on every boot), a simulator's UDID.
    public var id: String
    public var name: String
    /// A serial, or a simulator's runtime ("iOS 26.2").
    public var detail: String?
    /// The adb serial of a connected device or running emulator; a simulator's UDID.
    public var serial: String?
    /// Connected and online, or booted.
    public var isRunning: Bool
    /// Why it cannot be used as it stands ("unauthorized"): shown, not chosen.
    public var problem: String?
    public var avdName: String?

    public init(platform: RunDevicePlatform, kind: Kind, id: String, name: String, detail: String? = nil, serial: String? = nil,
                isRunning: Bool, problem: String? = nil, avdName: String? = nil) {
        self.platform = platform; self.kind = kind; self.id = id; self.name = name; self.detail = detail; self.serial = serial
        self.isRunning = isRunning; self.problem = problem; self.avdName = avdName
    }

    /// SF Symbol: a phone for a phone, a tablet for a tablet-sized AVD or simulator.
    public var symbol: String {
        let n = name.lowercased()
        return n.contains("ipad") || n.contains("tablet") || n.contains("fold") || n.contains("ten") ? "ipad" : "iphone"
    }
}

public struct RunDeviceError: Error, CustomStringConvertible, Equatable {
    public let description: String
    public init(_ description: String) { self.description = description }
}

// MARK: - Android

/// Where the Android SDK is: the project's `local.properties` (what Gradle itself uses), then
/// `ANDROID_HOME` / `ANDROID_SDK_ROOT`, then Android Studio's default. A GUI app does not inherit the
/// shell's `ANDROID_HOME`, so the first and last are the ones that usually answer.
public enum AndroidSDK {
    public static func locate(projectRoot: String?, environment: [String: String] = ProcessInfo.processInfo.environment,
                              home: URL = FileManager.default.homeDirectoryForCurrentUser,
                              exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> URL? {
        var candidates: [String] = []
        if let root = projectRoot,
           let props = try? String(contentsOfFile: root + "/local.properties", encoding: .utf8),
           let dir = sdkDir(localProperties: props) { candidates.append(dir) }
        candidates += [environment["ANDROID_HOME"], environment["ANDROID_SDK_ROOT"]].compactMap { $0 }
        candidates.append(home.appendingPathComponent("Library/Android/sdk").path)
        return candidates.first { !$0.isEmpty && exists($0 + "/platform-tools") }.map { URL(fileURLWithPath: $0) }
    }

    /// `sdk.dir=/Users/me/Library/Android/sdk` (escaped as Java properties escape `:` and `\`).
    static func sdkDir(localProperties: String) -> String? {
        for line in localProperties.split(whereSeparator: \.isNewline) {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("sdk.dir"), let eq = t.firstIndex(where: { $0 == "=" || $0 == ":" }) else { continue }
            let value = t[t.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "\\:", with: ":").replacingOccurrences(of: "\\\\", with: "\\")
            return value.isEmpty ? nil : value
        }
        return nil
    }

    static func tool(_ relative: String, in sdk: URL?, fallback: String) -> String {
        guard let sdk else { return fallback }
        let path = sdk.appendingPathComponent(relative).path
        return FileManager.default.isExecutableFile(atPath: path) ? path : fallback
    }
}

public enum AndroidDevices {
    public struct Connection: Equatable, Sendable {
        public var serial: String
        public var state: String
        public var model: String?
    }

    /// `adb devices -l`: `<serial> <state> [key:value…]`, after a header and any daemon chatter.
    public static func parseDevices(_ output: String) -> [Connection] {
        output.split(whereSeparator: \.isNewline).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("List of devices"), !line.hasPrefix("*") else { return nil }
            let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard parts.count >= 2 else { return nil }
            let model = parts.dropFirst(2).first { $0.hasPrefix("model:") }.map { String($0.dropFirst(6)) }
            return Connection(serial: parts[0], state: parts[1], model: model)
        }
    }

    /// `emulator -list-avds`: one name per line, among `INFO |`/`WARNING |` lines newer emulators print.
    public static func parseAVDs(_ output: String) -> [String] {
        output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.contains("|") && !$0.contains(" ") && !$0.hasPrefix("INFO") && !$0.hasPrefix("WARNING") }
    }

    /// `adb -s emulator-5554 emu avd name`: the name, then `OK`.
    public static func parseAVDName(_ output: String) -> String? {
        output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && $0 != "OK" && !$0.hasPrefix("KO") }
    }

    /// `Pixel_10_Pro_XL` → `Pixel 10 Pro XL`.
    public static func displayName(_ raw: String) -> String { raw.replacingOccurrences(of: "_", with: " ") }

    /// The picker's list: connected devices first (a running emulator under its AVD's name), then the
    /// AVDs that are not running, which a run would boot.
    public static func devices(connections: [Connection], runningAVDs: [String: String], avds: [String]) -> [RunDevice] {
        var out: [RunDevice] = []
        var running: Set<String> = []
        for c in connections {
            let problem: String? = switch c.state {
            case "device": nil
            case "unauthorized": "Unauthorized: accept the prompt on the device"
            case "offline": "Offline"
            default: c.state
            }
            if let avd = runningAVDs[c.serial] {
                running.insert(avd)
                out.append(RunDevice(platform: .android, kind: .emulator, id: "avd:" + avd, name: displayName(avd), detail: c.serial,
                                     serial: c.serial, isRunning: problem == nil, problem: problem, avdName: avd))
            } else {
                let name = c.model.map(displayName) ?? c.serial
                out.append(RunDevice(platform: .android, kind: c.serial.hasPrefix("emulator-") ? .emulator : .physical, id: c.serial,
                                     name: name, detail: c.serial, serial: c.serial, isRunning: problem == nil, problem: problem))
            }
        }
        for avd in avds where !running.contains(avd) {
            out.append(RunDevice(platform: .android, kind: .emulator, id: "avd:" + avd, name: displayName(avd), isRunning: false, avdName: avd))
        }
        return out
    }
}

// MARK: - iOS

public enum IOSSimulators {
    /// `xcrun simctl list devices available -j`: iOS runtimes only, newest first; iPhones before iPads.
    public static func devices(listJSON: Data) -> [RunDevice] {
        guard let root = try? JSONSerialization.jsonObject(with: listJSON) as? [String: Any],
              let byRuntime = root["devices"] as? [String: [[String: Any]]] else { return [] }
        let runtimes = byRuntime.keys.filter { $0.contains(".SimRuntime.iOS-") }.sorted { version($0).lexicographicallyPrecedes(version($1)) }.reversed()
        var out: [RunDevice] = []
        for runtime in runtimes {
            let label = runtimeName(runtime)
            let devices = (byRuntime[runtime] ?? []).filter { ($0["isAvailable"] as? Bool) ?? true }
            // iPhones before iPads, newest model first ("iPhone 17" before "iPhone 16e"), so the default
            // is the phone Xcode would pick rather than whichever sorts first alphabetically.
            let sorted = devices.sorted { a, b in
                let an = a["name"] as? String ?? "", bn = b["name"] as? String ?? ""
                let ap = an.hasPrefix("iPad"), bp = bn.hasPrefix("iPad")
                if ap != bp { return !ap }
                let av = modelNumber(an), bv = modelNumber(bn)
                return av == bv ? an < bn : av > bv
            }
            for d in sorted {
                guard let udid = d["udid"] as? String, let name = d["name"] as? String else { continue }
                out.append(RunDevice(platform: .ios, kind: .simulator, id: udid, name: name, detail: label, serial: udid,
                                     isRunning: (d["state"] as? String) == "Booted"))
            }
        }
        return out
    }

    /// The first number in a device name (`iPhone 17 Pro` → 17); -1 when there is none (`iPhone Air`).
    static func modelNumber(_ name: String) -> Int {
        name.split(whereSeparator: { !$0.isNumber }).first.flatMap { Int($0) } ?? -1
    }

    /// `com.apple.CoreSimulator.SimRuntime.iOS-26-2` → `iOS 26.2`.
    static func runtimeName(_ identifier: String) -> String {
        guard let r = identifier.range(of: ".SimRuntime.") else { return identifier }
        let tail = identifier[r.upperBound...]
        guard let dash = tail.firstIndex(of: "-") else { return String(tail) }
        return tail[..<dash] + " " + tail[tail.index(after: dash)...].replacingOccurrences(of: "-", with: ".")
    }

    private static func version(_ identifier: String) -> [Int] {
        runtimeName(identifier).split(separator: " ").last.map { $0.split(separator: ".").compactMap { Int($0) } } ?? []
    }
}

// MARK: - Choosing and preparing

public enum RunDeviceChoice {
    /// The device a run uses: the remembered one while it is still listed; else one that is already
    /// running; else, for Android, the first emulator (a run then boots it) and, for iOS, the newest
    /// runtime's first iPhone.
    public static func pick(_ devices: [RunDevice], remembered: String?) -> RunDevice? {
        if let remembered, let d = devices.first(where: { $0.id == remembered }) { return d }
        if let running = devices.first(where: { $0.isRunning && $0.problem == nil }) { return running }
        return devices.first { $0.kind != .physical && $0.problem == nil }
    }
}

/// Lists devices and gets one ready (ADR-124). Subprocesses only, each bounded so a wedged `adb` or
/// `simctl` cannot hang a run.
public enum RunDeviceProbe {
    public static func list(_ platform: RunDevicePlatform, projectRoot: String?) async -> [RunDevice] {
        switch platform {
        case .android: return await listAndroid(sdk: AndroidSDK.locate(projectRoot: projectRoot))
        case .ios:
            guard let data = await run("xcrun", ["simctl", "list", "devices", "available", "-j"], timeout: .seconds(10)) else { return [] }
            return IOSSimulators.devices(listJSON: data)
        }
    }

    private static func listAndroid(sdk: URL?) async -> [RunDevice] {
        let adb = AndroidSDK.tool("platform-tools/adb", in: sdk, fallback: "adb")
        let emulator = AndroidSDK.tool("emulator/emulator", in: sdk, fallback: "emulator")
        let connections = await run(adb, ["devices", "-l"], timeout: .seconds(8)).map { AndroidDevices.parseDevices(string($0)) } ?? []
        var runningAVDs: [String: String] = [:]
        for c in connections where c.serial.hasPrefix("emulator-") && c.state == "device" {
            if let out = await run(adb, ["-s", c.serial, "emu", "avd", "name"], timeout: .seconds(4)),
               let name = AndroidDevices.parseAVDName(string(out)) { runningAVDs[c.serial] = name }
        }
        let avds = await run(emulator, ["-list-avds"], timeout: .seconds(8)).map { AndroidDevices.parseAVDs(string($0)) } ?? []
        return AndroidDevices.devices(connections: connections, runningAVDs: runningAVDs, avds: avds)
    }

    /// Makes `device` ready and returns the environment the run's command needs. Boots an emulator or
    /// a simulator that is not running — detached, so it outlives the run, as Android Studio's do.
    /// `progress` hears each step; cancelling stops the waiting, not the boot.
    public static func prepare(_ device: RunDevice, projectRoot: String?,
                               progress: @escaping @Sendable (String) -> Void) async throws -> [String: String] {
        if let problem = device.problem { throw RunDeviceError("\(device.name): \(problem)") }
        switch device.platform {
        case .android: return try await prepareAndroid(device, sdk: AndroidSDK.locate(projectRoot: projectRoot), progress: progress)
        case .ios: return try await prepareIOS(device, progress: progress)
        }
    }

    private static func prepareAndroid(_ device: RunDevice, sdk: URL?, progress: @escaping @Sendable (String) -> Void) async throws -> [String: String] {
        if device.isRunning, let serial = device.serial { return ["ANDROID_SERIAL": serial] }
        guard let avd = device.avdName else { throw RunDeviceError("\(device.name) is not connected.") }
        let adb = AndroidSDK.tool("platform-tools/adb", in: sdk, fallback: "adb")
        let emulator = AndroidSDK.tool("emulator/emulator", in: sdk, fallback: "emulator")
        progress("Starting \(device.name)…")
        let process = try launchDetached(emulator, ["-avd", avd])
        let deadline = Date().addingTimeInterval(240)
        var serial: String?
        while serial == nil {
            try Task.checkCancellation()
            guard Date() < deadline else { throw RunDeviceError("\(device.name) did not appear within 4 minutes.") }
            if !process.isRunning, process.terminationStatus != 0 {
                throw RunDeviceError("The emulator exited (\(process.terminationStatus)) before \(device.name) started. Try booting it from Android Studio's Device Manager.")
            }
            let connections = await run(adb, ["devices"], timeout: .seconds(5)).map { AndroidDevices.parseDevices(string($0)) } ?? []
            for c in connections where c.serial.hasPrefix("emulator-") {
                if let out = await run(adb, ["-s", c.serial, "emu", "avd", "name"], timeout: .seconds(4)),
                   AndroidDevices.parseAVDName(string(out)) == avd { serial = c.serial; break }
            }
            if serial == nil { try await Task.sleep(for: .seconds(1)) }
        }
        guard let serial else { throw RunDeviceError("\(device.name) did not appear.") }
        progress("Waiting for \(device.name) to finish booting…")
        while true {
            try Task.checkCancellation()
            guard Date() < deadline else { throw RunDeviceError("\(device.name) did not finish booting within 4 minutes.") }
            if let out = await run(adb, ["-s", serial, "shell", "getprop", "sys.boot_completed"], timeout: .seconds(5)),
               string(out).trimmingCharacters(in: .whitespacesAndNewlines) == "1" { break }
            try await Task.sleep(for: .seconds(1))
        }
        return ["ANDROID_SERIAL": serial]
    }

    private static func prepareIOS(_ device: RunDevice, progress: @escaping @Sendable (String) -> Void) async throws -> [String: String] {
        guard let udid = device.serial else { throw RunDeviceError("\(device.name) has no UDID.") }
        if !device.isRunning {
            progress("Booting \(device.name)…")
            // `bootstatus -b` boots the simulator if it is not booted and returns once it is ready.
            guard await run("xcrun", ["simctl", "bootstatus", udid, "-b"], timeout: .seconds(300)) != nil else {
                throw RunDeviceError("\(device.name) did not boot. Try it from Xcode's Devices and Simulators window.")
            }
        }
        // Brings the Simulator window up on this device, as Xcode does; the run carries on either way.
        _ = await run("open", ["-a", "Simulator", "--args", "-CurrentDeviceUDID", udid], timeout: .seconds(10))
        return ["SIMULATOR_UDID": udid]
    }

    private static func launchDetached(_ tool: String, _ arguments: [String]) throws -> Process {
        let p = Process()
        if tool.hasPrefix("/") {
            p.executableURL = URL(fileURLWithPath: tool)
            p.arguments = arguments
        } else {
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments = [tool] + arguments
        }
        p.environment = ProcessEnvironment.withToolPaths()
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        return p
    }

    private static func run(_ tool: String, _ arguments: [String], timeout: Duration) async -> Data? {
        await RunDetector.boundedRun(tool, arguments, in: FileManager.default.homeDirectoryForCurrentUser, timeout: timeout)
    }

    private static func string(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }
}
