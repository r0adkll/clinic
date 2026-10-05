import Foundation

/// What a child session handed its parent through `report_to_parent` (ADR-182), kept per parent.
public struct SessionReport: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var from: SessionID
    public var message: String
    public var at: Date
    /// When it was pasted into the parent; nil while held.
    public var deliveredAt: Date?

    public init(id: UUID = UUID(), from: SessionID, message: String, at: Date = Date(), deliveredAt: Date? = nil) {
        self.id = id; self.from = from; self.message = message; self.at = at; self.deliveredAt = deliveredAt
    }

    public var isPending: Bool { deliveredAt == nil }

    /// Reports kept per parent; the oldest delivered ones go first.
    public static let maxPerParent = 50
}

/// A child's reporting state (ADR-182). An entry exists only for a child that reports to its parent.
public struct ChildReporting: Codable, Sendable, Equatable {
    /// The user turned reporting off for this child: reports are held, not delivered.
    public var paused = false
    /// The one reminder a child that stopped without reporting gets.
    public var remindedAt: Date?
    /// The first report, so the reminder knows it is no longer needed.
    public var reportedAt: Date?

    public init(paused: Bool = false, remindedAt: Date? = nil, reportedAt: Date? = nil) {
        self.paused = paused; self.remindedAt = remindedAt; self.reportedAt = reportedAt
    }
}

/// The words of the protocol (ADR-182): the child's brief, the header a report wears in the parent's
/// terminal, the reminder, and when a parent can take a paste.
public enum SessionReporting {
    /// Appended to the child's system prompt. `peerName` is the parent's CLI name for direct messages;
    /// nil leaves that sentence out rather than guessing. `reporting` adds the report instruction.
    public static func brief(parentTitle: String, peerName: String?, directory: String, reporting: Bool) -> String {
        var out = "You were started by Clinic session \"\(parentTitle)\""
        if let peerName, !peerName.isEmpty { out += " (peer name \(peerName))" }
        out += " working in \(directory)."
        if reporting {
            out += " When your work is done, call report_to_parent with a report written for that session: what you did, what you found, what it should do next."
            if let peerName, !peerName.isEmpty { out += " For progress before then you may message \(peerName) directly." }
        }
        return out
    }

    /// The first line of a delivered report: who it is from, so the parent and the reader both know.
    public static func header(childTitle: String, project: String?, id: SessionID) -> String {
        let short = String(id.rawValue.prefix(8))
        let place = project.map { "\($0), \(short)" } ?? short
        return "Report from child session \"\(childTitle)\" (\(place)):"
    }

    /// Header and message as one pasted prompt.
    public static func compose(header: String, message: String) -> String {
        header + "\n" + message.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static let reminder = "Reminder from Clinic: you have not reported to your parent session. Call report_to_parent with your report now."

    /// Whether a paste lands as a prompt: at the prompt, or working (the CLI queues it). Not while a
    /// permission prompt or dialog reads keys, not while starting, not once exited.
    public static func canDeliver(state: SessionState?, waitingOn: String?) -> Bool {
        state == .working || SessionStateMachine.acceptsPrompt(state, waitingOn: waitingOn)
    }
}
