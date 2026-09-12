import Foundation

/// One round of an interview the agent posted with `ask_round` (ADR-131): the whole frontier of the
/// design tree it can ask right now, each question carrying the agent's own recommended answer.
///
/// A round is a record, not a live object: the pane reads it, the reader answers it, and
/// `GrillAnswerComposer` turns round-plus-answers into the message that goes back to the agent.
public struct GrillRound: Codable, Sendable, Equatable, Identifiable {
    /// How many rounds Clinic keeps per session. A grill is four to six rounds; the cap is only here so
    /// that a session someone grills all day cannot grow the state file without bound (ADR-021).
    public static let maxPerSession = 20

    public var id: UUID
    /// The round's number as the agent gave it, for the header. Absent when it did not say.
    public var index: Int?
    /// What is being grilled, for the header. Absent when the agent did not say.
    public var topic: String?
    public var questions: [GrillQuestion]
    /// Answers so far, keyed by `GrillQuestion.id`. A question missing here is unanswered.
    public var answers: [String: GrillAnswer]
    public var postedAt: Date
    public var source: Source
    public var outcome: Outcome

    /// Where the round came from. A parsed round carries no structured choices, so the pane can say
    /// why a question that read like multiple choice does not offer any.
    public enum Source: String, Codable, Sendable {
        /// The agent called `ask_round`.
        case tool
        /// Clinic recognised the `grilling` skill's format in the transcript (ADR-131's safety net).
        case transcript
    }

    public enum Outcome: Codable, Sendable, Equatable {
        /// Waiting for the reader.
        case open
        /// The reader sent their answers from the pane.
        case sent(Date)
        /// The reader answered in the terminal instead, so the pane's copy is history, not a task.
        case answeredElsewhere(Date)
        /// The agent posted another round without waiting for this one. Keeping both open would leave
        /// the pane with two footers' worth of work and no way to say which Send meant which round, so
        /// the older one steps aside — its questions stay readable, they just stop being a task.
        case superseded(Date)
    }

    public init(id: UUID = UUID(), index: Int? = nil, topic: String? = nil,
                questions: [GrillQuestion], answers: [String: GrillAnswer] = [:],
                postedAt: Date = Date(), source: Source = .tool, outcome: Outcome = .open) {
        self.id = id
        self.index = index
        self.topic = topic
        self.questions = questions
        self.answers = answers
        self.postedAt = postedAt
        self.source = source
        self.outcome = outcome
    }

    public var isOpen: Bool { outcome == .open }

    /// Questions the reader has given an answer to — a skip counts, because skipping is a decision.
    public var answeredCount: Int { questions.filter { answers[$0.id] != nil }.count }

    public var isFullyAnswered: Bool { answeredCount == questions.count }

    public func answer(for question: GrillQuestion) -> GrillAnswer? { answers[question.id] }

    /// Fills every *unanswered* question that has a recommendation — the pane's "Accept all
    /// recommendations". Questions the reader has already answered are left alone, so this is safe to
    /// press halfway through a round.
    public mutating func acceptAllRecommendations() {
        for q in questions where answers[q.id] == nil && q.recommendation != nil {
            answers[q.id] = .acceptedRecommendation
        }
    }

    /// Tolerant decoding: a round whose shape changed between builds is dropped rather than taking the
    /// whole state file with it, the way `ClinicState` treats automations.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        index = try? c.decodeIfPresent(Int.self, forKey: .index)
        topic = try? c.decodeIfPresent(String.self, forKey: .topic)
        questions = try c.decode([GrillQuestion].self, forKey: .questions)
        answers = (try? c.decodeIfPresent([String: GrillAnswer].self, forKey: .answers)) ?? [:]
        postedAt = (try? c.decodeIfPresent(Date.self, forKey: .postedAt)) ?? Date()
        source = (try? c.decodeIfPresent(Source.self, forKey: .source)) ?? .tool
        outcome = (try? c.decodeIfPresent(Outcome.self, forKey: .outcome)) ?? .open
    }
}

/// One question in a round: a title, a body the agent may have written several paragraphs of, the
/// recommendation the reader can accept with one key, and — when the agent offered them — choices.
public struct GrillQuestion: Codable, Sendable, Equatable, Identifiable {
    /// The agent's own label for the question ("Q1"), because that is what the answer block names and
    /// what the agent will recognise when it reads the answers back.
    public var id: String
    public var title: String
    /// Markdown. May be empty when the title says the whole question.
    public var body: String
    /// What the agent would do. Absent when it offered no recommendation, which is the one case where
    /// `⏎` has nothing to accept.
    public var recommendation: String?
    public var choices: [GrillChoice]
    /// Whether more than one choice may be picked.
    public var allowsMultiple: Bool

    public init(id: String, title: String, body: String = "", recommendation: String? = nil,
                choices: [GrillChoice] = [], allowsMultiple: Bool = false) {
        self.id = id
        self.title = title
        self.body = body
        self.recommendation = recommendation
        self.choices = choices
        self.allowsMultiple = allowsMultiple
    }

    public var recommendedChoice: GrillChoice? { choices.first(where: \.recommended) }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? ""
        body = (try? c.decodeIfPresent(String.self, forKey: .body)) ?? ""
        recommendation = try? c.decodeIfPresent(String.self, forKey: .recommendation)
        choices = (try? c.decodeIfPresent([GrillChoice].self, forKey: .choices)) ?? []
        allowsMultiple = (try? c.decodeIfPresent(Bool.self, forKey: .allowsMultiple)) ?? false
    }
}

public struct GrillChoice: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var label: String
    public var detail: String?
    /// The one the agent would pick. Drawn with the accent treatment; nothing else is.
    public var recommended: Bool

    public init(id: String, label: String, detail: String? = nil, recommended: Bool = false) {
        self.id = id
        self.label = label
        self.detail = detail
        self.recommended = recommended
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        label = (try? c.decodeIfPresent(String.self, forKey: .label)) ?? ""
        detail = try? c.decodeIfPresent(String.self, forKey: .detail)
        recommended = (try? c.decodeIfPresent(Bool.self, forKey: .recommended)) ?? false
    }
}

/// What the reader said. Four shapes, because those are the four things the pane lets them do.
public enum GrillAnswer: Codable, Sendable, Equatable {
    /// Yes to what the agent recommended. Stored as the verb rather than a copy of the text, so the
    /// composer always echoes the *current* recommendation.
    case acceptedRecommendation
    /// `GrillChoice.id`s, in the order the reader picked them.
    case choices([String])
    /// The reader's own words.
    case text(String)
    /// "You decide" — a decision, not an absence.
    case skipped

    /// Whether this answer says anything the agent can act on. A blank free-text answer does not, so
    /// the pane treats it as unanswered rather than sending an empty line.
    public var isMeaningful: Bool {
        switch self {
        case .acceptedRecommendation, .skipped: true
        case .choices(let ids): !ids.isEmpty
        case .text(let t): !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}
