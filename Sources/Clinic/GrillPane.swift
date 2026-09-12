import AppKit
import ClinicCore
import Observation
import SwiftUI

/// A round of the agent's questions, answered one at a time (ADR-132, over ADR-131's card scroll).
///
/// The agent posts a round with `ask_round` and ends its turn; the reader walks the questions with the
/// keyboard, accepting recommendations, picking choices or typing their own, and Send — from the review
/// step at the end — pastes one block into the agent surface as their next message.

/// Everything one Grill pane remembers that is not the round itself: where the wizard is, which of the
/// two keyboards is live, which round is on screen, and any answer still being typed.
///
/// Committed answers live in `ClinicState` through `SessionStore`, so they persist and the composer can
/// read them. Drafts live here because writing every keystroke through the state file would be absurd —
/// and because ⎋ has to leave a draft alone rather than commit it.
@MainActor
@Observable
final class GrillPaneModel {
    /// Two keyboards, because this pane has to accept typing and still answer single keys
    /// (ADR-131; ADR-107 established that a pane-local handler never sees a command chord).
    enum Mode: Equatable {
        /// `j`/`k` step, `⏎` accepts, `1`–`9` pick, `e` starts typing.
        case navigate
        /// Everything types. `⎋` returns to navigate with the draft kept.
        case answering
    }

    /// Where the wizard is. The review step is one past the last question, so `j` reaches it and `k`
    /// comes back (ADR-132).
    enum Step: Equatable {
        case question(Int)
        case review
    }

    var mode: Mode = .navigate
    var step: Step = .question(0)
    /// Free text still being typed, keyed by **round and** question — question ids repeat across rounds
    /// (every round has a `Q1`), so keying by question alone would leak a superseded round's draft into
    /// the next round's first question.
    var drafts: [String: String] = [:]
    /// Which row of the review step has the keyboard, so `⏎` can jump back to its question.
    var reviewFocus = 0
    /// Which row of the history list has the keyboard, and which rows are opened (ADR-133). A round you
    /// cannot answer is read, not walked, so it keeps its own focus rather than borrowing the wizard's.
    var historyFocus = 0
    var expandedHistory: Set<String> = []
    /// A prior round the reader asked to see again. Nil means the round the pane would show anyway.
    var replayingRoundId: UUID?
    /// True while Send is writing into the surface, so the button cannot fire twice.
    var sending = false
    /// Whether the pane's own responder holds the keyboard. Set by AppKit from
    /// `becomeFirstResponder`/`resignFirstResponder`, not inferred from SwiftUI's focus state —
    /// inferring it is what let the keymap fire inside the reader's sentences (ADR-134, ADR-135).
    var hasKeyboard = false
    /// Asks the responder to claim the keyboard on the next update.
    var wantsKeyboard = false

    // MARK: Stepping

    /// The review step exists only from two questions up: a one-pip strip over a review listing one
    /// answer is ceremony around nothing (ADR-132).
    static func hasWizardChrome(_ round: GrillRound) -> Bool { round.questions.count >= 2 }

    func questionIndex(in round: GrillRound) -> Int? {
        guard case .question(let i) = step, round.questions.indices.contains(i) else { return nil }
        return i
    }

    func question(in round: GrillRound) -> GrillQuestion? {
        questionIndex(in: round).map { round.questions[$0] }
    }

    /// Steps without wrapping — a wizard has a beginning and an end, and wrapping makes "have I reached
    /// the end?" unanswerable by feel. Past the last question is the review step, when there is one.
    func move(by delta: Int, in round: GrillRound) {
        mode = .navigate
        let last = round.questions.count - 1
        guard last >= 0 else { return }
        switch step {
        case .review:
            if delta < 0 { step = .question(last) }
        case .question(let i):
            let next = i + delta
            if next > last {
                if Self.hasWizardChrome(round) { step = .review; reviewFocus = 0 }
            } else {
                step = .question(max(0, next))
            }
        }
    }

    /// What a complete answer does: move on. An incomplete one (a multi-select tick) calls nothing.
    func advance(in round: GrillRound) { move(by: 1, in: round) }

    func show(_ index: Int, in round: GrillRound) {
        guard round.questions.indices.contains(index) else { return }
        step = .question(index)
        mode = .navigate
    }

    /// Puts the wizard on the first question with no answer yet, or on the review step when every
    /// question has one — what *Accept all* does with the reader once it has filled what it can.
    func goToFirstUnanswered(in round: GrillRound) {
        if let i = round.questions.firstIndex(where: { round.answers[$0.id] == nil }) {
            show(i, in: round)
        } else if Self.hasWizardChrome(round) {
            step = .review
            reviewFocus = 0
            mode = .navigate
        }
    }

    func toggleHistory(_ question: GrillQuestion) {
        if expandedHistory.contains(question.id) { expandedHistory.remove(question.id) }
        else { expandedHistory.insert(question.id) }
    }

    /// Puts the wizard back at the first question. Deliberately does **not** touch `replayingRoundId`:
    /// this runs whenever the round on screen changes, and a replay *is* such a change — clearing the
    /// replay here made picking a round from the menu undo itself on the very next render.
    func reset() {
        step = .question(0)
        reviewFocus = 0
        historyFocus = 0
        expandedHistory = []
        mode = .navigate
    }

    // MARK: Drafts

    private func key(_ round: GrillRound, _ question: GrillQuestion) -> String { "\(round.id)#\(question.id)" }
    func draft(_ round: GrillRound, _ question: GrillQuestion) -> String { drafts[key(round, question)] ?? "" }
    func setDraft(_ text: String, _ round: GrillRound, _ question: GrillQuestion) { drafts[key(round, question)] = text }
    func clearDraft(_ round: GrillRound, _ question: GrillQuestion) { drafts[key(round, question)] = nil }

    /// Seeds the editor with whatever is already there, so `e` on an answer you wrote is an edit rather
    /// than a blank slate.
    func beginAnswering(_ round: GrillRound, _ question: GrillQuestion, existing: GrillAnswer?) {
        if drafts[key(round, question)] == nil, case .text(let t)? = existing { drafts[key(round, question)] = t }
        mode = .answering
    }
}

// MARK: - The pane

struct GrillPane: View {
    @Environment(SessionStore.self) private var sessions
    @Environment(TabStore.self) private var tabs
    let tab: Tab
    @Bindable var model: GrillPaneModel

    private var rounds: [GrillRound] {
        guard let id = tab.sessionId else { return [] }
        return sessions.grillRounds(for: id)
    }

    /// The round on screen: one the reader asked to see again, else the open one, else the newest —
    /// because a pane that says "nothing here" the moment you press Send erases what you just did
    /// (ADR-132).
    private var current: GrillRound? {
        if let id = model.replayingRoundId, let match = rounds.first(where: { $0.id == id }) { return match }
        return rounds.last(where: \.isOpen) ?? rounds.last
    }

    private var openRound: GrillRound? { rounds.last(where: \.isOpen) }

    /// Whether the round on screen can still be answered. A replayed, sent or superseded round cannot.
    private var isActionable: Bool { current?.isOpen == true }

    /// The round as the reader sees it: every uncommitted draft folded in, so a question you have just
    /// typed into reads as answered everywhere — the pip, the badge, the count, the review (ADR-136).
    /// The raw `current` is still what writes and identity use.
    private var shown: GrillRound? { current.map(withDrafts) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let round = current {
                // The strip is orientation *while answering*; a round being read shows its questions
                // all at once and has no position to orient (ADR-133).
                if isActionable, GrillPaneModel.hasWizardChrome(round) {
                    ProgressStrip(round: shown ?? round, model: model, actionable: true)
                    Divider()
                }
                body(for: round)
                Divider()
                footer(for: round)
            } else {
                // Without this the empty state describes a pane the reader has no way to look at
                // (ADR-133).
                ContentUnavailableView {
                    Label("No questions yet", systemImage: "flame")
                } description: {
                    Text("Rounds the agent posts with ask_round appear here, ready to answer.")
                } actions: {
                    Button("Post a Sample Round") { tabs.postSampleGrillRound(tab) }
                        .disabled(tab.sessionId == nil)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // Whatever put a different round on screen — a new one, or the rounds menu — starts it at its
        // first question. Drafts survive, being keyed by round (ADR-132).
        .onChange(of: current?.id) { _, _ in model.reset() }
        // A round that needs the reader pulls them out of history: the pane's job is to show what is
        // waiting, and staying in a replay would hide it.
        .onChange(of: openRound?.id) { _, id in if id != nil { model.replayingRoundId = nil } }
        // Leaving the answer field hands the keyboard back to the pane's responder.
        .onChange(of: model.mode) { _, mode in
            if mode == .navigate, !model.sending { model.wantsKeyboard = true }
        }
        // The reader opened this pane themselves, so it may have the keyboard (ADR-132). A round
        // arriving never sets the flag, so it can still never eat a half-typed sentence.
        .onChange(of: tabs.grillWantsKeyboard) { _, wants in if wants { takeKeyboard() } }
        .onAppear { if tabs.grillWantsKeyboard { takeKeyboard() } }
    }

    private func takeKeyboard() {
        // Next runloop turn: the flag is read during a view update, and clearing it there would mutate
        // observed state mid-body.
        DispatchQueue.main.async {
            model.wantsKeyboard = true
            tabs.grillWantsKeyboard = false
        }
    }

    @ViewBuilder
    private func body(for round: GrillRound) -> some View {
        VStack(spacing: 0) {
            if let note = readOnlyNote(round) { ReadOnlyBanner(text: note) }
            ScrollView {
                Group {
                    if !isActionable {
                        // Reading, not answering: every question at once, each row opening in place.
                        HistoryList(round: round, model: model)
                    } else if case .review = model.step, GrillPaneModel.hasWizardChrome(round) {
                        ReviewStep(round: shown ?? round, model: model, actionable: isActionable,
                                   jump: { model.show($0, in: round) })
                    } else if let index = model.questionIndex(in: round) {
                        QuestionStep(round: shown ?? round, question: round.questions[index], model: model,
                                     actionable: isActionable,
                                     accept: { accept(round.questions[index], in: round) },
                                     pick: { pick($0, for: round.questions[index], in: round) },
                                     skip: { answer(.skipped, for: round.questions[index], in: round, advance: true) },
                                     exit: { exit($0, for: round.questions[index], in: round) })
                    }
                }
                .padding(12)
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
        // The pane's keyboard is an `NSView`, not SwiftUI focus (ADR-135). It draws nothing and takes
        // no clicks; it exists so that arrows arrive at all and so that "who has the keyboard" has one
        // answer, held by AppKit.
        .background(
            GrillKeyboard(wants: model.wantsKeyboard && model.mode == .navigate,
                          onKey: { navigate($0, in: round) },
                          onFocusChange: { has in
                              model.hasKeyboard = has
                              if has { model.wantsKeyboard = false }
                          })
        )
    }

    /// Why this round cannot be answered, in the words that are true of it.
    private func readOnlyNote(_ round: GrillRound) -> String? {
        switch round.outcome {
        case .open: nil
        case .sent: "You sent these answers. They are here to read, not to change."
        case .answeredElsewhere: "You answered this round in the terminal, so this copy is a record."
        // ADR-132: nothing the reader typed is thrown away, it just has nowhere to go.
        case .superseded: "The agent moved on to the next round. Anything you entered here was kept, but not sent."
        }
    }

    // MARK: Header

    private var header: some View {
        PaneHeader {
            Image(systemName: "flame")
                .font(.system(size: PaneMetrics.glyph, weight: .medium))
                .foregroundStyle(isActionable ? Color.accentColor : Color.secondary)
            Text(title)
                .font(.system(size: PaneMetrics.label, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            if let hint = modeHint { hintLabel(hint) }
            if rounds.count > 1 { roundsMenu }
            if let round = current {
                PaneIconButton(symbol: "doc.on.doc", help: "Copy this round as Markdown (⌘⌃C)") {
                    tabs.copyGrillRound(round)
                }
            }
            if let round = shown, GrillPaneModel.hasWizardChrome(round) {
                Text("\(round.answeredCount) of \(round.questions.count)")
                    .font(.system(size: PaneMetrics.label, weight: .medium).monospacedDigit())
                    .foregroundStyle(round.isFullyAnswered ? Color.accentColor : Color.secondary)
            }
        }
    }

    private var title: String {
        guard let round = current else { return "Grill" }
        let number = round.index.map { "Round \($0)" } ?? "Questions"
        guard let topic = round.topic, !topic.isEmpty else { return number }
        return "\(number) · \(topic)"
    }

    /// Which of the two keyboards is live. Not decoration: `⏎` accepts a recommendation in one mode and
    /// types a newline in the other, so a reader who cannot see the mode is guessing (ADR-131).
    ///
    /// Nil when the pane does not hold the keyboard at all — the terminal does, and a pane advertising
    /// keys that would go to the agent's prompt instead would be worse than saying nothing.
    private var modeHint: String? {
        if model.mode == .answering { return "⎋ done" }
        guard model.hasKeyboard else { return nil }
        if !isActionable { return "↓↑ read · ⏎ open" }
        if case .review = model.step { return "↓↑ · ⏎ edit · ⌘⏎ send" }
        return "↓↑ move · ⏎ accept · s skip"
    }

    private func hintLabel(_ hint: String) -> some View {
        let answering = model.mode == .answering
        return Text(hint)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(answering ? Color.accentColor : Color.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background((answering ? Color.accentColor : Color.secondary).opacity(0.11), in: Capsule())
            .lineLimit(1)
    }

    /// Replays an earlier round read-only. The round the pane would show anyway is listed first, so
    /// getting back is the same gesture as leaving (ADR-132).
    private var roundsMenu: some View {
        Menu {
            ForEach(rounds.reversed()) { round in
                Button {
                    // The open round is "no replay", so picking it is the same gesture as leaving one.
                    model.replayingRoundId = round.isOpen ? nil : round.id
                } label: {
                    let name = round.index.map { "Round \($0)" } ?? "Questions"
                    let state = round.isOpen ? "waiting" : outcomeWord(round)
                    Text("\(name) — \(state) · \(round.questions.count)")
                }
            }
        } label: {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: PaneMetrics.glyph, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: PaneMetrics.control + 6, height: PaneMetrics.control)
        .help("Earlier rounds")
    }

    private func outcomeWord(_ round: GrillRound) -> String {
        switch round.outcome {
        case .open: "waiting"
        case .sent: "sent"
        case .answeredElsewhere: "answered in the terminal"
        case .superseded: "superseded"
        }
    }

    // MARK: Footer

    @ViewBuilder
    private func footer(for round: GrillRound) -> some View {
        HStack(spacing: 8) {
            if !isActionable {
                if openRound != nil {
                    Button("Back to the open round") { model.replayingRoundId = nil }
                        .help("⎋")
                }
                Spacer(minLength: 0)
            } else {
                let effective = withDrafts(round)
                let answered = effective.questions.filter { effective.answers[$0.id]?.isMeaningful == true }.count
                let total = round.questions.count
                let canAcceptAll = round.questions.contains { round.answers[$0.id] == nil && $0.recommendation != nil }
                let reviewing = model.step == .review || !GrillPaneModel.hasWizardChrome(round)

                if GrillPaneModel.hasWizardChrome(round) {
                    Button("Back") { model.move(by: -1, in: round) }
                        .disabled(model.step == .question(0))
                    Button("Next") { model.move(by: 1, in: round) }
                        .disabled(model.step == .review)
                }
                Button("Accept all") { acceptAll(round) }
                    .disabled(!canAcceptAll || model.sending)
                    .help("Fill every unanswered question with the agent's recommendation, then go to the first one that still needs you")
                // The one action here that destroys something, so it says so plainly and has no key.
                Button("Discard") { discard(round) }
                    .disabled(model.sending)
                    .help("Throw this round away without answering it. The questions stay in the terminal.")
                Spacer(minLength: 0)
                // Send is a destination you arrive at, so its button lives on the review step — but
                // ⌘⏎ still sends from anywhere (ADR-132).
                if reviewing {
                    Button { send(round) } label: {
                        if model.sending {
                            HStack(spacing: 5) {
                                ProgressView().controlSize(.small).tint(.white)
                                Text("Sending…")
                            }
                        } else {
                            Text(answered == total ? "Send \(total) answer\(total == 1 ? "" : "s")" : "Send \(answered) of \(total)")
                        }
                    }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(model.sending)
                } else {
                    // Present but invisible, so ⌘⏎ works from a question too without a second button.
                    Button("Send") { send(round) }
                        .keyboardShortcut(.return, modifiers: .command)
                        .hidden()
                        .frame(width: 0)
                }
            }
        }
        .padding(.horizontal, PaneMetrics.padding)
        .frame(height: PaneMetrics.headerHeight + 4)
        .background(.bar)
    }

    // MARK: The Navigate keyboard

    /// One round's worth of single keys, now delivered by the pane's own responder rather than by
    /// SwiftUI (ADR-135). Returns false to let AppKit carry on with the key.
    private func navigate(_ key: GrillKey, in round: GrillRound) -> Bool {
        // While the field has the keyboard, every key is the reader's prose (ADR-134). AppKit already
        // routes keys to the text view when it is first responder, so this is belt as well as braces.
        guard model.mode == .navigate else { return false }

        // ⎋ leaves a replay, the one key that works on a round you cannot answer.
        if key == .escape, model.replayingRoundId != nil {
            model.replayingRoundId = nil
            return true
        }

        // A round being read has its own keyboard rather than none. `guard isActionable` used to
        // swallow every key here, which is why a historical round showed question 1 and nothing else
        // (ADR-133).
        if !isActionable {
            let last = round.questions.count - 1
            guard last >= 0 else { return false }
            switch key {
            case .down, .right, .character("j"): model.historyFocus = min(model.historyFocus + 1, last); return true
            case .up, .left, .character("k"): model.historyFocus = max(model.historyFocus - 1, 0); return true
            case .enter, .space:
                model.toggleHistory(round.questions[min(model.historyFocus, last)])
                return true
            default: return false
            }
        }

        // The review step walks its rows; ⏎ goes back to change the one you are on.
        if case .review = model.step {
            switch key {
            case .down, .right, .character("j"):
                model.reviewFocus = min(model.reviewFocus + 1, round.questions.count - 1)
                return true
            case .up, .left, .character("k"):
                if model.reviewFocus > 0 { model.reviewFocus -= 1 } else { model.move(by: -1, in: round) }
                return true
            case .enter: model.show(model.reviewFocus, in: round); return true
            default: return false
            }
        }

        guard let question = model.question(in: round) else { return false }
        switch key {
        // Arrows are the navigation the header advertises: they cannot collide with prose the way a
        // letter can, and now that the pane owns a responder they actually arrive (ADR-135). ← / →
        // because a wizard is a sequence you move along — what the footer's own Back and Next say.
        case .down, .right, .character("j"): model.move(by: 1, in: round); return true
        case .up, .left, .character("k"): model.move(by: -1, in: round); return true
        case .tab(let shift): model.move(by: shift ? -1 : 1, in: round); return true

        case .enter:
            // ⏎ means "I am done with this question", in whichever way this question can be done: take
            // the recommendation, or move on from an answer already given — which is what a
            // multi-select needs, since ticking boxes deliberately does not advance. Only a question
            // with neither falls through to typing (ADR-132).
            if question.recommendation != nil {
                accept(question, in: round)
            } else if round.answers[question.id]?.isMeaningful == true {
                model.advance(in: round)
            } else {
                model.beginAnswering(round, question, existing: round.answers[question.id])
            }
            return true

        case .character("e"), .character("i"):
            model.beginAnswering(round, question, existing: round.answers[question.id])
            return true
        case .character("s"):
            answer(.skipped, for: question, in: round, advance: true)
            return true
        case .character(let c) where c.isNumber && c != "0":
            guard let n = c.wholeNumberValue, question.choices.indices.contains(n - 1) else { return true }
            pick(question.choices[n - 1], for: question, in: round)
            return true

        default: return false
        }
    }

    // MARK: Answering

    private func answer(_ value: GrillAnswer?, for question: GrillQuestion, in round: GrillRound, advance: Bool) {
        guard let session = tab.sessionId else { return }
        sessions.updateGrillRound(round.id, in: session) { r in r.answers[question.id] = value }
        model.mode = .navigate
        // A complete answer advances; an incomplete one does not (ADR-132).
        if advance { model.advance(in: round) }
    }

    private func accept(_ question: GrillQuestion, in round: GrillRound) {
        guard question.recommendation != nil else { return }
        model.clearDraft(round, question)
        answer(.acceptedRecommendation, for: question, in: round, advance: true)
    }

    /// Single-choice replaces and advances; multi-select toggles and stays, because a tick is not a
    /// finished answer.
    private func pick(_ choice: GrillChoice, for question: GrillQuestion, in round: GrillRound) {
        var picked: [String]
        if case .choices(let existing)? = round.answers[question.id] { picked = existing } else { picked = [] }
        if question.allowsMultiple {
            if let i = picked.firstIndex(of: choice.id) { picked.remove(at: i) } else { picked.append(choice.id) }
        } else {
            picked = picked == [choice.id] ? [] : [choice.id]
        }
        model.clearDraft(round, question)
        answer(picked.isEmpty ? nil : .choices(picked), for: question, in: round,
               advance: !question.allowsMultiple && !picked.isEmpty)
    }

    private func commitDraft(_ question: GrillQuestion, in round: GrillRound, advance: Bool) {
        let text = model.draft(round, question).trimmingCharacters(in: .whitespacesAndNewlines)
        answer(text.isEmpty ? nil : .text(text), for: question, in: round, advance: advance)
    }

    /// Every way out of the field commits what is in it (ADR-136). `⎋` used to leave the draft
    /// uncommitted, which is how a reader came to type a paragraph and watch the pane go on saying the
    /// question was unanswered — while the footer counted it and Send sent it.
    private func exit(_ how: GrillAnswerField.Exit, for question: GrillQuestion, in round: GrillRound) {
        switch how {
        case .next: commitDraft(question, in: round, advance: true)
        case .previous:
            commitDraft(question, in: round, advance: false)
            model.move(by: -1, in: round)
        // Done, and stay here — as against `.next`, which is done and move on.
        case .cancel: commitDraft(question, in: round, advance: false)
        }
    }

    /// Fills what it can, then puts the reader on the first question that still needs them — falling
    /// through to the review step when there is none (ADR-132).
    private func acceptAll(_ round: GrillRound) {
        guard let session = tab.sessionId else { return }
        sessions.updateGrillRound(round.id, in: session) { $0.acceptAllRecommendations() }
        var filled = round
        filled.acceptAllRecommendations()
        model.goToFirstUnanswered(in: filled)
    }

    /// The round as it would be sent: every uncommitted draft folded in, so Send never loses what the
    /// reader was in the middle of typing.
    private func withDrafts(_ round: GrillRound) -> GrillRound {
        var copy = round
        for question in round.questions {
            let text = model.draft(round, question).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { copy.answers[question.id] = .text(text) }
        }
        return copy
    }

    private func discard(_ round: GrillRound) {
        guard let session = tab.sessionId else { return }
        sessions.discardGrillRound(round.id, in: session)
        model.replayingRoundId = nil
        model.reset()
    }

    private func send(_ round: GrillRound) {
        guard let session = tab.sessionId, round.isOpen, !model.sending else { return }
        let effective = withDrafts(round)
        model.sending = true
        // Bracketed paste plus Return: from the CLI's side this is the reader typing (ADR-055 kept this
        // path for exactly the tools that speak for the reader).
        tab.surface.sendPastedLine(GrillAnswerComposer.compose(effective))
        sessions.updateGrillRound(round.id, in: session) { r in
            r.answers = effective.answers
            r.outcome = .sent(Date())
        }
        model.mode = .navigate
        model.sending = false
    }
}

// MARK: - Progress strip

/// Orientation: where you are, and how much is left. Pips carry state rather than only position —
/// "3 of 6" would say where you are but not what is still waiting (ADR-132).
private struct ProgressStrip: View {
    let round: GrillRound
    @Bindable var model: GrillPaneModel
    let actionable: Bool

    var body: some View {
        // 7 pt apart so two halos never touch, in a 30 pt band so one has room (ADR-134).
        HStack(spacing: 7) {
            ForEach(Array(round.questions.enumerated()), id: \.element.id) { index, question in
                Pip(label: "\(index + 1)",
                    state: .init(round.answers[question.id]),
                    current: model.step == .question(index),
                    question: question.title) { model.show(index, in: round) }
            }
            Pip(label: nil,
                state: round.isFullyAnswered ? .answered : .unanswered,
                current: model.step == .review,
                question: "Review and send") {
                model.step = .review
                model.reviewFocus = 0
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, PaneMetrics.padding)
        .frame(height: 30)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .disabled(!actionable)
    }

    /// There is no key for these: `1`–`9` already picks a choice, so the strip is a pointer control.
    private struct Pip: View {
        /// What happened to the question. Three looks rather than two, because a skip is a decision but
        /// not a decision with content, and drawing it as a plain answer said the wrong thing (ADR-134).
        enum State {
            case unanswered, skipped, answered

            init(_ answer: GrillAnswer?) {
                switch answer {
                case .none: self = .unanswered
                case .skipped: self = .skipped
                case .some(let a): self = a.isMeaningful ? .answered : .unanswered
                }
            }

            var fill: Color {
                switch self {
                case .unanswered: Color.primary.opacity(0.08)
                // Filled in, but not a decision with content. A border would not read at 18 pt.
                case .skipped: Color.secondary.opacity(0.5)
                case .answered: Color.accentColor
                }
            }

            var foreground: Color {
                switch self {
                case .unanswered: .secondary
                case .skipped, .answered: .white
                }
            }

            var word: String {
                switch self {
                case .unanswered: "not answered"
                case .skipped: "skipped"
                case .answered: "answered"
                }
            }
        }

        let label: String?
        let state: State
        let current: Bool
        let question: String
        let action: () -> Void

        var body: some View {
            Button(action: action) {
                Group {
                    if let label {
                        Text(label).font(.system(size: 10, weight: .semibold).monospacedDigit())
                    } else {
                        Image(systemName: "checklist").font(.system(size: 10, weight: .semibold))
                    }
                }
                .foregroundStyle(state.foreground)
                .frame(width: 18, height: 18)
                .background(state.fill, in: Circle())
                // Where you are is drawn *outside* the disc, clear of it, so it reads over any of the
                // three fills — including the accent one it used to be invisible against (ADR-134).
                .overlay {
                    Circle()
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                        .padding(-3)
                        .opacity(current ? 1 : 0)
                }
            }
            .buttonStyle(.plain)
            .help(help)
            .accessibilityLabel(help)
        }

        private var help: String {
            let name = label.map { "Q\($0)" } ?? "Review"
            return "\(name) — \(question) — \(state.word)" + (current ? " — showing" : "")
        }
    }
}

// MARK: - One question

private struct QuestionStep: View {
    let round: GrillRound
    let question: GrillQuestion
    @Bindable var model: GrillPaneModel
    let actionable: Bool
    let accept: () -> Void
    let pick: (GrillChoice) -> Void
    let skip: () -> Void
    let exit: (GrillAnswerField.Exit) -> Void

    private var answer: GrillAnswer? { round.answers[question.id] }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            titleRow
            // Bodies show in full: the fold existed so six cards would fit, and nothing has to fit now.
            if !question.body.isEmpty { GrillMarkdown(question.body) }
            if let recommendation = question.recommendation { recommendationRow(recommendation) }
            if !question.choices.isEmpty { choiceList }
            answerField
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .disabled(!actionable)
    }

    private var titleRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(question.id)
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Color.primary.opacity(0.07), in: Capsule())
            Text(question.title)
                .font(.system(size: 15, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if let answer { AnswerBadge(answer: answer) }
        }
    }

    /// The recommendation is what the reader is most likely to want, so it is the loudest thing here and
    /// carries the key that takes it.
    private func recommendationRow(_ text: String) -> some View {
        let accepted = answer == .acceptedRecommendation
        return HStack(alignment: .top, spacing: 7) {
            Image(systemName: "arrow.turn.down.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .padding(.top, 2)
            GrillMarkdown(text)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(accepted ? "Accepted" : "Accept") { accept() }
                .buttonStyle(.borderless)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(accepted ? Color.secondary : Color.accentColor)
                .help(accepted ? "You accepted this" : "Accept the agent's recommendation — ⏎")
        }
        .padding(9)
        .background(Color.accentColor.opacity(accepted ? 0.14 : 0.08), in: RoundedRectangle(cornerRadius: 6))
    }

    private var choiceList: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(question.choices.enumerated()), id: \.element.id) { index, choice in
                ChoiceRow(choice: choice, number: index + 1,
                          multiple: question.allowsMultiple,
                          picked: isPicked(choice)) { pick(choice) }
            }
            if question.allowsMultiple {
                Text("Pick as many as apply — ⏎ or ⇥ when you are done")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 1)
            }
        }
    }

    private func isPicked(_ choice: GrillChoice) -> Bool {
        if case .choices(let ids)? = answer { return ids.contains(choice.id) }
        return false
    }

    private var draft: Binding<String> {
        Binding(get: { model.draft(round, question) }, set: { model.setDraft($0, round, question) })
    }

    /// The box, its prompt and the two things that are not typing — laid out down the column rather
    /// than across it, so nothing sits beside the box competing to be the way you answer (ADR-136).
    private var answerField: some View {
        let focused = model.mode == .answering
        let empty = draft.wrappedValue.isEmpty
        return VStack(alignment: .leading, spacing: 4) {
            GrillAnswerField(text: draft,
                             isActive: focused,
                             onFocus: { model.beginAnswering(round, question, existing: answer) },
                             onExit: exit)
                .frame(height: 56)
                .padding(.horizontal, 2)
                .padding(.vertical, 2)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay {
                    // Accent while it has the keyboard — the same signal the current pip and the
                    // focused card use. `NSScrollView.lineBorder` cannot change with state, so the
                    // border lives here.
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(focused ? Color.accentColor.opacity(0.8) : Color.primary.opacity(0.12),
                                      lineWidth: focused ? 1.5 : 1)
                        // Decoration only. An overlay sits *above* the `NSViewRepresentable`, and a
                        // shape hit-tests, so without this the border swallowed every click into the
                        // box and the text view never became first responder: the reader could type
                        // only by pressing `e`, and clicking did nothing at all.
                        .allowsHitTesting(false)
                }
                .overlay(alignment: .topLeading) {
                    // A prompt and a caret in the same box is noise, so it goes once the field is live.
                    if empty && !focused {
                        Text(prompt)
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }
                }

            HStack(spacing: 6) {
                if focused {
                    Text("⇥ next · ⎋ done")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
                if answer != .skipped {
                    // Not a peer of typing: the third of the three answers a question takes, which is
                    // why it no longer sits against the box.
                    Button("Skip · s") { skip() }
                        .buttonStyle(.borderless)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .help("You decide — the agent picks")
                }
            }
        }
    }

    /// Names the key that opens the field: this pane is meant to be worked without the pointer, and
    /// "Your answer…" tells a reader nothing about how to get into it (ADR-136).
    private var prompt: String {
        question.choices.isEmpty ? "Press e to write your own answer" : "Press e to add a note"
    }
}

// MARK: - Review

/// The last look before Send: every question with the answer it will send, in the composer's own words
/// so the reader sees what the agent will read. Each row goes back to its question, because a review you
/// cannot act on is a receipt (ADR-132).
private struct ReviewStep: View {
    let round: GrillRound
    @Bindable var model: GrillPaneModel
    let actionable: Bool
    let jump: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Review")
                .font(.system(size: 15, weight: .semibold))
            Text("What will be sent. Pick a row to change it.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.bottom, 2)
            ForEach(Array(round.questions.enumerated()), id: \.element.id) { index, question in
                GrillAnswerRow(
                    question: question,
                    phrase: GrillAnswerComposer.answerPhrase(for: question, answer: round.answers[question.id]),
                    answered: round.answers[question.id]?.isMeaningful == true,
                    focused: actionable && model.reviewFocus == index
                ) { jump(index) } detail: { EmptyView() }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - History

/// A round that can no longer be answered: every question at once, each row opening in place to show
/// the body, the recommendation and what was picked (ADR-133).
///
/// The wizard is a shape for *deciding* — one question, the recommendation loudest, a complete answer
/// advancing. None of that survives a round you cannot answer, and what is left ("what did I decide
/// about the transport?") is reading, which wants everything visible. Disabling the wizard instead left
/// question 1 reachable and the rest not.
private struct HistoryList: View {
    let round: GrillRound
    @Bindable var model: GrillPaneModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(round.questions.enumerated()), id: \.element.id) { index, question in
                let expanded = model.expandedHistory.contains(question.id)
                GrillAnswerRow(
                    question: question,
                    phrase: GrillAnswerComposer.answerPhrase(for: question, answer: round.answers[question.id]),
                    answered: round.answers[question.id]?.isMeaningful == true,
                    focused: model.historyFocus == index,
                    leading: expanded ? "chevron.down" : "chevron.right",
                    help: expanded ? "Collapse — ⏎" : "Show the question — ⏎"
                ) {
                    model.historyFocus = index
                    model.toggleHistory(question)
                } detail: {
                    if expanded { detail(for: question) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func detail(for question: GrillQuestion) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            if !question.body.isEmpty { GrillMarkdown(question.body) }
            if let recommendation = question.recommendation {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .padding(.top, 2)
                    GrillMarkdown(recommendation)
                }
            }
            ForEach(question.choices) { choice in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: picked(choice, in: question) ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 10))
                        .foregroundStyle(picked(choice, in: question) ? Color.accentColor : Color.secondary.opacity(0.6))
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(choice.label)
                            .font(.system(size: 11, weight: picked(choice, in: question) ? .medium : .regular))
                        if let detail = choice.detail {
                            Text(detail).font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.top, 6)
        .padding(.leading, 33)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func picked(_ choice: GrillChoice, in question: GrillQuestion) -> Bool {
        if case .choices(let ids)? = round.answers[question.id] { return ids.contains(choice.id) }
        return false
    }
}

/// One question with the answer it carries — the row the review step and the history list share, since
/// both list every question with its answer and differ only in what pressing one does (ADR-133).
private struct GrillAnswerRow<Detail: View>: View {
    let question: GrillQuestion
    let phrase: String
    let answered: Bool
    let focused: Bool
    var leading: String?
    var help: String = "Go back and change this answer"
    let action: () -> Void
    @ViewBuilder var detail: Detail

    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: action) {
                HStack(alignment: .top, spacing: 7) {
                    if let leading {
                        Image(systemName: leading)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 10)
                            .padding(.top, 4)
                    }
                    Text(question.id)
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 26, alignment: .leading)
                        .padding(.top, 1)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(question.title)
                            .font(.system(size: 12, weight: .medium))
                            .fixedSize(horizontal: false, vertical: true)
                        Text(phrase)
                            .font(.system(size: 11))
                            .foregroundStyle(answered ? .secondary : .tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(help)
            detail
        }
        .background(hovering ? Color.primary.opacity(0.07) : Color.primary.opacity(0.03),
                    in: RoundedRectangle(cornerRadius: 5))
        .overlay {
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(focused ? Color.accentColor.opacity(0.75) : .clear, lineWidth: 1.5)
        }
        .onHover { hovering = $0 }
    }
}

// MARK: - Pieces

/// Why the round on screen cannot be answered, said plainly rather than left to be worked out.
private struct ReadOnlyBanner: View {
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle").font(.system(size: 11))
            Text(text).font(.system(size: 11))
            Spacer(minLength: 0)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, PaneMetrics.padding)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(Color.primary.opacity(0.05))
    }
}

/// What the reader has said about a question, in the smallest thing that can say it.
private struct AnswerBadge: View {
    let answer: GrillAnswer

    private var word: String {
        switch answer {
        case .acceptedRecommendation: "Accepted"
        case .choices: "Chosen"
        case .text: "Your answer"
        case .skipped: "Skipped"
        }
    }

    private var isDecision: Bool { if case .skipped = answer { false } else { true } }

    var body: some View {
        Text(word)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(isDecision ? Color.accentColor : Color.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background((isDecision ? Color.accentColor : Color.secondary).opacity(0.12), in: Capsule())
    }
}

/// One choice. The number is not decoration: it is the key that picks this row, so the keyboard is
/// learnable without a cheat sheet.
private struct ChoiceRow: View {
    let choice: GrillChoice
    let number: Int
    let multiple: Bool
    let picked: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: symbol)
                    .font(.system(size: 12))
                    .foregroundStyle(picked ? Color.accentColor : Color.secondary)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(choice.label)
                            .font(.system(size: 12, weight: picked ? .medium : .regular))
                            .fixedSize(horizontal: false, vertical: true)
                        // The agent's pick wears the accent and nothing else does.
                        if choice.recommended {
                            Text("recommended")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(Color.accentColor)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.accentColor.opacity(0.13), in: Capsule())
                        }
                    }
                    if let detail = choice.detail {
                        Text(detail)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 4)
                Text("\(number)")
                    .font(.system(size: 9, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 13, height: 13)
                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 3))
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background, in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private var symbol: String {
        if multiple { return picked ? "checkmark.square.fill" : "square" }
        return picked ? "largecircle.fill.circle" : "circle"
    }

    private var background: Color {
        if picked { return Color.accentColor.opacity(0.13) }
        return hovering ? Color.primary.opacity(0.06) : Color.primary.opacity(0.03)
    }
}

/// Inline markdown, the way the PR panel renders a body's paragraphs — enough for the emphasis and code
/// spans a question actually uses, without pulling a renderer into the panel.
private struct GrillMarkdown: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        let attributed = try? AttributedString(markdown: text,
                                               options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        return (attributed.map { Text($0) } ?? Text(text))
            .font(.system(size: 12))
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
