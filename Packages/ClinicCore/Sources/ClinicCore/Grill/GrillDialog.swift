import Foundation

/// One question of Claude Code's own `AskUserQuestion` tool, as the session mod forwards the tool's
/// input (ADR-179). Tolerant: a field the CLI drops or adds does not lose the round.
public struct AskedQuestion: Codable, Sendable, Hashable {
    /// The complete question. Also the key the tool's result names the answer by.
    public var question: String
    /// A short chip, at most twelve characters ("Auth method").
    public var header: String?
    /// One helper line under the question.
    public var description: String?
    /// `choice` (the default), `text` or `number`.
    public var kind: String?
    public var options: [Option]
    public var multiSelect: Bool

    public struct Option: Codable, Sendable, Hashable {
        public var label: String
        public var description: String?

        public init(label: String, description: String? = nil) { self.label = label; self.description = description }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            label = (try? c.decodeIfPresent(String.self, forKey: .label)) ?? ""
            description = try? c.decodeIfPresent(String.self, forKey: .description)
        }
    }

    public init(question: String, header: String? = nil, description: String? = nil, kind: String? = nil,
                options: [Option] = [], multiSelect: Bool = false) {
        self.question = question; self.header = header; self.description = description; self.kind = kind
        self.options = options; self.multiSelect = multiSelect
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        question = (try? c.decodeIfPresent(String.self, forKey: .question)) ?? ""
        header = try? c.decodeIfPresent(String.self, forKey: .header)
        description = try? c.decodeIfPresent(String.self, forKey: .description)
        kind = try? c.decodeIfPresent(String.self, forKey: .kind)
        options = (try? c.decodeIfPresent([Option].self, forKey: .options)) ?? []
        multiSelect = (try? c.decodeIfPresent(Bool.self, forKey: .multiSelect)) ?? false
    }
}

extension GrillRound {
    /// The marker Claude Code's own guidance puts on the option it would pick.
    static let recommendedMarker = "(Recommended)"

    /// A round from the `AskUserQuestion` dialog (ADR-179), so the reader can answer it as a form.
    ///
    /// The question's text becomes the title, because it is what the tool's result is keyed by and what
    /// the reader has to see whole; the helper line becomes the body. An option labelled
    /// `… (Recommended)` is the recommended choice, which gives `⏎` something to accept. Nil when no
    /// question has any text.
    public static func from(asked: [AskedQuestion], toolUseId: String, now: Date = Date()) -> GrillRound? {
        var questions: [GrillQuestion] = []
        for (i, q) in asked.enumerated() {
            let title = q.question.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }
            var seen = Set<String>()
            var choices: [GrillChoice] = []
            for (j, option) in q.options.enumerated() {
                let label = option.label.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !label.isEmpty, seen.insert(label).inserted else { continue }
                let detail = option.description?.trimmingCharacters(in: .whitespacesAndNewlines)
                choices.append(GrillChoice(id: "\(j + 1)", label: label, detail: detail?.isEmpty == false ? detail : nil,
                                           recommended: label.range(of: recommendedMarker, options: .caseInsensitive) != nil))
            }
            if let first = choices.firstIndex(where: \.recommended) {
                for k in choices.indices where k != first { choices[k].recommended = false }
            }
            let recommendation = choices.first(where: \.recommended).map { choice in
                choice.label.replacingOccurrences(of: recommendedMarker, with: "", options: .caseInsensitive)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            questions.append(GrillQuestion(id: "Q\(i + 1)", title: title,
                                           body: q.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                                           recommendation: recommendation?.isEmpty == false ? recommendation : nil,
                                           choices: choices, allowsMultiple: q.multiSelect))
        }
        guard !questions.isEmpty else { return nil }
        var round = GrillRound(questions: questions, postedAt: now, source: .dialog)
        round.toolUseId = toolUseId
        return round
    }

    /// What the reader answered, in the shape the tool's result wants: the question's text to the
    /// chosen label, several labels comma-joined, or the reader's own words (ADR-179).
    ///
    /// Every question is answered, because the dialog has no skip: one the reader passed over says so
    /// in words the agent can act on.
    public var dialogAnswers: [String: String] {
        var out: [String: String] = [:]
        for question in questions {
            out[question.title] = Self.dialogAnswer(for: question, answer: answers[question.id])
        }
        return out
    }

    static let dialogSkipped = "No preference. You decide."

    static func dialogAnswer(for question: GrillQuestion, answer: GrillAnswer?) -> String {
        guard let answer, answer.isMeaningful else { return dialogSkipped }
        switch answer {
        case .acceptedRecommendation:
            // The option's own label, marker and all: it is what the dialog itself would have returned.
            return question.recommendedChoice?.label ?? question.recommendation ?? dialogSkipped
        case .choices(let ids):
            let labels = ids.compactMap { id in question.choices.first { $0.id == id }?.label }
            return labels.isEmpty ? dialogSkipped : labels.joined(separator: ", ")
        case .text(let text):
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        case .skipped:
            return dialogSkipped
        }
    }

    /// Folds in what the terminal dialog was answered with, so the pane's copy reads as a record.
    /// A label the round offered becomes that choice; anything else is kept as the reader's words.
    public mutating func record(dialogAnswers given: [String: String]) {
        for question in questions {
            guard let value = given[question.title]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { continue }
            if let choice = question.choices.first(where: { $0.label == value }) {
                answers[question.id] = .choices([choice.id])
            } else {
                answers[question.id] = .text(value)
            }
        }
    }
}

/// Holds what the Grill pane and the session mod have for each other while a dialog is open (ADR-179).
///
/// The mod waits on `GET /answer?id=<tool_use_id>`. The pane, some minutes later, has answers. Either
/// can arrive first, the poll is re-made every time the server lets it go, and both sides are on
/// different threads, so this is the one place that pairs them.
public final class AskBroker: @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: [String: HookPoll] = [:]
    private var answers: [String: Data] = [:]
    /// Rounds that are over: answered here and delivered, answered in the terminal, or discarded.
    private var closed: Set<String> = []

    public init() {}

    /// The mod is waiting for this dialog's answers.
    public func poll(id: String, _ poll: HookPoll) {
        lock.lock(); defer { lock.unlock() }
        if closed.contains(id) { poll.respond(status: 410); return }
        if let answer = answers[id] {
            if poll.respond(status: 200, body: answer) { answers[id] = nil; closed.insert(id) }
            return
        }
        // One waiter per dialog: an earlier one the mod abandoned is let go.
        waiting[id]?.respond(status: 204)
        waiting[id] = poll
    }

    /// The reader sent answers from the pane. Delivered now if the mod is waiting, otherwise kept for
    /// its next poll, which is at most one request away.
    public func answer(id: String, with answers: [String: String]) {
        guard let body = try? JSONSerialization.data(withJSONObject: ["answers": answers]) else { return }
        lock.lock(); defer { lock.unlock() }
        guard !closed.contains(id) else { return }
        if let poll = waiting.removeValue(forKey: id), poll.respond(status: 200, body: body) {
            closed.insert(id)
        } else {
            self.answers[id] = body
        }
    }

    /// The dialog ended some other way: answered or dismissed in the terminal, or discarded in the pane.
    public func close(id: String) {
        lock.lock(); defer { lock.unlock() }
        closed.insert(id)
        answers[id] = nil
        waiting.removeValue(forKey: id)?.respond(status: 410)
    }

    /// Whether answers are held for a poll that has not come yet.
    public func hasUndelivered(id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return answers[id] != nil
    }
}
