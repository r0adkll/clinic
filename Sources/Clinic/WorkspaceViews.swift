import AppKit
import SwiftUI
import ClinicCore

// MARK: - Tab pieces shared by the strips (ADR-212)

/// A pane's glyph in a strip: a PR's service glyph with its state, a run's status, else its symbol.
struct PaneGlyph: View {
    @Environment(TabStore.self) private var tabs
    let tab: Tab
    let pane: PanelPane
    let compact: Bool

    var body: some View {
        if case .pr(let ref) = pane.kind {
            PRTabGlyph(ref: ref, size: pane.kind.glyphSize(compact: compact))
        } else if case .run(let key) = pane.kind {
            RunStatusGlyph(run: tabs.runs.run(forKey: key), idleSymbol: "play.fill", size: pane.kind.glyphSize(compact: compact) + 1)
        } else {
            Image(systemName: pane.kind.symbol).font(.system(size: pane.kind.glyphSize(compact: compact)))
        }
    }
}

// MARK: - The session header (ADR-212)

/// The toolbar's leading item: what the window is showing. For a session, its project's icon, its title
/// over its project's name, its state, and a ⋯ menu for the verbs the session tab's ✕ and menu used to hold
/// (ADR-212). Model, effort, directory and context stay in the footer (ADR-216).
struct WorkspaceHeader: View {
    @Environment(TabStore.self) private var tabs
    /// Passed in: toolbar content sits outside the `.environment(window)` the window's views get.
    let window: WindowState

    var body: some View {
        if let screen = window.screen {
            Text(screen.title).font(.headline)
        } else if window.editingDraft != nil {
            Text("New session").font(.headline)
        } else if let tab = tabs.selectedTab(in: window) {
            SessionHeader(tab: tab)
        }
    }
}

struct SessionHeader: View {
    @Environment(TabStore.self) private var tabs
    @Environment(SessionStore.self) private var sessions
    let tab: Tab

    var body: some View {
        HStack(spacing: 10) {
            ProjectIcon(project: Project(path: tab.projectPath), size: 26)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(tab.title).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.tail)
                    StatePill(tab: tab)
                }
                meta
            }
            // A toolbar item is as wide as it asks to be, and the controls after it overflow into a »
            // menu rather than squeeze it: the cap is what lets a long title truncate instead.
            .frame(maxWidth: 290, alignment: .leading)
            menu
        }
        .padding(.horizontal, 4)
    }

    /// The project's name under the title. Model, effort, directory and context are the footer's (ADR-216).
    private var meta: some View {
        Text(Project(path: tab.projectPath).name)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    private var menu: some View {
        Menu {
            Button("Close Session…") { tabs.close(tab) }
            if let id = tab.sessionId, let summary = sessions.sessions[id] {
                Button("Archive") { SessionActions.archive(summary, sessions: sessions, tabs: tabs) }
                Divider()
                Button("Details…") { NotificationCenter.default.post(name: .clinicSessionDetails, object: id.rawValue) }
            }
            Divider()
            MoveToWindowMenu(tab: tab)
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Close, archive, move or show details of this session")
    }

}

/// The session's state in words, coloured only for what wants the reader (ADR-096's palette).
struct StatePill: View {
    let tab: Tab

    var body: some View {
        if let label {
            let tint = label.1
            Text(label.0)
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(tint.opacity(0.18), in: Capsule())
                .foregroundStyle(tint)
        }
    }

    private var label: (String, Color)? {
        if tab.isReplay { return ("Replay", .secondary) }
        switch tab.state {
        case .launching: return ("Starting", .secondary)
        case .working: return ("Working", .secondary)
        case .waitingForPermission, .waitingForInput: return ("Needs you", .orange)
        case .idle: return tab.unread ? ("Finished", .blue) : ("Idle", .secondary)
        case .exited: return ("Exited", .secondary)
        case nil: return nil
        }
    }
}

// MARK: - The footer's context meter (ADR-217)

/// How full the session's context window is, at the footer's trailing end: a bar, the percentage and the
/// tokens, all from the CLI's status line (ADR-157). Hovering opens a card with what the CLI says about it.
struct ContextMeter: View {
    let report: StatusLineReport
    @State private var hovering = false
    @State private var showsCard = false
    @State private var opening: Task<Void, Never>?

    private var percent: Double { max(0, min(100, report.contextUsedPercentage ?? 0)) }

    var body: some View {
        HStack(spacing: 6) {
            ContextBar(percent: percent, width: 64, height: 6)
            Text("\(Int(percent.rounded(.down)))%").monospacedDigit().foregroundStyle(ContextBar.tint(percent).opacity(percent >= 90 ? 1 : 0.9))
            if let used = report.contextTokens, let size = report.contextWindowSize {
                Text("\(TokenCount.short(used)) / \(TokenCount.short(size))").monospacedDigit().foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 6).frame(height: 24)
        .background(hovering ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onHover { inside in
            hovering = inside
            opening?.cancel()
            if inside {
                // A short wait, as a tooltip has, so passing the pointer over the footer opens nothing.
                opening = Task { try? await Task.sleep(for: .milliseconds(350)); if !Task.isCancelled { showsCard = true } }
            } else {
                showsCard = false
            }
        }
        .onTapGesture { showsCard.toggle() }
        .popover(isPresented: $showsCard, arrowEdge: .top) { ContextCard(report: report) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Context \(Int(percent))% used")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default) { showsCard.toggle() }
    }
}

/// The context bar: secondary until the window is nearly full, orange from 90 %, where Clinic also voices
/// the limit (ADR-203).
struct ContextBar: View {
    let percent: Double
    var width: CGFloat
    var height: CGFloat

    static func tint(_ percent: Double) -> Color { percent >= 90 ? .orange : .secondary }

    var body: some View {
        Capsule().fill(.quaternary)
            .frame(width: width, height: height)
            .overlay(alignment: .leading) {
                Capsule().fill(Self.tint(percent)).frame(width: max(height, width * percent / 100), height: height)
            }
    }
}

/// What the CLI reports about the session's context and cost. It does not report what fills the context
/// (system prompt, tools, memory files, messages); `/context` shows that in the terminal, and the card says so.
private struct ContextCard: View {
    let report: StatusLineReport

    private var percent: Double { max(0, min(100, report.contextUsedPercentage ?? 0)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Context").font(.headline)
                    Spacer()
                    Text("\(Int(percent.rounded(.down)))% used").monospacedDigit().foregroundStyle(ContextBar.tint(percent))
                }
                ContextBar(percent: percent, width: 248, height: 8)
                if let used = report.contextTokens, let size = report.contextWindowSize {
                    Text("\(TokenCount.short(used)) of \(TokenCount.short(size)) tokens · \(TokenCount.short(max(0, size - used))) left")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            if let last = report.lastRequest {
                section("Last request") {
                    row("Read from cache", TokenCount.short(last.cacheRead))
                    row("Written to cache", TokenCount.short(last.cacheWrite))
                    row("New input", TokenCount.short(last.input))
                    row("Reply", TokenCount.short(last.output))
                }
            }
            if let cost = report.cost {
                section("This session") {
                    if let usd = cost.usd { row("Cost", usd.formatted(.currency(code: "USD"))) }
                    if let ms = cost.durationMs {
                        row("Time", Self.duration(ms) + (cost.apiDurationMs.map { " · \(Self.duration($0)) in the API" } ?? ""))
                    }
                    if let added = cost.linesAdded, let removed = cost.linesRemoved { row("Lines", "+\(added)  −\(removed)") }
                }
            }
            Text("What fills the context — system prompt, tools, memory files, messages — isn't reported to Clinic. Type /context in the session to see it.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 276)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).monospacedDigit().foregroundStyle(.secondary)
        }
        .font(.callout)
    }

    static func duration(_ ms: Int) -> String {
        let s = ms / 1000
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        return "\(s / 3600)h \((s % 3600) / 60)m"
    }
}

/// "68.2k", "1.1M", "200": tokens the way the CLI writes them.
enum TokenCount {
    static func short(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: n % 1_000_000 == 0 ? "%.0fM" : "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: n % 1_000 == 0 ? "%.0fk" : "%.1fk", Double(n) / 1_000) }
        return "\(n)"
    }
}

