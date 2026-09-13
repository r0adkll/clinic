import Foundation
import Testing
@testable import ClinicCore

/// What a round the agent posted turns into, and what the reader's answers turn back into (ADR-131).
/// The answer block is the one part of this feature that cannot be checked by looking at the screen —
/// the agent is the reader — so it is checked here.
@Suite struct GrillTests {
    let now = Date(timeIntervalSince1970: 1_000_000)

    private func round(_ questions: [GrillQuestion], index: Int? = 3, topic: String? = "Grill panel design",
                       answers: [String: GrillAnswer] = [:]) -> GrillRound {
        GrillRound(index: index, topic: topic, questions: questions, answers: answers, postedAt: now)
    }

    private func q(_ id: String, _ title: String, recommendation: String? = nil,
                   choices: [GrillChoice] = [], multiple: Bool = false) -> GrillQuestion {
        GrillQuestion(id: id, title: title, body: "", recommendation: recommendation,
                      choices: choices, allowsMultiple: multiple)
    }

    // MARK: The answer block

    @Test func theHeaderNamesTheRoundAndItsTopic() {
        #expect(GrillAnswerComposer.header(round([])) == "Answers to round 3 — Grill panel design:")
        #expect(GrillAnswerComposer.header(round([], topic: nil)) == "Answers to round 3:")
        #expect(GrillAnswerComposer.header(round([], index: nil)) == "Answers to your questions — Grill panel design:")
        #expect(GrillAnswerComposer.header(round([], index: nil, topic: nil)) == "Answers to your questions:")
        // A topic of spaces is the same as no topic; the header must not end in a dangling dash.
        #expect(GrillAnswerComposer.header(round([], index: nil, topic: "   ")) == "Answers to your questions:")
    }

    /// The point of echoing: the agent never has to resolve which recommendation "yes" meant.
    @Test func anAcceptedRecommendationIsQuotedBackInFull() {
        let question = q("Q1", "Round transport", recommendation: "an MCP tool that posts and returns")
        #expect(GrillAnswerComposer.line(for: question, answer: .acceptedRecommendation)
                == "Q1 (Round transport) — accepted your recommendation: an MCP tool that posts and returns.")
    }

    @Test func punctuationIsNotDoubled() {
        let ends = q("Q1", "T", recommendation: "do the thing.")
        #expect(GrillAnswerComposer.line(for: ends, answer: .acceptedRecommendation).hasSuffix("do the thing."))
        let asks = q("Q2", "T", recommendation: "why not both?")
        #expect(GrillAnswerComposer.line(for: asks, answer: .acceptedRecommendation).hasSuffix("why not both?"))
    }

    @Test func choicesAreNamedByTheirLabelNotTheirIndex() {
        let question = q("Q2", "Where it lives", choices: [
            GrillChoice(id: "1", label: "a pane in the right-hand panel", recommended: true),
            GrillChoice(id: "2", label: "a modal sheet"),
        ])
        #expect(GrillAnswerComposer.line(for: question, answer: .choices(["1"]))
                == "Q2 (Where it lives) — chose: a pane in the right-hand panel.")
    }

    @Test func severalChoicesJoinInThePickedOrder() {
        let question = q("Q3", "Layers", choices: [
            GrillChoice(id: "1", label: "tool description"),
            GrillChoice(id: "2", label: "server instructions"),
            GrillChoice(id: "3", label: "transcript parser"),
        ], multiple: true)
        #expect(GrillAnswerComposer.line(for: question, answer: .choices(["2", "1"]))
                == "Q3 (Layers) — chose: server instructions; tool description.")
    }

    @Test func freeTextIsMarkedAsTheReadersOwnWords() {
        let question = q("Q3", "Keyboard", recommendation: "two modes")
        #expect(GrillAnswerComposer.line(for: question, answer: .text("  two modes, but ⇥ commits  "))
                == "Q3 (Keyboard) — my answer: two modes, but ⇥ commits")
    }

    /// A paragraph that happens to start a line with "Q4…" must not read as another answer.
    @Test func multiLineAnswersIndentTheirContinuations() {
        let question = q("Q3", "Keyboard")
        let line = GrillAnswerComposer.line(for: question, answer: .text("two modes.\nQ4 is wrong because of this."))
        #expect(line == "Q3 (Keyboard) — my answer: two modes.\n  Q4 is wrong because of this.")
    }

    @Test func skippingIsADecisionAndSaysSo() {
        let question = q("Q4", "")
        #expect(GrillAnswerComposer.line(for: question, answer: .skipped) == "Q4 — skipped, you decide.")
        // An untitled question is named by its id alone — no empty parentheses.
        #expect(!GrillAnswerComposer.line(for: question, answer: .skipped).contains("()"))
    }

    @Test func unansweredAndEmptyAnswersBothReadAsSkipped() {
        let question = q("Q5", "Naming")
        #expect(GrillAnswerComposer.line(for: question, answer: nil) == "Q5 (Naming) — skipped, you decide.")
        #expect(GrillAnswerComposer.line(for: question, answer: .text("   ")) == "Q5 (Naming) — skipped, you decide.")
        #expect(GrillAnswerComposer.line(for: question, answer: .choices([])) == "Q5 (Naming) — skipped, you decide.")
        // A choice id that no longer exists is not an answer either.
        #expect(GrillAnswerComposer.line(for: question, answer: .choices(["gone"])) == "Q5 (Naming) — skipped, you decide.")
    }

    @Test func acceptWithNothingToAcceptStillSaysSomethingTrue() {
        #expect(GrillAnswerComposer.line(for: q("Q1", "T"), answer: .acceptedRecommendation) == "Q1 (T) — agreed with you.")
    }

    @Test func everyQuestionAppearsOnceInTheOrderItWasAsked() {
        let r = round([
            q("Q1", "Round transport", recommendation: "post and return"),
            q("Q2", "Where it lives", choices: [GrillChoice(id: "1", label: "a pane")]),
            q("Q3", "Keyboard"),
        ], answers: ["Q1": .acceptedRecommendation, "Q2": .choices(["1"]), "Q3": .text("two modes")])

        #expect(GrillAnswerComposer.compose(r) == """
            Answers to round 3 — Grill panel design:

            Q1 (Round transport) — accepted your recommendation: post and return.
            Q2 (Where it lives) — chose: a pane.
            Q3 (Keyboard) — my answer: two modes
            """)
    }

    /// A round the reader sends having answered nothing is still a reply, not an empty message.
    @Test func aRoundWithNothingAnsweredStillNamesEveryQuestion() {
        let text = GrillAnswerComposer.compose(round([q("Q1", "A"), q("Q2", "B")]))
        #expect(text.contains("Q1 (A) — skipped, you decide."))
        #expect(text.contains("Q2 (B) — skipped, you decide."))
    }

    // MARK: Counting and accepting

    @Test func aSkipCountsAsAnswered() {
        var r = round([q("Q1", "A", recommendation: "x"), q("Q2", "B", recommendation: "y"), q("Q3", "C")])
        #expect(r.answeredCount == 0)
        r.answers["Q2"] = .skipped
        #expect(r.answeredCount == 1)
        #expect(!r.isFullyAnswered)
    }

    @Test func acceptAllLeavesWhatTheReaderAlreadySaid() {
        var r = round([q("Q1", "A", recommendation: "x"), q("Q2", "B", recommendation: "y"), q("Q3", "C")])
        r.answers["Q2"] = .text("mine")
        r.acceptAllRecommendations()
        #expect(r.answers["Q1"] == .acceptedRecommendation)
        #expect(r.answers["Q2"] == .text("mine"))         // not overwritten
        #expect(r.answers["Q3"] == nil)                   // nothing to accept
        #expect(r.answeredCount == 2)
    }

    // MARK: Reading what the agent actually sent

    @Test func theDocumentedShapeDecodes() throws {
        let r = try GrillRound.from(arguments: [
            "topic": "Grill panel design",
            "roundIndex": 3,
            "questions": [
                ["id": "Q1", "title": "Round transport", "body": "Long body.", "recommendation": "post and return"],
                ["id": "Q2", "title": "Where it lives", "allowsMultiple": false,
                 "choices": [["label": "a pane", "detail": "beside the terminal", "recommended": true],
                             ["label": "a sheet"]]],
            ],
        ], now: now)

        #expect(r.index == 3)
        #expect(r.topic == "Grill panel design")
        #expect(r.questions.count == 2)
        #expect(r.questions[0].recommendation == "post and return")
        #expect(r.questions[1].choices.map(\.label) == ["a pane", "a sheet"])
        #expect(r.questions[1].recommendedChoice?.label == "a pane")
        #expect(r.source == .tool)
        #expect(r.outcome == .open)
    }

    @Test func missingIdsAreNumberedSoTheAnswerBlockCanNameThem() throws {
        let r = try GrillRound.from(arguments: ["questions": [["title": "First"], ["title": "Second"]]])
        #expect(r.questions.map(\.id) == ["Q1", "Q2"])
    }

    /// Two questions sharing an id would collide in `answers`, so one answer would silently answer both.
    @Test func repeatedIdsAreMadeUnique() throws {
        let r = try GrillRound.from(arguments: [
            "questions": [["id": "Q1", "title": "First"], ["id": "Q1", "title": "Second"]],
        ])
        #expect(r.questions.map(\.id) == ["Q1", "Q2"])
    }

    @Test func plainStringChoicesAreAccepted() throws {
        let r = try GrillRound.from(arguments: [
            "questions": [["title": "Pick", "choices": ["one", "two"]]],
        ])
        #expect(r.questions[0].choices.map(\.label) == ["one", "two"])
        #expect(r.questions[0].choices.map(\.id) == ["1", "2"])
    }

    @Test func aLoneQuestionObjectIsAccepted() throws {
        let r = try GrillRound.from(arguments: ["questions": ["title": "Just the one"]])
        #expect(r.questions.map(\.title) == ["Just the one"])
    }

    @Test func theAlternativeKeysAModelReachesForAreAccepted() throws {
        let r = try GrillRound.from(arguments: [
            "subject": "Naming",
            "round": "4",
            "questions": [["question": "What do we call it?", "details": "Full body.",
                           "recommended": "Grill", "multiple": "true",
                           "options": [["text": "Grill", "description": "vivid", "recommended": "true"],
                                       ["text": "Questions"]]]],
        ])
        #expect(r.index == 4)
        #expect(r.topic == "Naming")
        #expect(r.questions[0].title == "What do we call it?")
        #expect(r.questions[0].body == "Full body.")
        #expect(r.questions[0].recommendation == "Grill")
        #expect(r.questions[0].allowsMultiple)
        #expect(r.questions[0].choices.map(\.label) == ["Grill", "Questions"])
        #expect(r.questions[0].recommendedChoice?.label == "Grill")
    }

    /// The accent treatment means nothing if two choices wear it.
    @Test func onlyOneChoiceStaysRecommended() throws {
        let r = try GrillRound.from(arguments: [
            "questions": [["title": "Pick", "choices": [["label": "a", "recommended": true],
                                                        ["label": "b", "recommended": true]]]],
        ])
        #expect(r.questions[0].choices.filter(\.recommended).map(\.label) == ["a"])
    }

    @Test func aQuestionWithNeitherTitleNorBodyIsDropped() throws {
        let r = try GrillRound.from(arguments: [
            "questions": [["title": "Real"], ["body": "  "], ["recommendation": "orphan"]],
        ])
        #expect(r.questions.map(\.title) == ["Real"])
    }

    @Test func aRoundWithNothingAnswerableIsAnErrorNotAnEmptyPane() {
        #expect(throws: GrillArgumentError.self) { try GrillRound.from(arguments: [:]) }
        #expect(throws: GrillArgumentError.self) { try GrillRound.from(arguments: ["questions": []]) }
        #expect(throws: GrillArgumentError.self) { try GrillRound.from(arguments: ["questions": [["recommendation": "x"]]]) }
    }

    // MARK: Markdown export

    @Test func markdownCarriesTheQuestionAndWhatWasDecided() {
        var r = round([
            GrillQuestion(id: "Q1", title: "Round transport", body: "How do answers travel?",
                          recommendation: "post and return",
                          choices: [GrillChoice(id: "1", label: "post and return", recommended: true),
                                    GrillChoice(id: "2", label: "block")]),
        ])
        r.answers["Q1"] = .acceptedRecommendation

        #expect(GrillAnswerComposer.markdown(r) == """
            # Round 3 — Grill panel design

            ## Q1 — Round transport
            How do answers travel?
            **Recommended:** post and return
            - post and return _(recommended)_
            - block
            **Answer:** accepted your recommendation: post and return.
            """)
    }

    /// The export is for pasting into an ADR, so it must not carry the `Q1 (title) —` the agent needs.
    @Test func theExportedAnswerDropsTheLabelTheAgentNeeds() {
        let question = q("Q2", "Naming", recommendation: "Grill")
        #expect(GrillAnswerComposer.answerPhrase(for: question, answer: .acceptedRecommendation)
                == "accepted your recommendation: Grill.")
        #expect(GrillAnswerComposer.answerPhrase(for: q("Q3", ""), answer: .skipped) == "skipped, you decide.")
    }

    // MARK: What the session's system prompt is told

    @Test func instructionsOnlyNameToolsThatAreOffered() {
        let all = MCPToolSpec.all
        let text = MCPToolSpec.instructions(for: all)
        #expect(text.hasPrefix("Tools provided by Clinic, the macOS app hosting this session."))
        #expect(text.contains("ask_round"))
        #expect(text.contains("grilling"))
        #expect(text.contains("set_session_title"))

        // A tool the user switched off is not listed by tools/list, so the instructions must not
        // promise it either (ADR-131).
        let without = all.filter { $0.name != "ask_round" }
        #expect(!MCPToolSpec.instructions(for: without).contains("ask_round"))
        #expect(MCPToolSpec.instructions(for: without).contains("notify_user"))
        #expect(MCPToolSpec.instructions(for: []) == "Tools provided by Clinic, the macOS app hosting this session.")
    }

    @Test func askRoundIsOfferedWithASchemaThatParses() throws {
        let spec = try #require(MCPToolSpec.all.first { $0.name == "ask_round" })
        #expect(spec.defaultEnabled)
        let schema = try #require(spec.listEntry["inputSchema"] as? [String: Any])
        let properties = try #require(schema["properties"] as? [String: Any])
        #expect(properties["questions"] != nil)
        #expect(schema["required"] as? [String] == ["questions"])
        // The description has to carry both ways this gets used wrongly, or it carries nothing.
        #expect(spec.description.contains("ONCE PER ROUND"))
        #expect(spec.description.contains("End your turn"))
    }

    // MARK: Persistence

    let session = SessionID("11111111-2222-3333-4444-555555555555")

    /// A new round no longer closes the ones before it: superseding cost a reader the round they were
    /// part way through answering, and the footer acts on the round on screen rather than on "the one
    /// open round" (ADR-142).
    @Test func postingARoundLeavesTheOneBeforeOpen() {
        var state = ClinicState()
        state.postGrillRound(round([q("Q1", "A")], index: 1), to: session)
        state.postGrillRound(round([q("Q1", "B")], index: 2), to: session)

        let rounds = state.grillRounds[session] ?? []
        #expect(rounds.count == 2)
        #expect(rounds.filter(\.isOpen).count == 2)
        #expect(rounds.compactMap(\.index) == [1, 2])
    }

    /// Answers the reader had already given survive a later round arriving — the whole point.
    @Test func aPartAnsweredRoundKeepsItsAnswersWhenAnotherArrives() {
        var state = ClinicState()
        var first = round([q("Q1", "A", recommendation: "x"), q("Q2", "B")], index: 1)
        first.answers["Q1"] = .acceptedRecommendation
        state.postGrillRound(first, to: session)
        state.postGrillRound(round([q("Q1", "C")], index: 2), to: session)

        let kept = state.grillRounds[session]?.first
        #expect(kept?.isOpen == true)
        #expect(kept?.answers["Q1"] == .acceptedRecommendation)
    }

    /// A round the reader already sent stays sent when another arrives.
    @Test func aSentRoundKeepsItsOutcome() {
        var state = ClinicState()
        var first = round([q("Q1", "A")], index: 1)
        first.outcome = .sent(now)
        state.grillRounds[session] = [first]
        state.postGrillRound(round([q("Q1", "B")], index: 2), to: session)
        #expect(state.grillRounds[session]?[0].outcome == .sent(now))
    }

    @Test func theHistoryIsCappedOldestFirst() {
        var state = ClinicState()
        for i in 1...(GrillRound.maxPerSession + 3) {
            state.postGrillRound(round([q("Q1", "A")], index: i), to: session)
        }
        let rounds = state.grillRounds[session] ?? []
        #expect(rounds.count == GrillRound.maxPerSession)
        #expect(rounds.first?.index == 4)                       // the first three fell off
        #expect(rounds.last?.index == GrillRound.maxPerSession + 3)
    }

    // MARK: The sample round and discarding (ADR-133)

    /// The sample exists to show what the pane can draw, so it has to contain one of each shape — and
    /// it goes through the same decode-free path a posted round does.
    @Test func theSampleCoversEveryShapeThePaneDraws() {
        let r = GrillRound.sample(now: now)
        #expect(r.topic == "Sample round")
        #expect(r.isOpen)
        #expect(r.questions.count == 4)
        #expect(r.answers.isEmpty)

        let recommendationOnly = r.questions[0]
        #expect(recommendationOnly.recommendation != nil && recommendationOnly.choices.isEmpty)

        let singleSelect = r.questions[1]
        #expect(!singleSelect.allowsMultiple && singleSelect.choices.count == 3)
        #expect(singleSelect.recommendedChoice != nil)

        let multiSelect = r.questions[2]
        #expect(multiSelect.allowsMultiple && multiSelect.choices.count == 3)

        let freeform = r.questions[3]
        #expect(freeform.recommendation == nil && freeform.choices.isEmpty)

        // Every question needs a body, or the pane has nothing to show when a row is opened.
        #expect(r.questions.allSatisfy { !$0.body.isEmpty && !$0.title.isEmpty })
        // Ids must be unique, the same as any round the agent posts.
        #expect(Set(r.questions.map(\.id)).count == r.questions.count)
    }

    @Test func aSampleRoundIsPostedLikeAnyOther() {
        var state = ClinicState()
        state.postGrillRound(round([q("Q1", "A")], index: 1), to: session)
        state.postGrillRound(.sample(now: now), to: session)
        #expect(state.grillRounds[session]?.filter(\.isOpen).count == 2)
        #expect(state.grillRounds[session]?.last?.topic == "Sample round")
    }

    /// Discard removes rather than recording a fifth outcome — "discarded" means gone (ADR-133).
    @Test func discardRemovesTheRound() {
        var state = ClinicState()
        let keep = round([q("Q1", "A")], index: 1)
        let drop = round([q("Q1", "B")], index: 2)
        state.postGrillRound(keep, to: session)
        state.postGrillRound(drop, to: session)

        state.discardGrillRound(drop.id, in: session)
        #expect(state.grillRounds[session]?.compactMap(\.index) == [1])
        // The one that stayed is untouched — and stays open, since rounds no longer close each other
        // (ADR-142). Discarding one round is not a way to change another.
        #expect(state.grillRounds[session]?[0].isOpen == true)
    }

    @Test func discardingTheLastRoundLeavesNoEmptyEntry() {
        var state = ClinicState()
        let only = round([q("Q1", "A")], index: 1)
        state.postGrillRound(only, to: session)
        state.discardGrillRound(only.id, in: session)
        #expect(state.grillRounds[session] == nil)
    }

    @Test func discardingAnUnknownRoundChangesNothing() {
        var state = ClinicState()
        let only = round([q("Q1", "A")], index: 1)
        state.postGrillRound(only, to: session)
        state.discardGrillRound(UUID(), in: session)
        #expect(state.grillRounds[session]?.count == 1)
    }

    @Test func roundsSurviveAStateRoundTrip() throws {
        let id = session
        var state = ClinicState()
        var r = round([q("Q1", "Round transport", recommendation: "post and return")])
        r.answers["Q1"] = .acceptedRecommendation
        r.outcome = .sent(now)
        state.grillRounds[id] = [r]

        let back = try JSONDecoder().decode(ClinicState.self, from: JSONEncoder().encode(state))
        #expect(back.grillRounds[id]?.count == 1)
        #expect(back.grillRounds[id]?[0].answers["Q1"] == .acceptedRecommendation)
        #expect(back.grillRounds[id]?[0].outcome == .sent(now))
        #expect(back.grillRounds[id]?[0].questions[0].recommendation == "post and return")
    }

    /// Every other field is decoded tolerantly (ADR-021), and a state file written before this feature
    /// has no `grillRounds` key at all.
    @Test func stateWithoutRoundsStillLoads() throws {
        let back = try JSONDecoder().decode(ClinicState.self, from: Data(#"{"version":1}"#.utf8))
        #expect(back.grillRounds.isEmpty)
    }
}
