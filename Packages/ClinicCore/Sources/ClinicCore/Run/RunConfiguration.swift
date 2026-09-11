import Foundation

/// One thing a project can run (ADR-122): a named shell command, or a compound that starts several
/// configurations at once. Lives in `<project>/.clinic/run.json`.
public struct RunConfiguration: Codable, Sendable, Equatable, Identifiable, Hashable {
    public var id: String
    public var name: String
    /// An SF Symbol name; the app falls back to `play.fill`.
    public var icon: String?
    /// One shell command line. Absent on a compound.
    public var command: String?
    /// Relative to the checkout; `.` when absent.
    public var directory: String?
    public var env: [String: String]?
    /// Re-run after a turn that changed files, when it has already run in that checkout.
    public var rerunAfterTurn: Bool?
    /// Member ids, started at once. A configuration with `compound` has no `command`.
    public var compound: [String]?
    /// The device it installs onto (ADR-124): Clinic gets one ready and names it in the environment.
    public var device: RunDevicePlatform?
    /// Keys Clinic does not know, kept so a save never drops what someone else wrote.
    public var extra: [String: JSONValue] = [:]

    public init(id: String, name: String, icon: String? = nil, command: String? = nil, directory: String? = nil,
                env: [String: String]? = nil, rerunAfterTurn: Bool? = nil, compound: [String]? = nil, device: RunDevicePlatform? = nil) {
        self.id = id; self.name = name; self.icon = icon; self.command = command; self.directory = directory
        self.env = env; self.rerunAfterTurn = rerunAfterTurn; self.compound = compound; self.device = device
    }

    public var isCompound: Bool { compound != nil && command == nil }
    public var reruns: Bool { rerunAfterTurn ?? false }
    public var symbol: String { icon.flatMap { $0.isEmpty ? nil : $0 } ?? "play.fill" }

    /// A shell command, or a compound with at least one member.
    public var isRunnable: Bool {
        if let command { return !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return !(compound ?? []).isEmpty
    }

    private static let known: Set<String> = ["id", "name", "icon", "command", "directory", "env", "rerunAfterTurn", "compound", "device"]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        func string(_ k: String) throws -> String? { try c.decodeIfPresent(String.self, forKey: AnyKey(k)) }
        let rawName = try string("name")
        // A hand-written entry without an id still needs one to be selected and run; derive it from the name.
        id = try string("id").flatMap { $0.isEmpty ? nil : $0 } ?? RunConfiguration.makeId(from: rawName ?? "run", avoiding: [])
        name = rawName ?? id
        icon = try string("icon")
        command = try string("command")
        directory = try string("directory")
        env = try c.decodeIfPresent([String: String].self, forKey: AnyKey("env"))
        rerunAfterTurn = try c.decodeIfPresent(Bool.self, forKey: AnyKey("rerunAfterTurn"))
        compound = try c.decodeIfPresent([String].self, forKey: AnyKey("compound"))
        // An unknown platform (a newer Clinic's) reads as none rather than failing the whole file.
        device = (try? c.decodeIfPresent(String.self, forKey: AnyKey("device"))).flatMap { $0.flatMap(RunDevicePlatform.init(rawValue:)) }
        for key in c.allKeys where !Self.known.contains(key.stringValue) {
            extra[key.stringValue] = try c.decode(JSONValue.self, forKey: key)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        try c.encode(id, forKey: AnyKey("id"))
        try c.encode(name, forKey: AnyKey("name"))
        try c.encodeIfPresent(icon, forKey: AnyKey("icon"))
        try c.encodeIfPresent(command, forKey: AnyKey("command"))
        try c.encodeIfPresent(directory, forKey: AnyKey("directory"))
        if let env, !env.isEmpty { try c.encode(env, forKey: AnyKey("env")) }
        if rerunAfterTurn == true { try c.encode(true, forKey: AnyKey("rerunAfterTurn")) }
        try c.encodeIfPresent(compound, forKey: AnyKey("compound"))
        try c.encodeIfPresent(device, forKey: AnyKey("device"))
        for (k, v) in extra where !Self.known.contains(k) { try c.encode(v, forKey: AnyKey(k)) }
    }

    /// A unique id derived from a name: lowercase, dashes, and a numeric suffix on collision.
    public static func makeId(from name: String, avoiding taken: Set<String>) -> String {
        let allowed = CharacterSet.alphanumerics
        var slug = ""
        var dash = false
        for scalar in name.lowercased().unicodeScalars {
            if allowed.contains(scalar), scalar.isASCII { slug.unicodeScalars.append(scalar); dash = false }
            else if !dash, !slug.isEmpty { slug += "-"; dash = true }
        }
        while slug.hasSuffix("-") { slug.removeLast() }
        if slug.isEmpty { slug = "run" }
        var candidate = slug
        var n = 2
        while taken.contains(candidate) { candidate = "\(slug)-\(n)"; n += 1 }
        return candidate
    }
}

/// `.clinic/run.json` (ADR-122).
public struct RunConfigurationFile: Codable, Sendable, Equatable {
    public var version: Int = 1
    /// The first selection only; afterwards the selection lives in Clinic's state, never in the repo.
    public var defaultId: String?
    public var configurations: [RunConfiguration] = []
    public var extra: [String: JSONValue] = [:]

    public init(version: Int = 1, defaultId: String? = nil, configurations: [RunConfiguration] = []) {
        self.version = version; self.defaultId = defaultId; self.configurations = configurations
    }

    public static let relativePath = ".clinic/run.json"

    public func configuration(_ id: String) -> RunConfiguration? { configurations.first { $0.id == id } }

    /// Shell commands a compound starts, in its order, skipping unknown ids and nested compounds.
    public func members(of config: RunConfiguration) -> [RunConfiguration] {
        guard config.isCompound else { return [config] }
        return (config.compound ?? []).compactMap { configuration($0) }.filter { !$0.isCompound }
    }

    private static let known: Set<String> = ["version", "default", "configurations"]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        version = try c.decodeIfPresent(Int.self, forKey: AnyKey("version")) ?? 1
        defaultId = try c.decodeIfPresent(String.self, forKey: AnyKey("default"))
        configurations = try c.decodeIfPresent([RunConfiguration].self, forKey: AnyKey("configurations")) ?? []
        for key in c.allKeys where !Self.known.contains(key.stringValue) {
            extra[key.stringValue] = try c.decode(JSONValue.self, forKey: key)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        try c.encode(version, forKey: AnyKey("version"))
        try c.encodeIfPresent(defaultId, forKey: AnyKey("default"))
        try c.encode(configurations, forKey: AnyKey("configurations"))
        for (k, v) in extra where !Self.known.contains(k) { try c.encode(v, forKey: AnyKey(k)) }
    }

    /// Parses a file's bytes. Throws a readable error for the Run menu and the editor to show.
    public static func decode(_ data: Data) throws -> RunConfigurationFile {
        do {
            return try JSONDecoder().decode(RunConfigurationFile.self, from: data)
        } catch let DecodingError.dataCorrupted(context) {
            throw RunConfigurationError.unreadable(context.underlyingError.map { "\($0.localizedDescription)" } ?? context.debugDescription)
        } catch let DecodingError.typeMismatch(_, context), let DecodingError.valueNotFound(_, context) {
            let path = context.codingPath.map { key in key.intValue.map { "[\($0)]" } ?? "." + key.stringValue }.joined()
            let place = path.isEmpty ? "The file" : String(path.drop { $0 == "." })
            throw RunConfigurationError.unreadable(place + ": " + context.debugDescription)
        }
    }

    /// Pretty-printed with sorted keys, so a save produces a stable, reviewable diff.
    public func encoded() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try e.encode(self)
        data.append(0x0A)
        return data
    }

    /// Reads `url`; nil when there is no file.
    public static func load(from url: URL) throws -> RunConfigurationFile? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try decode(Data(contentsOf: url))
    }

    public func write(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoded().write(to: url, options: .atomic)
    }
}

public enum RunConfigurationError: Error, Equatable, CustomStringConvertible {
    case unreadable(String)
    public var description: String {
        switch self { case .unreadable(let why): "run.json could not be read: \(why)" }
    }
}

/// Any JSON value, for keys Clinic keeps without understanding.
public enum JSONValue: Codable, Sendable, Equatable, Hashable {
    case string(String), number(Double), bool(Bool), null
    case array([JSONValue]), object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n):
            if n.rounded() == n, abs(n) < 1e15 { try c.encode(Int64(n)) } else { try c.encode(n) }
        case .bool(let b): try c.encode(b)
        case .null: try c.encodeNil()
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

struct AnyKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(_ s: String) { stringValue = s }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}
