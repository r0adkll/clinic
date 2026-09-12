import Foundation

/// Why a round the agent posted could not be read. The message goes straight back as the tool's error
/// text, so it is written for the agent to act on rather than for a log.
public struct GrillArgumentError: LocalizedError, Equatable {
    public let message: String
    public var errorDescription: String? { message }
    public init(_ message: String) { self.message = message }
}

extension GrillRound {
    /// Builds a round from `ask_round`'s arguments (ADR-131).
    ///
    /// Deliberately tolerant about *shape* and strict about *substance*. The schema says
    /// `questions[{id,title,body,recommendation,choices,allowsMultiple}]`, but a model that writes
    /// `question` for the title, `choices: ["a","b"]` instead of objects, or a lone question object
    /// instead of an array has still said something unambiguous — accepting those costs a few lines
    /// here and saves a round the reader would otherwise never see. What is *not* tolerated is a round
    /// with no answerable question in it, because posting an empty pane is worse than an error the
    /// agent can read and retry.
    public static func from(arguments args: [String: Any], now: Date = Date(),
                            source: Source = .tool) throws -> GrillRound {
        let rawQuestions: [[String: Any]]
        switch args["questions"] {
        case let list as [[String: Any]]: rawQuestions = list
        case let single as [String: Any]: rawQuestions = [single]          // one question, unwrapped
        case let strings as [String]: rawQuestions = strings.map { ["title": $0] }
        default:
            throw GrillArgumentError("questions is required: an array of {id, title, body, recommendation, choices, allowsMultiple}.")
        }

        var questions: [GrillQuestion] = []
        var seen = Set<String>()
        for (i, raw) in rawQuestions.enumerated() {
            let title = string(raw, "title", "question", "summary", "headline") ?? ""
            let body = string(raw, "body", "detail", "details", "description", "text") ?? ""
            guard !title.isEmpty || !body.isEmpty else { continue }

            // `id` is what the answer block names, so it has to be unique even if the agent repeats one.
            var id = string(raw, "id", "label", "key") ?? ""
            if id.isEmpty || seen.contains(id) { id = "Q\(i + 1)" }
            var unique = id
            var bump = 2
            while seen.contains(unique) { unique = "\(id).\(bump)"; bump += 1 }
            seen.insert(unique)

            questions.append(GrillQuestion(
                id: unique,
                title: title,
                body: body,
                recommendation: string(raw, "recommendation", "recommended", "recommendedAnswer", "recommended_answer", "suggestion"),
                choices: choices(from: raw["choices"] ?? raw["options"]),
                allowsMultiple: bool(raw, "allowsMultiple", "allows_multiple", "multiple", "multiSelect", "multi_select") ?? false
            ))
        }

        guard !questions.isEmpty else {
            throw GrillArgumentError("Every question was empty: each needs a title or a body.")
        }

        return GrillRound(
            index: int(args, "roundIndex", "round_index", "round", "index"),
            topic: string(args, "topic", "subject", "about"),
            questions: questions,
            postedAt: now,
            source: source
        )
    }

    /// Choices as objects, as plain strings, or absent. A recommended flag that arrives as the string
    /// "true" counts, because JSON from a model is not always typed the way the schema asked.
    private static func choices(from value: Any?) -> [GrillChoice] {
        var out: [GrillChoice] = []
        var seen = Set<String>()
        let raws: [Any]
        switch value {
        case let list as [Any]: raws = list
        default: return []
        }
        for (i, raw) in raws.enumerated() {
            var id: String
            var label: String
            var detail: String?
            var recommended = false
            if let s = raw as? String {
                id = "\(i + 1)"
                label = s.trimmingCharacters(in: .whitespacesAndNewlines)
            } else if let obj = raw as? [String: Any] {
                label = string(obj, "label", "title", "text", "name", "value") ?? ""
                detail = string(obj, "detail", "description", "body")
                recommended = bool(obj, "recommended", "isRecommended", "is_recommended", "default") ?? false
                id = string(obj, "id", "key") ?? "\(i + 1)"
            } else {
                continue
            }
            guard !label.isEmpty else { continue }
            if seen.contains(id) { id = "\(i + 1)" }
            var unique = id
            var bump = 2
            while seen.contains(unique) { unique = "\(id).\(bump)"; bump += 1 }
            seen.insert(unique)
            out.append(GrillChoice(id: unique, label: label, detail: detail, recommended: recommended))
        }
        // Only one choice can be the recommended one; the accent treatment means nothing if two wear it.
        if let first = out.firstIndex(where: \.recommended) {
            for i in out.indices where i != first { out[i].recommended = false }
        }
        return out
    }

    // MARK: Reading whatever the model actually sent

    private static func string(_ obj: [String: Any], _ keys: String...) -> String? {
        for key in keys {
            guard let raw = obj[key] else { continue }
            let text: String?
            switch raw {
            case let s as String: text = s
            case let n as NSNumber: text = n.stringValue
            default: text = nil
            }
            if let t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { return t }
        }
        return nil
    }

    private static func int(_ obj: [String: Any], _ keys: String...) -> Int? {
        for key in keys {
            switch obj[key] {
            case let n as Int: return n
            case let n as NSNumber: return n.intValue
            case let s as String: if let n = Int(s.trimmingCharacters(in: .whitespaces)) { return n }
            default: continue
            }
        }
        return nil
    }

    private static func bool(_ obj: [String: Any], _ keys: String...) -> Bool? {
        for key in keys {
            switch obj[key] {
            case let b as Bool: return b
            case let n as NSNumber: return n.boolValue
            case let s as String:
                switch s.lowercased() {
                case "true", "yes", "1": return true
                case "false", "no", "0": return false
                default: continue
                }
            default: continue
            }
        }
        return nil
    }
}
