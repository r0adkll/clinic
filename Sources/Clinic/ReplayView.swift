import SwiftUI
import ClinicCore

/// A past transcript as chat bubbles with Step / Play (ADR-059). Lives in a replay tab with no surface.
@MainActor
@Observable
final class ReplayModel {
    let sessionId: SessionID
    let transcriptPath: String
    private(set) var turns: [TranscriptTurns.Turn] = []
    private(set) var stats = TranscriptTurns.Stats()
    private(set) var error: String?
    private(set) var isLoading = true
    var revealed = 0
    var playing = false
    private var playTask: Task<Void, Never>?

    init(sessionId: SessionID, transcriptPath: String) {
        self.sessionId = sessionId; self.transcriptPath = transcriptPath
        Task { await load() }
    }

    func load() async {
        let path = transcriptPath
        let result = await Task.detached(priority: .userInitiated) { () -> Result<TranscriptTurns.Result, Error> in
            do { return .success(try TranscriptTurns.read(fileAt: path)) } catch { return .failure(error) }
        }.value
        switch result {
        case .success(let r): turns = r.turns; stats = r.stats; revealed = min(1, r.turns.count)
        case .failure(let e): error = "\(e)"
        }
        isLoading = false
    }

    func step() { if revealed < turns.count { revealed += 1 } else { stop() } }
    func showAll() { stop(); revealed = turns.count }
    func restart() { stop(); revealed = min(1, turns.count) }

    func togglePlay() { playing ? stop() : play() }

    private func play() {
        playing = true
        playTask = Task { [weak self] in
            while let self, self.playing, self.revealed < self.turns.count {
                try? await Task.sleep(for: .milliseconds(700))
                guard !Task.isCancelled else { return }
                self.revealed += 1
            }
            self?.playing = false
        }
    }

    func stop() { playing = false; playTask?.cancel(); playTask = nil }
}

struct ReplayView: View {
    @Bindable var model: ReplayModel

    var body: some View {
        VStack(spacing: 0) {
            if model.isLoading {
                ProgressView("Reading transcript…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = model.error {
                ContentUnavailableView("Cannot replay", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if model.turns.isEmpty {
                ContentUnavailableView("Nothing to replay", systemImage: "bubble.left.and.bubble.right", description: Text("This transcript has no conversation turns."))
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(Array(model.turns.prefix(model.revealed).enumerated()), id: \.offset) { i, turn in
                                TurnBubble(turn: turn).id(i)
                            }
                        }
                        .padding(16)
                        .frame(maxWidth: 900)
                        .frame(maxWidth: .infinity)
                    }
                    .onChange(of: model.revealed) { withAnimation { proxy.scrollTo(max(model.revealed - 1, 0), anchor: .bottom) } }
                }
            }
            Divider()
            HStack(spacing: 10) {
                Button { model.restart() } label: { Image(systemName: "backward.end") }.help("Restart")
                Button { model.togglePlay() } label: { Image(systemName: model.playing ? "pause.fill" : "play.fill") }.help("Play / pause")
                Button("Step") { model.step() }.keyboardShortcut(.rightArrow, modifiers: []).disabled(model.revealed >= model.turns.count)
                Button("Show all") { model.showAll() }.disabled(model.revealed >= model.turns.count)
                Spacer()
                Text("\(model.revealed) / \(model.turns.count) turns").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                if let d = model.stats.duration { Text(Self.duration(d)).font(.caption).foregroundStyle(.tertiary) }
            }
            .controlSize(.small)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(.bar)
        }
    }

    static func duration(_ t: TimeInterval) -> String {
        let f = DateComponentsFormatter(); f.allowedUnits = t > 3600 ? [.hour, .minute] : [.minute, .second]; f.unitsStyle = .abbreviated
        return f.string(from: t) ?? ""
    }
}

struct TurnBubble: View {
    let turn: TranscriptTurns.Turn
    @State private var expanded = false

    var body: some View {
        switch turn {
        case .user(let text, let date):
            HStack { Spacer(minLength: 80)
                VStack(alignment: .trailing, spacing: 3) {
                    Text(text).textSelection(.enabled).padding(10).background(Color.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 10))
                    if let date { Text(date, format: .dateTime.hour().minute().second()).font(.caption2).foregroundStyle(.tertiary) }
                }
            }
        case .assistant(let text, _):
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "sparkle").foregroundStyle(.secondary).padding(.top, 12)
                MarkdownText(text).padding(10).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                Spacer(minLength: 80)
            }
        case .toolUse(let name, let summary, _, _):
            HStack(spacing: 8) {
                Image(systemName: "wrench").font(.caption).foregroundStyle(.secondary)
                Text(name).font(.system(.caption, design: .monospaced).weight(.semibold))
                Text(summary).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                Spacer()
            }
            .padding(.leading, 28)
        case .toolResult(let summary, let isError, _, _):
            if !summary.isEmpty {
                DisclosureGroup(isExpanded: $expanded) {
                    Text(summary).font(.system(.caption, design: .monospaced)).textSelection(.enabled).padding(6)
                        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: isError ? "xmark.circle" : "arrow.turn.down.right").font(.caption).foregroundStyle(isError ? .red : .secondary)
                        Text(summary.split(whereSeparator: \.isNewline).first.map(String.init) ?? "").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .padding(.leading, 28)
            }
        }
    }
}
