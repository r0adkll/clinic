// clinic-wake: launchd's end of the *Run automations when Clinic isn't open* preference (ADR-095).
//
// This is a wake-up, not a scheduler. Clinic has exactly one scheduler and it lives in the app; all
// this does is bring the app back so that scheduler's ordinary catch-up pass can run. That is why it
// knows nothing about cron, automations, or what is due.
//
// It is deliberately tiny and always exits 0: a launchd agent that fails loudly every five minutes is
// worse than one that quietly does nothing.
import Foundation

let bundleId = "com.r0adkll.clinic"

/// Written by Clinic when the user quits it on purpose. An app that resurrects itself four minutes
/// after you quit it is hostile, so an explicit quit suppresses the wake until the next login —
/// launchd re-runs the agent from scratch then, and a fresh boot leaves no marker behind.
func isSuppressed() -> Bool {
    let support = ProcessInfo.processInfo.environment["CLINIC_APP_SUPPORT"].map { URL(fileURLWithPath: $0) }
        ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    let marker = support.appendingPathComponent("Clinic/wake-suppressed", isDirectory: false)
    guard let data = try? Data(contentsOf: marker),
          let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
          let bootTime = text.isEmpty ? nil : Double(text)
    else { return false }
    // The marker records the boot time it was written against; a different boot means a new login
    // session, so the suppression has expired.
    return abs(bootTime - systemBootTime()) < 1
}

func systemBootTime() -> Double {
    var tv = timeval()
    var size = MemoryLayout<timeval>.stride
    var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
    guard sysctl(&mib, 2, &tv, &size, nil, 0) == 0 else { return 0 }
    return Double(tv.tv_sec)
}

guard !isSuppressed() else { exit(0) }

// -g: do not bring it to the front. -j: launch hidden. Together these put Clinic into exactly the
// resident, window-less state ADR-069's Keep Running already designed for.
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
p.arguments = ["-g", "-j", "-b", bundleId]
try? p.run()
p.waitUntilExit()
exit(0)
