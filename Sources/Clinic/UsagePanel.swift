import SwiftUI
import Security
import os
import ClinicCore

/// Reads the CLI's OAuth token (Keychain first, credentials file second) and polls usage every 5 minutes (ADR-051).
@MainActor
@Observable
final class UsageService {
    private static let log = Logger(subsystem: "com.r0adkll.clinic", category: "usage")
    private(set) var snapshot: UsageSnapshot?
    private(set) var error: String?
    private(set) var isLoading = false
    private var timer: Task<Void, Never>?
    static let interval: Duration = .seconds(300)

    func start() {
        guard timer == nil else { return }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: Self.interval)
            }
        }
    }

    func stop() { timer?.cancel(); timer = nil }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            guard let creds = Self.readCredentials() else { throw UsageError.noCredentials }
            snapshot = try await UsageClient.fetch(credentials: creds)
            error = nil
        } catch {
            self.error = "\(error)"
            Self.log.warning("usage: \(error, privacy: .public)")
        }
    }

    /// Keychain generic password `Claude Code-credentials`; falls back to the credentials file (Linux-style layout).
    nonisolated static func readCredentials() -> ClaudeCredentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data, let c = ClaudeCredentials.parse(data) {
            return c
        }
        let file = ClaudePaths().configDirectory.appendingPathComponent(".credentials.json")
        if let data = try? Data(contentsOf: file) { return ClaudeCredentials.parse(data) }
        return nil
    }
}

struct UsagePanel: View {
    @Environment(UsageService.self) private var usage
    @AppStorage("ClinicUsageExpanded") private var expanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button { expanded.toggle() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.caption2)
                        Text("Claude usage").font(.caption.weight(.semibold))
                        if let sub = usage.snapshot?.subscription, !sub.isEmpty { Text(sub.capitalized).font(.caption2).foregroundStyle(.secondary) }
                    }
                }.buttonStyle(.plain)
                Spacer()
                Button { Task { await usage.refresh() } } label: { Image(systemName: "arrow.clockwise").font(.caption2) }
                    .buttonStyle(.plain).disabled(usage.isLoading).help("Refresh")
            }
            if expanded {
                if let snap = usage.snapshot {
                    ForEach(snap.bars) { bar in UsageBarView(bar: bar) }
                    if let c = snap.credits {
                        HStack {
                            Text("Extra usage").font(.caption2)
                            Spacer()
                            Text(c.used, format: .currency(code: c.currency)) + Text(c.limit.map { " / " + $0.formatted(.currency(code: c.currency)) } ?? "")
                        }.font(.caption2).foregroundStyle(c.spendLimitReached ? .red : .secondary)
                    }
                    Text("Updated \(snap.fetchedAt, format: .relative(presentation: .named))").font(.caption2).foregroundStyle(.tertiary)
                } else if let error = usage.error {
                    Text(error).font(.caption2).foregroundStyle(.secondary).lineLimit(3)
                } else {
                    Text("Loading…").font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.bar)
    }
}

struct UsageBarView: View {
    let bar: UsageSnapshot.Bar

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(bar.title).font(.caption2)
                Spacer()
                Text("\(bar.rawPercent)%").font(.caption2).monospacedDigit().foregroundStyle(color)
            }
            ProgressView(value: Double(bar.percent), total: 100).tint(color).controlSize(.small)
            if let r = bar.resetsAt {
                Text("Resets \(r, format: .relative(presentation: .named))").font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private var color: Color {
        switch bar.severity {
        case "exceeded": return .red
        case "warning": return .orange
        default: return bar.percent >= 90 ? .orange : .accentColor
        }
    }
}
