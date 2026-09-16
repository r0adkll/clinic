// Prints the CGWindowID of the largest normal on-screen window owned by a pid (ADR-159).
import CoreGraphics
import Foundation

guard CommandLine.arguments.count == 2, let pid = Int32(CommandLine.arguments[1]) else {
    FileHandle.standardError.write(Data("usage: window-id <pid>\n".utf8)); exit(2)
}
let windows = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? [])
    .filter { ($0[kCGWindowOwnerPID as String] as? Int32) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }
    .compactMap { w -> (Int, Double)? in
        guard let id = w[kCGWindowNumber as String] as? Int, let b = w[kCGWindowBounds as String] as? [String: Double] else { return nil }
        return (id, (b["Width"] ?? 0) * (b["Height"] ?? 0))
    }
guard let largest = windows.max(by: { $0.1 < $1.1 }) else { exit(1) }
print(largest.0)
