import Foundation
import os
import ClinicCore

/// Once a day, asks GitHub for the latest release and announces a newer one once (ADR-066).
@MainActor
final class UpdateCheck {
    private static let log = Logger(subsystem: "com.r0adkll.clinic", category: "update")
    static let url = URL(string: "https://api.github.com/repos/r0adkll/clinic/releases/latest")!

    static var currentVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }

    func start(notify: @escaping @MainActor (String, URL) -> Void) {
        guard UserDefaults.standard.object(forKey: "ClinicCheckForUpdates") as? Bool ?? true else { return }
        let last = UserDefaults.standard.double(forKey: "ClinicUpdateCheckedAt")
        guard Date().timeIntervalSince1970 - last > 86_400 else { return }
        Task {
            var req = URLRequest(url: Self.url); req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept"); req.setValue("Clinic", forHTTPHeaderField: "User-Agent")
            guard let (data, _) = try? await URLSession.shared.data(for: req),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = obj["tag_name"] as? String, let html = obj["html_url"] as? String, let url = URL(string: html) else { return }
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "ClinicUpdateCheckedAt")
            let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            guard Self.isNewer(latest, than: Self.currentVersion), UserDefaults.standard.string(forKey: "ClinicAnnouncedUpdate") != latest else { return }
            UserDefaults.standard.set(latest, forKey: "ClinicAnnouncedUpdate")
            notify(latest, url)
        }
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }, pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
