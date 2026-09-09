import Foundation
import Testing
@testable import ClinicCore

/// A fixed, non-UTC calendar so "next Monday at 09:00" means the same thing on every machine.
private func calendar(_ tz: String = "America/New_York") -> Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: tz)!
    c.locale = Locale(identifier: "en_US_POSIX")
    return c
}

private func date(_ s: String, _ cal: Calendar = calendar()) -> Date {
    let f = DateFormatter()
    f.calendar = cal; f.timeZone = cal.timeZone; f.locale = cal.locale
    f.dateFormat = "yyyy-MM-dd HH:mm"
    return f.date(from: s)!
}

private func string(_ d: Date, _ cal: Calendar = calendar()) -> String {
    let f = DateFormatter()
    f.calendar = cal; f.timeZone = cal.timeZone; f.locale = cal.locale
    f.dateFormat = "yyyy-MM-dd HH:mm"
    return f.string(from: d)
}

struct CronParsingTests {
    @Test func parsesTheFieldForms() throws {
        #expect(try CronSchedule("0 * * * *").minutes == [0])
        #expect(try CronSchedule("*/15 * * * *").minutes == [0, 15, 30, 45])
        #expect(try CronSchedule("0 9-17 * * *").hours == Set(9...17))
        #expect(try CronSchedule("0 0-12/4 * * *").hours == [0, 4, 8, 12])
        #expect(try CronSchedule("0 0 1,15 * *").daysOfMonth == [1, 15])
        #expect(try CronSchedule("0 0 * jan,jul *").months == [1, 7])
        #expect(try CronSchedule("0 0 * * mon-fri").daysOfWeek == [1, 2, 3, 4, 5])
    }

    /// `5/15` is "from 5 to the end of the range, every 15" — not just 5.
    @Test func bareValueWithAStepRunsToTheEndOfTheRange() throws {
        #expect(try CronSchedule("5/15 * * * *").minutes == [5, 20, 35, 50])
        #expect(try CronSchedule("5 * * * *").minutes == [5])
    }

    /// Cron accepts both 0 and 7 for Sunday; matching should only ever have to know about 0.
    @Test func sundayIsNormalisedToZero() throws {
        #expect(try CronSchedule("0 0 * * 7").daysOfWeek == [0])
        #expect(try CronSchedule("0 0 * * 0").daysOfWeek == [0])
        #expect(try CronSchedule("0 0 * * 0,7").daysOfWeek == [0])
    }

    @Test func rejectsWhatItCannotHonour() {
        #expect(throws: CronSchedule.ParseError.self) { try CronSchedule("") }
        #expect(throws: CronSchedule.ParseError.self) { try CronSchedule("* * * *") }          // four fields
        #expect(throws: CronSchedule.ParseError.self) { try CronSchedule("0 0 * * * *") }      // six: seconds
        #expect(throws: CronSchedule.ParseError.self) { try CronSchedule("60 * * * *") }       // out of range
        #expect(throws: CronSchedule.ParseError.self) { try CronSchedule("0 25 * * *") }
        #expect(throws: CronSchedule.ParseError.self) { try CronSchedule("0 * * * nope") }
        #expect(throws: CronSchedule.ParseError.self) { try CronSchedule("*/0 * * * *") }      // zero step
        #expect(throws: CronSchedule.ParseError.self) { try CronSchedule("0 17-9 * * *") }     // reversed range
    }
}

struct CronNextDateTests {
    @Test func findsTheNextFire() throws {
        let cal = calendar()
        let daily = try CronSchedule("30 8 * * *")
        #expect(string(daily.nextDate(after: date("2026-09-09 07:00"), calendar: cal)!) == "2026-09-09 08:30")
        #expect(string(daily.nextDate(after: date("2026-09-09 09:00"), calendar: cal)!) == "2026-09-10 08:30")
        // Exactly on the fire is *not* a match: a schedule fires strictly after the given instant,
        // which is what stops a run re-firing itself the moment it records lastFiredAt.
        #expect(string(daily.nextDate(after: date("2026-09-09 08:30"), calendar: cal)!) == "2026-09-10 08:30")
    }

    @Test func everySixHoursWalksTheDay() throws {
        let cal = calendar()
        let s = try CronSchedule("0 */6 * * *")
        #expect(string(s.nextDate(after: date("2026-09-09 05:59"), calendar: cal)!) == "2026-09-09 06:00")
        #expect(string(s.nextDate(after: date("2026-09-09 18:01"), calendar: cal)!) == "2026-09-10 00:00")
    }

    @Test func weekdayScheduleSkipsTheWeekend() throws {
        let cal = calendar()
        let s = try CronSchedule("30 8 * * 1-5")   // 2026-09-11 is a Friday
        #expect(string(s.nextDate(after: date("2026-09-11 09:00"), calendar: cal)!) == "2026-09-14 08:30")
    }

    /// Vixie cron's least obvious rule: with *both* day fields restricted the two are OR-ed.
    @Test func dayOfMonthAndDayOfWeekAreOredWhenBothRestricted() throws {
        let cal = calendar()
        let both = try CronSchedule("0 0 1 * mon")
        // 2026-09-09 is a Wednesday, so the weekday arm fires first: Monday the 14th.
        #expect(string(both.nextDate(after: date("2026-09-09 12:00"), calendar: cal)!) == "2026-09-14 00:00")
        // From Monday the 28th the next Monday is 5 October, but 1 October — a Thursday — matches the
        // day-of-month arm and comes first. Only the OR produces this; an AND would give nothing in
        // September or October at all.
        #expect(string(both.nextDate(after: date("2026-09-28 12:00"), calendar: cal)!) == "2026-10-01 00:00")
        // And the weekday arm still fires on a day that is not the 1st.
        #expect(string(both.nextDate(after: date("2026-10-01 12:00"), calendar: cal)!) == "2026-10-05 00:00")

        // With only day-of-month restricted, weekday contributes nothing.
        let domOnly = try CronSchedule("0 0 1 * *")
        #expect(string(domOnly.nextDate(after: date("2026-09-09 12:00"), calendar: cal)!) == "2026-10-01 00:00")
    }

    /// The honest impossible case, and the reason this returns an optional rather than looping.
    @Test func returnsNilWhenNothingCanEverMatch() throws {
        #expect(try CronSchedule("0 0 30 2 *").nextDate(after: date("2026-09-09 12:00"), calendar: calendar()) == nil)
    }

    /// Spring forward: 02:30 does not exist on 2026-03-08 in New York. Cron runs the job once, late,
    /// rather than skipping the day — and the result must still be strictly after the start.
    @Test func springForwardGapStillProducesAFire() throws {
        let cal = calendar()
        let s = try CronSchedule("30 2 * * *")
        let next = s.nextDate(after: date("2026-03-08 00:10"), calendar: cal)
        let after = try #require(next)
        #expect(after > date("2026-03-08 00:10"))
        #expect(after < date("2026-03-09 00:00"))
    }

    /// Fall back repeats 01:30. Walking forward from the last fire must never return it twice.
    @Test func fallBackDoesNotRepeatAFire() throws {
        let cal = calendar()
        let s = try CronSchedule("30 1 * * *")
        var cursor = date("2026-11-01 00:00")
        var seen: [Date] = []
        for _ in 0..<3 {
            let next = try #require(s.nextDate(after: cursor, calendar: cal))
            #expect(next > cursor)
            seen.append(next)
            cursor = next
        }
        #expect(Set(seen).count == 3)
    }

    @Test func findsTheMostRecentFireBeforeAnInstant() throws {
        let cal = calendar()
        let daily = try CronSchedule("30 8 * * *")
        #expect(string(daily.lastDate(atOrBefore: date("2026-09-09 12:00"), calendar: cal)!) == "2026-09-09 08:30")
        #expect(string(daily.lastDate(atOrBefore: date("2026-09-09 08:00"), calendar: cal)!) == "2026-09-08 08:30")
        // Exactly on a fire counts as that fire — this answers "when should it last have run".
        #expect(string(daily.lastDate(atOrBefore: date("2026-09-09 08:30"), calendar: cal)!) == "2026-09-09 08:30")

        let weekdays = try CronSchedule("30 8 * * 1-5")
        // 2026-09-13 is a Sunday, so the last fire was Friday the 11th.
        #expect(string(weekdays.lastDate(atOrBefore: date("2026-09-13 12:00"), calendar: cal)!) == "2026-09-11 08:30")

        #expect(try CronSchedule("0 0 30 2 *").lastDate(atOrBefore: date("2026-09-09 12:00"), calendar: cal) == nil)
    }

    @Test func missedFiresAreEnumeratedAndBounded() throws {
        let cal = calendar()
        let hourly = try CronSchedule("0 * * * *")
        let missed = hourly.dates(after: date("2026-09-09 00:00"), through: date("2026-09-09 06:00"), calendar: cal)
        #expect(missed.count == 6)
        #expect(string(missed.first!) == "2026-09-09 01:00")
        // A weekend of missed hourly fires is a fact, not 48 launches: the walk is capped.
        let weekend = hourly.dates(after: date("2026-09-05 00:00"), through: date("2026-09-08 00:00"), calendar: cal, limit: 10)
        #expect(weekend.count == 10)
    }
}

struct CronPresetTests {
    @Test func presetsRoundTrip() {
        #expect(CronSchedule.hourly.preset == .hourly)
        #expect(CronSchedule.everyNHours(6).preset == .everyNHours(6))
        #expect(CronSchedule.daily(hour: 8, minute: 30).preset == .daily(hour: 8, minute: 30))
        #expect(CronSchedule.weekly(weekday: 5, hour: 16, minute: 0).preset == .weekly(weekday: 5, hour: 16, minute: 0))
    }

    /// A hand-typed expression that happens to *be* a preset opens the picker on that preset, which
    /// is the point of recognising by what it matches rather than by how it was written.
    @Test func recognisesAPresetTypedByHand() throws {
        #expect(try CronSchedule("0 0-23 * * *").preset == .hourly)
        #expect(try CronSchedule("0 0,6,12,18 * * *").preset == .everyNHours(6))
    }

    @Test func anythingElseStaysCustom() throws {
        #expect(try CronSchedule("0 9-17 * * 1-5").preset == .custom)
        #expect(try CronSchedule("*/15 * * * *").preset == .custom)
        #expect(try CronSchedule("0 3,7,19 * * *").preset == .custom)   // uneven stride
        #expect(try CronSchedule("0 9-17 * * 1-5").summary() == "0 9-17 * * 1-5")
    }

    /// Three of the eight shipped templates use a weekday range, so a gallery that falls back to raw
    /// cron for it shows tiles that speak cron. Caught on the first smoke run.
    @Test func weekdayShapesArePhrasedNotPrinted() throws {
        let cal = calendar()
        let loc = cal.locale!
        // Times are compared loosely on purpose: Foundation puts a NARROW NO-BREAK SPACE (U+202F)
        // before AM/PM on macOS 15, so pinning the literal would be testing Foundation's typography
        // rather than the phrasing.
        func summary(_ e: String) throws -> String { try CronSchedule(e).summary(calendar: cal, locale: loc) }
        #expect(try summary("30 8 * * 1-5").hasPrefix("Every weekday at 8:30"))
        #expect(try summary("0 18 * * 1-5").hasPrefix("Every weekday at 6:00"))
        #expect(try summary("0 9 * * 0,6").hasPrefix("Every weekend day at 9:00"))
        #expect(try CronSchedule("0 9 * * mon,wed").summary(calendar: cal, locale: loc).hasPrefix("Every Mon, Wed at"))
        // Still cron when it genuinely is not phraseable.
        #expect(try CronSchedule("*/15 9-17 * * *").summary(calendar: cal, locale: loc) == "*/15 9-17 * * *")
    }

    /// Every shipped template should read as English in the gallery, not as an expression.
    @Test func noBundledTemplateShowsRawCron() {
        for t in AutomationTemplate.bundled {
            let summary = t.parsedSchedule?.summary() ?? t.schedule
            #expect(summary != t.schedule, "\(t.id) falls back to raw cron: \(summary)")
        }
    }

    @Test func summaryReadsAsEnglish() {
        let cal = calendar()
        #expect(CronSchedule.hourly.summary(calendar: cal, locale: cal.locale!) == "Every hour")
        #expect(CronSchedule.everyNHours(6).summary(calendar: cal, locale: cal.locale!) == "Every 6 hours")
        #expect(CronSchedule.daily(hour: 8, minute: 30).summary(calendar: cal, locale: cal.locale!).hasPrefix("Every day at"))
        #expect(CronSchedule.weekly(weekday: 5, hour: 16, minute: 0).summary(calendar: cal, locale: cal.locale!).hasPrefix("Every Friday at"))
    }
}

struct AutomationLaunchTests {
    private func automation(_ mode: Automation.PermissionMode, target: Automation.Target = .project(path: "/repo")) -> Automation {
        Automation(name: "Morning triage", prompt: "Triage the repo", target: target,
                   schedule: CronSchedule.daily(hour: 8, minute: 30), model: "opus",
                   permissionMode: mode)
    }

    @Test func backgroundLaunchCarriesNamePostureAndPrompt() {
        let l = AutomationLauncher.launch(for: automation(.plan), fireDate: date("2026-09-09 08:30"),
                                          settingsFilePath: "/tmp/h.json")
        let args = l.arguments
        #expect(args.first == "Triage the repo")            // prompt first: variadic options would eat it
        #expect(args.contains("--bg"))
        #expect(!args.contains("--session-id"))             // the CLI refuses one under --bg
        #expect(args.contains("--permission-mode") && args.contains("plan"))
        #expect(args.contains("--model") && args.contains("opus"))
        #expect(args.contains("-n"))
        #expect(!args.contains("-w"))                       // read-only: nothing to isolate
    }

    @Test func anEditingAutomationGetsAFreshWorktreePerRun() {
        let a = automation(.acceptEdits)
        let first = AutomationLauncher.launch(for: a, fireDate: date("2026-09-09 08:30"), settingsFilePath: "/tmp/h.json")
        let second = AutomationLauncher.launch(for: a, fireDate: date("2026-09-10 08:30"), settingsFilePath: "/tmp/h.json")
        let name1 = first.worktreeName
        let name2 = second.worktreeName
        #expect(first.arguments.contains("-w"))
        #expect(name1 != nil && name1 != name2)
        #expect(name1!.hasPrefix("auto-morning-triage-"))
    }

    /// A chat automation has no repository, so it never gets a worktree whatever its posture.
    @Test func aChatAutomationNeverGetsAWorktree() {
        let l = AutomationLauncher.launch(for: automation(.acceptEdits, target: .chat),
                                          fireDate: date("2026-09-09 08:30"), settingsFilePath: "/tmp/h.json")
        #expect(!l.arguments.contains("-w"))
    }

    /// Verbatim `--bg` stdout, captured from the real CLI on 2026-09-09.
    @Test func readsTheShortIdBackFromStdout() {
        let out = """
        Starting background service…
        backgrounded · e6f9d349 · Morning triage · 9 Sep 2026 at 08:30
          claude agents             list sessions
          claude attach e6f9d349    open in this terminal
        """
        #expect(AutomationLauncher.parseAgentId(out) == "e6f9d349")
        #expect(AutomationLauncher.parseAgentId("Starting background service…\n") == nil)
    }

    /// The short id is the session UUID's first eight characters, so binding is a prefix test rather
    /// than a guess bounded by a time window.
    @Test func bindsTheSessionIdByPrefix() {
        #expect(AutomationLauncher.sessionId(SessionID("e6f9d349-dc80-4619-9704-9f75cf2ef4a0"), matches: "e6f9d349"))
        #expect(!AutomationLauncher.sessionId(SessionID("11111111-dc80-4619-9704-9f75cf2ef4a0"), matches: "e6f9d349"))
    }
}

struct AutomationTemplateTests {
    /// Every shipped template must parse, or the gallery ships a tile that cannot be used.
    @Test func bundledTemplatesAreAllUsable() {
        #expect(AutomationTemplate.bundledProblems.isEmpty, "\(AutomationTemplate.bundledProblems)")
        #expect(AutomationTemplate.bundled.count >= 8)
        for t in AutomationTemplate.bundled {
            #expect(t.parsedSchedule != nil, "\(t.id) schedule")
            #expect(!t.blurb.isEmpty && !t.name.isEmpty && !t.icon.isEmpty, "\(t.id) metadata")
            #expect(t.prompt.count > 80, "\(t.id) prompt looks like a stub")
            #expect(t.parsedSchedule?.nextDate(after: Date()) != nil, "\(t.id) never fires")
        }
        #expect(Set(AutomationTemplate.bundled.map(\.id)).count == AutomationTemplate.bundled.count)
    }

    /// A chat-scoped template must not ask for a posture that implies a worktree it cannot have.
    @Test func templatePosturesAreCoherent() {
        for t in AutomationTemplate.bundled where t.scope == .chat {
            #expect(t.permissionMode == .plan, "\(t.id) is chat-scoped but wants to write")
        }
        #expect(!AutomationTemplate.bundled.contains { $0.permissionMode == .bypassPermissions },
                "bypassPermissions is never inherited from a template")
    }

    @Test func buildsAnAutomationFromATemplate() throws {
        let t = try #require(AutomationTemplate.bundled.first { $0.id == "morning-triage" })
        let a = t.makeAutomation(target: .project(path: "/repo"))
        #expect(a.templateId == "morning-triage")
        #expect(a.permissionMode == .plan)
        #expect(!a.permissionMode.wantsWorktree)
        #expect(a.projectPath == "/repo")
        #expect(a.schedule.expression == t.schedule)
    }
}

struct AutomationSchedulerTests {
    private func hourly(lastFired: Date?, created: Date, catchUp: Automation.CatchUpPolicy = .runOnce,
                        enabled: Bool = true) -> Automation {
        Automation(name: "Hourly", prompt: "p", target: .chat, schedule: CronSchedule.hourly,
                   isEnabled: enabled, catchUp: catchUp, createdAt: created, lastFiredAt: lastFired)
    }

    @Test func waitsWhenNothingIsDue() {
        let cal = calendar()
        let a = hourly(lastFired: date("2026-09-09 10:00"), created: date("2026-09-01 00:00"))
        #expect(AutomationScheduler.decide(for: a, now: date("2026-09-09 10:30"), calendar: cal)
                == .wait(until: date("2026-09-09 11:00")))
    }

    @Test func firesWhenDue() {
        let cal = calendar()
        let a = hourly(lastFired: date("2026-09-09 10:00"), created: date("2026-09-01 00:00"))
        #expect(AutomationScheduler.decide(for: a, now: date("2026-09-09 11:00"), calendar: cal)
                == .fire(scheduledFor: date("2026-09-09 11:00")))
    }

    /// The rule the ADR is most insistent about: a weekend of missed hourly fires is **one** run.
    @Test func missedFiresCollapseToASingleRun() {
        let cal = calendar()
        let a = hourly(lastFired: date("2026-09-05 09:00"), created: date("2026-09-01 00:00"))
        let decision = AutomationScheduler.decide(for: a, now: date("2026-09-07 14:30"), calendar: cal)
        // 53 fires were missed; the decision is one, for the most recent of them.
        #expect(decision == .fire(scheduledFor: date("2026-09-07 14:00")))
    }

    @Test func skipPolicyRecordsTheMissRatherThanRunning() {
        let cal = calendar()
        let a = hourly(lastFired: date("2026-09-05 09:00"), created: date("2026-09-01 00:00"), catchUp: .skip)
        #expect(AutomationScheduler.decide(for: a, now: date("2026-09-07 14:30"), calendar: cal)
                == .skip(reason: .missedWhileClosed, scheduledFor: date("2026-09-07 14:00")))
    }

    /// An on-time fire is not a catch-up, so `skip` must not swallow it.
    @Test func skipPolicyStillFiresOnTime() {
        let cal = calendar()
        let a = hourly(lastFired: date("2026-09-09 10:00"), created: date("2026-09-01 00:00"), catchUp: .skip)
        #expect(AutomationScheduler.decide(for: a, now: date("2026-09-09 11:00"), calendar: cal)
                == .fire(scheduledFor: date("2026-09-09 11:00")))
    }

    @Test func firesDoNotStack() {
        let cal = calendar()
        let a = hourly(lastFired: date("2026-09-09 10:00"), created: date("2026-09-01 00:00"))
        #expect(AutomationScheduler.decide(for: a, now: date("2026-09-09 11:00"), activeRun: true, calendar: cal)
                == .skip(reason: .alreadyRunning, scheduledFor: date("2026-09-09 11:00")))
    }

    /// A schedule created at noon must not immediately "catch up" this morning's fire.
    @Test func neverFiresForATimeBeforeItExisted() {
        let cal = calendar()
        let a = Automation(name: "Morning", prompt: "p", target: .chat,
                           schedule: CronSchedule.daily(hour: 8, minute: 30),
                           createdAt: date("2026-09-09 12:00"))
        #expect(AutomationScheduler.decide(for: a, now: date("2026-09-09 12:01"), calendar: cal)
                == .wait(until: date("2026-09-10 08:30")))
    }

    @Test func disabledIsIdle() {
        let cal = calendar()
        let a = hourly(lastFired: nil, created: date("2026-09-01 00:00"), enabled: false)
        #expect(AutomationScheduler.decide(for: a, now: date("2026-09-09 11:00"), calendar: cal) == .idle)
    }

    @Test func nextWakeUpIsTheEarliestAcrossAutomations() {
        let cal = calendar()
        let a = hourly(lastFired: date("2026-09-09 10:00"), created: date("2026-09-01 00:00"))
        var b = a
        b.id = UUID()
        b.schedule = CronSchedule.daily(hour: 10, minute: 5)
        var c = a
        c.id = UUID()
        c.isEnabled = false
        c.schedule = CronSchedule.everyNHours(1)
        #expect(AutomationScheduler.nextWakeUp(for: [a, b, c], after: date("2026-09-09 10:01"), calendar: cal)
                == date("2026-09-09 10:05"))
        #expect(AutomationScheduler.nextWakeUp(for: [], after: date("2026-09-09 10:01"), calendar: cal) == nil)
    }

    /// A year-old lastFiredAt must not walk a year of minutes.
    @Test func aVeryStaleAutomationDecidesQuickly() {
        let cal = calendar()
        let a = Automation(name: "Every minute", prompt: "p", target: .chat,
                           schedule: try! CronSchedule("* * * * *"),
                           createdAt: date("2025-01-01 00:00"), lastFiredAt: date("2025-01-01 00:00"))
        let started = Date()
        let decision = AutomationScheduler.decide(for: a, now: date("2026-09-09 11:00"), calendar: cal)
        // Was 2.25 s when this stepped through every missed fire; the backwards day walk makes it
        // microseconds. The bound is deliberately tight so a regression to the old shape fails here.
        #expect(Date().timeIntervalSince(started) < 0.1)
        #expect(decision == .fire(scheduledFor: date("2026-09-09 11:00")))
    }
}
