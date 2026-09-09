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

    /// The user has explicitly connected their Claude account (ADR-070). Nothing touches the Keychain before this.
    static let connectedKey = "ClinicUsageConnected"
    var isConnected: Bool { UserDefaults.standard.bool(forKey: Self.connectedKey) }

    /// Starts polling only if the user connected earlier.
    ///
    /// Never in a smoke instance. `CLINIC_APP_SUPPORT` does not isolate `UserDefaults`, so a smoke run
    /// inherits the real app's consent and polls on launch — and because the smoke build lives at a
    /// different path than the keychain item's ACL trusts, macOS puts up a password prompt over the
    /// window under test. Connecting by hand still works if a run actually needs usage.
    func start() {
        guard !ClinicPaths.isSmokeInstance else { return }
        guard isConnected, timer == nil else { return }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: Self.interval)
            }
        }
    }

    func stop() { timer?.cancel(); timer = nil }

    /// User action: read the CLI's sign-in (the Keychain prompt appears here, once) and start polling.
    func connect() async {
        UserDefaults.standard.set(true, forKey: Self.connectedKey)
        await refresh()
        if error == nil { start() } else { UserDefaults.standard.set(false, forKey: Self.connectedKey) }
    }

    func disconnect() {
        stop()
        UserDefaults.standard.set(false, forKey: Self.connectedKey)
        snapshot = nil
        error = nil
    }

    func refresh() async {
        guard isConnected else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            // Keychain access can block on a user prompt; never do it on the main thread.
            let creds = await Task.detached(priority: .utility) { Self.readCredentials() }.value
            guard let creds else { throw UsageError.noCredentials }
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

/// Sidebar footer. Collapsed it is a one-row snapshot — a chip per limit (ADR-085); expanded it is the
/// full set of bars with reset captions and credits (ADR-051).
struct UsagePanel: View {
    @Environment(UsageService.self) private var usage
    @AppStorage("ClinicUsageExpanded") private var expanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if expanded { expandedBody }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.bar)
    }

    /// The whole row is the disclosure control, so the snapshot is also the way back to the detail.
    private var header: some View {
        HStack(spacing: 6) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.caption2)
                    if expanded || bars.isEmpty { title } else { snapshotStrip }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(headerHelp)
            trailing
        }
    }

    private var title: some View {
        HStack(spacing: 4) {
            Text("Claude usage").font(.caption.weight(.semibold))
            if usage.isConnected, usage.error != nil, usage.snapshot == nil {
                Image(systemName: "exclamationmark.triangle.fill").font(.caption2).foregroundStyle(.orange)
            } else if let sub = usage.snapshot?.subscription, !sub.isEmpty {
                Text(sub.capitalized).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    /// As many chips as the sidebar's width allows, calmest dropped first (ADR-085). The candidates run
    /// widest-first because `ViewThatFits` takes the first that fits.
    private var snapshotStrip: some View {
        ViewThatFits(in: .horizontal) {
            ForEach(Array(stride(from: bars.count, through: 1, by: -1)), id: \.self) { n in
                HStack(spacing: 8) {
                    ForEach(usage.snapshot?.compactBars(limit: n) ?? []) { UsageChip(bar: $0) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var trailing: some View {
        if usage.isConnected {
            Button { Task { await usage.refresh() } } label: { Image(systemName: "arrow.clockwise").font(.caption2) }
                .buttonStyle(.plain).disabled(usage.isLoading).help("Refresh")
        } else if !expanded {
            Button("Connect") { expanded = true; Task { await usage.connect() } }.controlSize(.mini)
        }
    }

    @ViewBuilder private var expandedBody: some View {
        if !usage.isConnected {
            VStack(alignment: .leading, spacing: 6) {
                Text("Show your plan limits from Claude Code's sign-in. Clinic reads the token from your Keychain only after you connect; macOS will ask once.")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Connect Claude account") { Task { await usage.connect() } }.controlSize(.small)
                if let error = usage.error { Text(error).font(.caption2).foregroundStyle(.red).lineLimit(3) }
            }
        } else if let snap = usage.snapshot {
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

    private var bars: [UsageSnapshot.Bar] { usage.snapshot?.bars ?? [] }

    /// Collapsed, the row's own tooltip carries what the chips leave out: the plan, and how fresh they are.
    private var headerHelp: String {
        var parts = ["Claude usage"]
        if let sub = usage.snapshot?.subscription, !sub.isEmpty { parts.append(sub.capitalized) }
        if let error = usage.error { parts.append(error) }
        else if let at = usage.snapshot?.fetchedAt { parts.append("updated " + at.formatted(.relative(presentation: .named))) }
        return parts.joined(separator: " · ")
    }
}

/// One limit in the collapsed snapshot: short label, micro meter, percent. The meter always carries the
/// bar's tint, the number only when the limit is pressing; the reset time lives in the tooltip so the
/// row's height and width never move (ADR-085).
struct UsageChip: View {
    let bar: UsageSnapshot.Bar

    var body: some View {
        HStack(spacing: 3) {
            Text(bar.shortTitle).font(.caption2).foregroundStyle(.secondary)
            MicroMeter(fraction: Double(bar.percent) / 100, tint: bar.tint)
            // Three saturated numbers in a row read as three alarms. Only a limit that is actually
            // pressing colours its number; the rest stay in the sidebar's own ink.
            Text("\(bar.rawPercent)%").font(.caption2).monospacedDigit()
                .foregroundStyle(bar.isPressing ? AnyShapeStyle(bar.tint) : AnyShapeStyle(.secondary))
                .frame(minWidth: 24, alignment: .trailing)
        }
        .fixedSize()
        .help(help)
    }

    private var help: String {
        var s = "\(bar.title) · \(bar.rawPercent)%"
        if let r = bar.resetsAt { s += " · resets " + r.formatted(.relative(presentation: .named)) }
        return s
    }
}

/// A 24 × 4 pt capsule. The fill keeps a 3 pt minimum so a single percent still reads as "started".
struct MicroMeter: View {
    let fraction: Double
    let tint: Color
    var width: CGFloat = 24
    var height: CGFloat = 4

    var body: some View {
        Capsule().fill(.quaternary)
            .frame(width: width, height: height)
            .overlay(alignment: .leading) {
                Capsule().fill(tint)
                    .frame(width: fraction <= 0 ? 0 : max(3, width * min(1, fraction)), height: height)
            }
            .accessibilityHidden(true)
    }
}

struct UsageBarView: View {
    let bar: UsageSnapshot.Bar

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(bar.title).font(.caption2)
                Spacer()
                Text("\(bar.rawPercent)%").font(.caption2).monospacedDigit().foregroundStyle(bar.tint)
            }
            ProgressView(value: Double(bar.percent), total: 100).tint(bar.tint).controlSize(.small)
            if let r = bar.resetsAt {
                Text("Resets \(r, format: .relative(presentation: .named))").font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }
}

extension UsageSnapshot.Bar {
    /// Shared by the collapsed chip and the expanded bar, so one limit reads the same in both.
    var tint: Color {
        switch severity {
        case "exceeded": return .red
        case "warning": return .orange
        default: return percent >= 90 ? .orange : .accentColor
        }
    }

    /// Worth shouting about: the endpoint said so, or the bar is nearly full.
    var isPressing: Bool { severity == "exceeded" || severity == "warning" || percent >= 90 }
}
