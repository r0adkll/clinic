import Foundation

extension GrillRound {
    /// A round the reader can post themselves, from the Panel menu or the pane's empty state (ADR-133).
    ///
    /// It exists for two reasons that turn out to be the same reason: a reader who has never been
    /// grilled cannot otherwise look at the pane, and anyone changing the pane needs a real agent or a
    /// hand-written socket call to test it. It goes through `postGrillRound` like any other round, so
    /// it exercises what it demonstrates.
    ///
    /// One question of every shape the pane can draw, deliberately: a recommendation on its own, a
    /// single-select with a recommended choice, a multi-select, a question with neither, and a body
    /// long enough to be worth reading.
    public static func sample(now: Date = Date()) -> GrillRound {
        GrillRound(
            index: nil,
            topic: "Sample round",
            questions: [
                GrillQuestion(
                    id: "Q1",
                    title: "Accepting a recommendation",
                    body: """
                        This question has a recommendation and nothing else, which is the most common \
                        shape in a real grill. Press **⏎** to take it — the answer is recorded and the \
                        pane moves to the next question, so a round you agree with is one keystroke per \
                        question.

                        Press **e** instead to write your own answer, or **s** to skip it and let the \
                        agent decide.
                        """,
                    recommendation: "take the recommendation with ⏎, and move on"),

                GrillQuestion(
                    id: "Q2",
                    title: "Picking one of several choices",
                    body: "Press **1**, **2** or **3**, or click a row. Picking one answers the question and moves on, because a single choice is a complete answer.",
                    recommendation: "pick the recommended choice",
                    choices: [
                        GrillChoice(id: "1", label: "The recommended one",
                                    detail: "Marked with the accent, and the only row that is", recommended: true),
                        GrillChoice(id: "2", label: "A second choice", detail: "With a line of detail under it"),
                        GrillChoice(id: "3", label: "A third choice"),
                    ]),

                GrillQuestion(
                    id: "Q3",
                    title: "Picking several at once",
                    body: "Ticking a box does **not** move on, because you may not be finished. Press **⏎** or **⇥** when you are.",
                    choices: [
                        GrillChoice(id: "1", label: "One of these"),
                        GrillChoice(id: "2", label: "Another of these"),
                        GrillChoice(id: "3", label: "And a third"),
                    ],
                    allowsMultiple: true),

                GrillQuestion(
                    id: "Q4",
                    title: "A question with no recommendation",
                    body: "Nothing to accept here, so **⏎** opens the field below instead of taking an answer. **⎋** puts the keyboard back without losing what you typed; **⇥** commits it and moves on."),
            ],
            postedAt: now,
            source: .tool)
    }
}
