import Foundation

/// Turns a round and its answers into the message Clinic pastes into the agent surface (ADR-131).
///
/// A pure function over a `GrillRound`, which is the point: the format the agent has to understand is
/// the one thing here that cannot be checked by looking at the screen, so it is checked by tests
/// instead (ADR-022).
public enum GrillAnswerComposer {

    /// The block the reader sends. Every question the agent asked appears exactly once, in the order it
    /// asked them, so a round can be read as a reply rather than matched up.
    ///
    /// An accepted recommendation is **echoed in full** rather than acknowledged. "Yes to Q2" makes the
    /// agent resolve which recommendation that was against a transcript it may have compacted away;
    /// quoting it back costs a line and removes the ambiguity.
    public static func compose(_ round: GrillRound) -> String {
        var lines = [header(round)]
        lines.append("")
        for question in round.questions {
            lines.append(line(for: question, answer: round.answers[question.id]))
        }
        return lines.joined(separator: "\n")
    }

    static func header(_ round: GrillRound) -> String {
        let what = round.index.map { "round \($0)" } ?? "your questions"
        guard let topic = round.topic?.trimmingCharacters(in: .whitespacesAndNewlines), !topic.isEmpty else {
            return "Answers to \(what):"
        }
        return "Answers to \(what) — \(topic):"
    }

    static func line(for question: GrillQuestion, answer: GrillAnswer?) -> String {
        let label = question.title.isEmpty ? question.id : "\(question.id) (\(question.title))"
        guard let answer, answer.isMeaningful else { return "\(label) — skipped, you decide." }

        switch answer {
        case .acceptedRecommendation:
            guard let rec = question.recommendation?.trimmingCharacters(in: .whitespacesAndNewlines), !rec.isEmpty else {
                // The pane does not offer accept without a recommendation; if one ever gets here, say
                // the thing that is still true rather than quoting an empty string.
                return "\(label) — agreed with you."
            }
            return "\(label) — accepted your recommendation: \(indented(sentence(rec)))"

        case .choices(let ids):
            let picked = ids.compactMap { id in question.choices.first { $0.id == id } }
            guard !picked.isEmpty else { return "\(label) — skipped, you decide." }
            return "\(label) — chose: \(indented(sentence(picked.map(\.label).joined(separator: "; "))))"

        case .text(let text):
            return "\(label) — my answer: \(indented(text.trimmingCharacters(in: .whitespacesAndNewlines)))"

        case .skipped:
            return "\(label) — skipped, you decide."
        }
    }

    /// The round and what the reader said about it, as a Markdown document.
    ///
    /// A grill exists to produce an ADR, so the round it settled is the raw material for one. Pure, and
    /// therefore checkable, for the same reason `compose` is.
    public static func markdown(_ round: GrillRound) -> String {
        var out: [String] = []
        let number = round.index.map { "Round \($0)" } ?? "Questions"
        out.append("# " + [number, round.topic].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " — "))
        for question in round.questions {
            out.append("")
            out.append("## " + (question.title.isEmpty ? question.id : "\(question.id) — \(question.title)"))
            if !question.body.isEmpty { out.append(question.body) }
            if let rec = question.recommendation { out.append("**Recommended:** \(rec)") }
            for choice in question.choices {
                out.append("- \(choice.label)" + (choice.recommended ? " _(recommended)_" : ""))
            }
            out.append("**Answer:** " + answerPhrase(for: question, answer: round.answers[question.id]))
        }
        return out.joined(separator: "\n")
    }

    /// The answer alone, without the `Q1 (title) — ` that `line` puts in front of it for the agent.
    /// The review step shows this beside each question, so it is the same words the agent will read.
    public static func answerPhrase(for question: GrillQuestion, answer: GrillAnswer?) -> String {
        let full = line(for: question, answer: answer)
        let label = question.title.isEmpty ? question.id : "\(question.id) (\(question.title))"
        let prefix = "\(label) — "
        return full.hasPrefix(prefix) ? String(full.dropFirst(prefix.count)) : full
    }

    /// Ends a clause with a full stop unless it already ends with punctuation, so the block reads as
    /// prose whether or not the agent's recommendation was written as a sentence.
    private static func sentence(_ text: String) -> String {
        guard let last = text.last else { return text }
        return ".!?:;,".contains(last) ? text : text + "."
    }

    /// Indents the continuation lines of a multi-line answer by two spaces, so a reader who writes a
    /// paragraph beginning "Q3 is wrong because…" cannot produce a line that looks like another
    /// question's answer.
    private static func indented(_ text: String) -> String {
        let parts = text.components(separatedBy: "\n")
        guard parts.count > 1 else { return text }
        return ([parts[0]] + parts.dropFirst().map { "  " + $0 }).joined(separator: "\n")
    }
}
