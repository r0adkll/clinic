import Foundation
import os

/// Package-wide logger.
let ghosttyLog = Logger(subsystem: "com.clinic.GhosttyBridge", category: "GhosttyBridge")

/// Errors thrown by the bridge.
public enum GhosttyError: Error, Sendable, CustomStringConvertible {
    /// `ghostty_init` returned a non-success code.
    case initFailed(Int32)
    /// `ghostty_config_new` returned NULL.
    case configCreateFailed
    /// `ghostty_app_new` returned NULL.
    case appCreateFailed
    /// `ghostty_surface_new` returned NULL.
    case surfaceCreateFailed
    /// A libghostty call was attempted after `free()` / on a dead handle.
    case surfaceFreed

    public var description: String {
        switch self {
        case .initFailed(let code): return "ghostty_init failed with code \(code)"
        case .configCreateFailed: return "ghostty_config_new failed"
        case .appCreateFailed: return "ghostty_app_new failed"
        case .surfaceCreateFailed: return "ghostty_surface_new failed"
        case .surfaceFreed: return "surface has already been freed"
        }
    }
}

/// Runs `body` with a temporary array of C strings for `strings`, valid only inside the closure.
func withCStrings<R>(_ strings: [String], _ body: ([UnsafePointer<CChar>]) throws -> R) rethrows -> R {
    func recurse(_ index: Int, _ acc: [UnsafePointer<CChar>]) throws -> R {
        if index == strings.count { return try body(acc) }
        return try strings[index].withCString { ptr in
            try recurse(index + 1, acc + [ptr])
        }
    }
    return try recurse(0, [])
}

/// Shell escaping for file paths dropped/pasted into the terminal.
/// (Technique from Ghostty's `Ghostty.Shell.escape`, MIT licensed.)
enum ShellEscape {
    private static let escapeCharacters = "\\ ()[]{}<>\"'`!#$&;|*?\t"

    static func escape(_ str: String) -> String {
        var result = str
        for char in escapeCharacters {
            result = result.replacingOccurrences(of: String(char), with: "\\\(char)")
        }
        return result
    }
}
