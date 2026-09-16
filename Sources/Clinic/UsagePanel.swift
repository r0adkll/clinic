import SwiftUI
import os
import ClinicCore

/// Plan usage for the sidebar (ADR-051, ADR-162). The 5-hour and 7-day windows arrive live from every Clinic
/// session's status line and need no sign-in; once the user connects (ADR-070), a poll of the usage endpoint
/// every 15 minutes adds the per-model weekly limits and extra usage that only the endpoint knows.
@MainActor
@Observable
final class UsageService {
    private static let log = Logger(subsystem: "com.r0adkll.clinic", category: "usage")
    /// The last endpoint response.
    private(set) var fetched: UsageSnapshot?
    /// The newest windows the status line reported, from any session.
    private(set) var live = LiveRateLimits()
    /// What the panel draws: the fetch with the live windows over it.
    var snapshot: UsageSnapshot? { UsageSnapshot.combining(fetched, live: live) }
    private(set) var error: String?
    private(set) var isLoading = false
    private var timer: Task<Void, Never>?
    /// Held until it expires, so a poll reads the Keychain once per token rather than once per poll.
    @ObservationIgnored private var credentials: ClaudeCredentials?
    /// The live windows cover what changes fastest, so the endpoint is asked only for the rest (ADR-162).
    static let interval: Duration = .seconds(900)

    /// The user has explicitly connected their Claude account (ADR-070). Nothing touches the Keychain before this.
    static let connectedKey = "ClinicUsageConnected"
    var isConnected: Bool { UserDefaults.standard.bool(forKey: Self.connectedKey) }

    /// Starts polling only if the user connected earlier.
    ///
    /// Never in a smoke instance. `CLINIC_APP_SUPPORT` does not isolate `UserDefaults`, so a smoke run
    /// inherits the real app's consent and would poll the real account on launch. Connecting by hand still
    /// works if a run actually needs usage.
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

    /// User action: read the CLI's sign-in and start polling.
    func connect() async {
        UserDefaults.standard.set(true, forKey: Self.connectedKey)
        await refresh()
        if error == nil { start() } else { UserDefaults.standard.set(false, forKey: Self.connectedKey) }
    }

    /// Forgets the fetch and the token. The live windows stay: they never needed the connection.
    func disconnect() {
        stop()
        UserDefaults.standard.set(false, forKey: Self.connectedKey)
        fetched = nil
        credentials = nil
        error = nil
    }

    /// A status line report from any session; most carry the same windows as the last.
    func absorb(_ report: StatusLineReport, at: Date) {
        var next = live
        if next.absorb(report, at: at) { live = next }
    }

    func refresh() async {
        guard isConnected else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            do {
                fetched = try await UsageClient.fetch(credentials: currentCredentials(reread: false))
            } catch UsageError.expired, UsageError.http(401, _) {
                // The CLI refreshes the token when it next uses it; the held copy may simply be older than the Keychain's.
                fetched = try await UsageClient.fetch(credentials: currentCredentials(reread: true))
            }
            error = nil
        } catch {
            self.error = "\(error)"
            Self.log.warning("usage: \(error, privacy: .public)")
        }
    }

    private func currentCredentials(reread: Bool) async throws -> ClaudeCredentials {
        if !reread, let credentials, !credentials.isExpired { return credentials }
        credentials = await Task.detached(priority: .utility) { Self.readCredentials() }.value
        guard let credentials else { throw UsageError.noCredentials }
        return credentials
    }

    /// Keychain generic password `Claude Code-credentials`; falls back to the credentials file (Linux-style layout).
    nonisolated static func readCredentials() -> ClaudeCredentials? {
        if let data = keychainItem(), let c = ClaudeCredentials.parse(data) { return c }
        let file = ClaudePaths().configDirectory.appendingPathComponent(".credentials.json")
        if let data = try? Data(contentsOf: file) { return ClaudeCredentials.parse(data) }
        return nil
    }

    /// Read through `/usr/bin/security`, not `SecItemCopyMatching` (ADR-162). The CLI writes the item with
    /// `security`, so the item trusts that binary and the read never prompts. Asked for as Clinic, macOS
    /// prompted again whenever the "Always Allow" it had granted stopped matching: after a rebuild, from a
    /// build at another path, and with the CLI rewriting the item on every token refresh.
    nonisolated static func keychainItem() -> Data? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? data : nil
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
                // The status line's windows need no sign-in, so they show before any connection (ADR-162).
                ForEach(bars) { bar in UsageBarView(bar: bar) }
                Text(bars.isEmpty
                     ? "Your 5-hour and weekly limits appear here once a session has talked to Claude. Connect to add per-model limits and extra usage from Claude Code's sign-in."
                     : "Connect to add per-model limits and extra usage from Claude Code's sign-in.")
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
            Text("Updated \(snap.updatedAt, format: .relative(presentation: .named))").font(.caption2).foregroundStyle(.tertiary)
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
        else if let at = usage.snapshot?.updatedAt { parts.append("updated " + at.formatted(.relative(presentation: .named))) }
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
    @MainActor var tint: Color {
        switch severity {
        case "exceeded": return .red
        case "warning": return .orange
        default: return percent >= 90 ? .orange : .accent
        }
    }

    /// Worth shouting about: the endpoint said so, or the bar is nearly full.
    var isPressing: Bool { severity == "exceeded" || severity == "warning" || percent >= 90 }
}
