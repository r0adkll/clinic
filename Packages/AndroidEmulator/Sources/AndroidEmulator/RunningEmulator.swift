import Foundation

/// An emulator that is running now, read from the discovery file every emulator writes while it runs:
/// `~/Library/Caches/TemporaryItems/avd/running/pid_<pid>.ini`. Android Studio's emulators, headless ones
/// and ones Clinic booted all write one, with the gRPC port and the token that opens it.
public struct RunningEmulator: Sendable, Hashable, Identifiable {
    /// The AVD's id (`avd.id`), which names it across boots; its serial changes on every boot.
    public let avdId: String
    /// The AVD's display name (`avd.name`).
    public let name: String
    /// The emulator process, from the file's name.
    public let pid: Int32
    /// The console port, so the adb serial is `emulator-<serialPort>`.
    public let serialPort: Int
    public let grpcPort: Int
    /// Sent as `authorization: Bearer <token>`; nil for an emulator started without `-grpc-use-token`.
    public let token: String?
    /// The SDK the emulator was launched from (the parent of `launcher.dir`), for its adb.
    public let sdkDirectory: URL?

    public var id: String { avdId }
    public var serial: String { "emulator-\(serialPort)" }
    /// The id a Device pane and a run's device use for this emulator: `avd:<id>`, since the serial
    /// changes on every boot.
    public var deviceId: String { "avd:" + avdId }
    public var adb: String { sdkDirectory.map { $0.appendingPathComponent("platform-tools/adb").path } ?? "adb" }

    /// Parses one discovery file. Nil when it lacks the AVD or the gRPC port.
    public init?(ini: String, pid: Int32) {
        var values: [String: String] = [:]
        for line in ini.split(whereSeparator: \.isNewline) {
            guard let eq = line.firstIndex(of: "=") else { continue }
            values[String(line[..<eq])] = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
        }
        guard let avdId = values["avd.id"], !avdId.isEmpty,
              let grpcPort = values["grpc.port"].flatMap(Int.init) else { return nil }
        self.avdId = avdId
        self.name = values["avd.name"].flatMap { $0.isEmpty ? nil : $0 } ?? avdId.replacingOccurrences(of: "_", with: " ")
        self.pid = pid
        self.serialPort = values["port.serial"].flatMap(Int.init) ?? 0
        self.grpcPort = grpcPort
        self.token = values["grpc.token"].flatMap { $0.isEmpty ? nil : $0 }
        self.sdkDirectory = values["launcher.dir"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0).deletingLastPathComponent() }
    }

    /// Where emulators write their discovery files on macOS.
    public static var discoveryDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/TemporaryItems/avd/running", isDirectory: true)
    }

    /// Every emulator with a discovery file whose process is still alive, sorted by name. A file left
    /// behind by an emulator that crashed is skipped rather than offered.
    public static func scan(_ directory: URL = discoveryDirectory) -> [RunningEmulator] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.compactMap { name -> RunningEmulator? in
            guard name.hasPrefix("pid_"), name.hasSuffix(".ini"),
                  let pid = Int32(name.dropFirst(4).dropLast(4)), kill(pid, 0) == 0 || errno == EPERM,
                  let ini = try? String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8) else { return nil }
            return RunningEmulator(ini: ini, pid: pid)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
