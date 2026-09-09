import Foundation

/// What to do about one automation at a given instant (ADR-095).
///
/// Pure and static on purpose: "a weekend of missed hourly fires is one run, not forty-eight" and
/// "a fire while the previous run is still working is skipped, not queued" are the two rules most
/// likely to be got wrong, and both are unit tests here rather than behaviour to observe on a Monday.
public enum AutomationScheduler {
    public enum Decision: Equatable, Sendable {
        /// Launch, for this scheduled time. May be earlier than now on a catch-up.
        case fire(scheduledFor: Date)
        /// Due, but deliberately not launched. Recorded in the run history with the reason rather
        /// than silently dropped.
        case skip(reason: AutomationRun.SkipReason, scheduledFor: Date)
        /// Nothing due; the next fire is at this date.
        case wait(until: Date)
        /// Disabled, or an expression that can never match again.
        case idle
    }

    /// A fire this recent counts as "on time" rather than missed — the timer can wake a second or two
    /// late, and a run started 3 s after its minute is not a catch-up.
    public static let onTimeGrace: TimeInterval = 90
    /// How far back `nextWakeUp` looks when an automation has been idle for a long time, so a
    /// months-stale `lastFiredAt` cannot push the search past `CronSchedule`'s own day cap.
    public static let missedLookback: TimeInterval = 7 * 24 * 60 * 60

    public static func decide(for automation: Automation, now: Date = Date(),
                              activeRun: Bool = false, calendar: Calendar = .current) -> Decision {
        guard automation.isEnabled else { return .idle }

        // Never fire for a time before the automation existed: a schedule created at noon must not
        // immediately "catch up" this morning's run.
        let since = automation.lastFiredAt ?? automation.createdAt
        guard let firstDue = automation.schedule.nextDate(after: since, calendar: calendar) else { return .idle }
        guard firstDue <= now else { return .wait(until: firstDue) }

        let scheduledFor = latestDue(automation.schedule, firstDue: firstDue, now: now, calendar: calendar)

        if activeRun { return .skip(reason: .alreadyRunning, scheduledFor: scheduledFor) }

        let wasMissed = now.timeIntervalSince(scheduledFor) > onTimeGrace
        if wasMissed, automation.catchUp == .skip {
            return .skip(reason: .missedWhileClosed, scheduledFor: scheduledFor)
        }
        return .fire(scheduledFor: scheduledFor)
    }

    /// The most recent fire at or before `now`. Several missed fires collapse to this one — the
    /// automation runs once and its `lastFiredAt` jumps forward, so the backlog cannot re-accumulate.
    ///
    /// Delegates to `CronSchedule.lastDate`, which walks days backwards rather than stepping through
    /// every missed fire: a year-stale `* * * * *` decides in microseconds instead of seconds.
    static func latestDue(_ schedule: CronSchedule, firstDue: Date, now: Date, calendar: Calendar) -> Date {
        guard let last = schedule.lastDate(atOrBefore: now, calendar: calendar), last >= firstDue else {
            return firstDue
        }
        return last
    }

    /// The soonest moment the caller needs to wake up, across every automation. Nil when nothing is
    /// scheduled at all, which is the app's cue to arm no timer rather than poll.
    public static func nextWakeUp(for automations: [Automation], after date: Date = Date(),
                                  calendar: Calendar = .current) -> Date? {
        automations
            .filter(\.isEnabled)
            .compactMap { a -> Date? in
                let since = max(a.lastFiredAt ?? a.createdAt, date.addingTimeInterval(-missedLookback))
                return a.schedule.nextDate(after: since, calendar: calendar)
            }
            .min()
    }
}
