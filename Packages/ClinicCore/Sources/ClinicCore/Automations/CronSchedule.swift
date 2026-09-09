import Foundation

/// A five-field cron expression and the walk that finds its next fire (ADR-095).
///
/// Cron is Clinic's *single* representation of a schedule: the preset picker in the UI builds one of
/// these and reads itself back out of `preset`, so there is no parallel model to keep in step. Pure
/// Foundation and pure functions — "the next run of `0 */6 * * *` after a spring-forward Sunday" is a
/// unit test, not something to discover in production.
///
/// Supported syntax is Vixie cron's, minus the parts nothing here needs: `*`, `n`, `a-b`, `*/step`,
/// `a-b/step`, comma-separated lists of any of those, and three-letter month and day names. Not
/// supported, deliberately: `@reboot` and friends (no meaning for a wall-clock scheduler), `L`/`W`/`#`
/// (Quartz extensions, not cron), and seconds (a six-field expression is rejected rather than
/// silently misread as five).
public struct CronSchedule: Sendable, Hashable, Codable, CustomStringConvertible {
    public let minutes: Set<Int>        // 0–59
    public let hours: Set<Int>          // 0–23
    public let daysOfMonth: Set<Int>    // 1–31
    public let months: Set<Int>         // 1–12
    public let daysOfWeek: Set<Int>     // 0–6, Sunday = 0
    /// The expression as written, kept verbatim so the custom field shows the user their own text.
    public let expression: String
    /// True when the field was literally `*`. Cron's day matching depends on this, not on whether the
    /// set happens to contain everything: `*/1` and `*` mean the same days but not the same rule.
    let dayOfMonthRestricted: Bool
    let dayOfWeekRestricted: Bool

    public var description: String { expression }

    public enum ParseError: Error, Equatable, Sendable, CustomStringConvertible {
        case wrongFieldCount(Int)
        case badField(field: String, value: String)
        case emptyExpression

        public var description: String {
            switch self {
            case .emptyExpression: "A schedule needs five fields: minute hour day month weekday."
            case .wrongFieldCount(let n):
                "A cron expression has five fields (minute hour day month weekday); this has \(n)."
            case .badField(let field, let value): "\(value) is not a valid \(field)."
            }
        }
    }

    // MARK: - Parsing

    public init(_ expression: String) throws {
        let trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ParseError.emptyExpression }
        let fields = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
        guard fields.count == 5 else { throw ParseError.wrongFieldCount(fields.count) }

        minutes = try Self.parse(fields[0], range: 0...59, name: "minute")
        hours = try Self.parse(fields[1], range: 0...23, name: "hour")
        daysOfMonth = try Self.parse(fields[2], range: 1...31, name: "day of month")
        months = try Self.parse(fields[3], range: 1...12, name: "month", names: Self.monthNames)
        // Cron accepts 7 for Sunday as well as 0; normalise so matching only has to know about 0.
        let rawWeekdays = try Self.parse(fields[4], range: 0...7, name: "day of week", names: Self.dayNames)
        daysOfWeek = Set(rawWeekdays.map { $0 == 7 ? 0 : $0 })

        self.expression = trimmed
        dayOfMonthRestricted = fields[2] != "*"
        dayOfWeekRestricted = fields[4] != "*"
    }

    private static let monthNames = ["jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6,
                                     "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12]
    private static let dayNames = ["sun": 0, "mon": 1, "tue": 2, "wed": 3, "thu": 4, "fri": 5, "sat": 6]

    private static func parse(_ field: String, range: ClosedRange<Int>, name: String,
                              names: [String: Int] = [:]) throws -> Set<Int> {
        var out: Set<Int> = []
        for part in field.split(separator: ",") {
            let piece = String(part).lowercased()
            guard !piece.isEmpty else { throw ParseError.badField(field: name, value: field) }

            // Split off a `/step` suffix first: it applies to whatever precedes it.
            let stepSplit = piece.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
            let base = String(stepSplit[0])
            var step = 1
            if stepSplit.count == 2 {
                guard let s = Int(stepSplit[1]), s > 0 else { throw ParseError.badField(field: name, value: field) }
                step = s
            }

            let bounds: ClosedRange<Int>
            if base == "*" {
                bounds = range
            } else if base.contains("-") {
                let ends = base.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
                guard ends.count == 2,
                      let lo = value(String(ends[0]), names), let hi = value(String(ends[1]), names),
                      range.contains(lo), range.contains(hi), lo <= hi
                else { throw ParseError.badField(field: name, value: field) }
                bounds = lo...hi
            } else {
                guard let v = value(base, names), range.contains(v) else {
                    throw ParseError.badField(field: name, value: field)
                }
                // A bare `n/step` means "from n to the end of the range, every step" — `5/15` is
                // 5,20,35,50, not just 5. A bare `n` is only itself.
                bounds = step == 1 ? v...v : v...range.upperBound
            }
            for v in stride(from: bounds.lowerBound, through: bounds.upperBound, by: step) { out.insert(v) }
        }
        guard !out.isEmpty else { throw ParseError.badField(field: name, value: field) }
        return out
    }

    private static func value(_ s: String, _ names: [String: Int]) -> Int? {
        if let n = Int(s) { return n }
        return names[s]
    }

    // MARK: - Matching

    /// Cron's day rule, which is not the obvious one: when *both* day-of-month and day-of-week are
    /// restricted the two are OR-ed, so `0 0 1 * mon` fires on the 1st **and** every Monday. When one
    /// is `*` it contributes nothing and the other decides alone.
    func matches(dateComponents c: DateComponents) -> Bool {
        guard let month = c.month, let day = c.day, let weekday = c.weekday else { return false }
        guard months.contains(month) else { return false }
        let dom = daysOfMonth.contains(day)
        let dow = daysOfWeek.contains(weekday - 1)   // Calendar's weekday is 1-based from Sunday
        switch (dayOfMonthRestricted, dayOfWeekRestricted) {
        case (true, true): return dom || dow
        case (true, false): return dom
        case (false, true): return dow
        case (false, false): return true
        }
    }

    /// The first fire strictly after `date`, or nil if the expression cannot match within `searchDays`
    /// (`0 0 30 2 *` — the 30th of February — is the honest case, and the reason this returns an
    /// optional rather than looping forever).
    ///
    /// Searches day by day and then only the hours and minutes the expression names, so the worst case
    /// is a few hundred iterations rather than the ~527,000 a minute-by-minute walk would take.
    public func nextDate(after date: Date, calendar: Calendar = .current, searchDays: Int = 366) -> Date? {
        // Start at the top of the next minute: a schedule fires *after* the given instant, and
        // seconds are not part of the expression.
        guard let start = calendar.date(bySetting: .second, value: 0, of: date).map({ $0 > date ? $0 : $0.addingTimeInterval(60) })
                ?? calendar.date(byAdding: .minute, value: 1, to: date)
        else { return nil }

        let sortedHours = hours.sorted()
        let sortedMinutes = minutes.sorted()
        let startDay = calendar.startOfDay(for: start)

        for offset in 0..<searchDays {
            guard let day = calendar.date(byAdding: .day, value: offset, to: startDay) else { continue }
            let c = calendar.dateComponents([.year, .month, .day, .weekday], from: day)
            guard matches(dateComponents: c) else { continue }

            for h in sortedHours {
                for m in sortedMinutes {
                    var want = c
                    want.hour = h
                    want.minute = m
                    want.second = 0
                    want.weekday = nil   // over-specified components can make Calendar return nil
                    // A wall-clock time inside a spring-forward gap does not exist; Calendar returns
                    // the adjusted instant, which is what cron does too — the job runs once, late.
                    guard let candidate = calendar.date(from: want) else { continue }
                    if candidate > date { return candidate }
                }
            }
        }
        return nil
    }

    // MARK: - Codable

    /// Encoded as the expression alone. The sets are derived, so persisting them would put five
    /// redundant arrays in every state file and risk a decoded schedule disagreeing with its own text.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        try self.init(raw)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(expression)
    }

    /// The most recent fire at or before `date`, or nil if there is none within `searchDays`.
    ///
    /// The mirror of `nextDate`, and the reason catch-up is cheap: answering "what was the last time
    /// this should have run" by stepping forward one fire at a time costs an iteration per *fire*,
    /// which for `* * * * *` over a week is ten thousand of them. Walking days backwards costs one
    /// iteration per *day* whatever the expression.
    public func lastDate(atOrBefore date: Date, calendar: Calendar = .current, searchDays: Int = 366) -> Date? {
        let sortedHours = hours.sorted(by: >)
        let sortedMinutes = minutes.sorted(by: >)
        let startDay = calendar.startOfDay(for: date)

        for offset in 0..<searchDays {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: startDay) else { continue }
            let c = calendar.dateComponents([.year, .month, .day, .weekday], from: day)
            guard matches(dateComponents: c) else { continue }

            for h in sortedHours {
                for m in sortedMinutes {
                    var want = c
                    want.hour = h
                    want.minute = m
                    want.second = 0
                    want.weekday = nil
                    guard let candidate = calendar.date(from: want) else { continue }
                    if candidate <= date { return candidate }
                }
            }
        }
        return nil
    }

    /// Fires strictly after `date` and no later than `end`, oldest first. Used to answer "did we miss
    /// one while Clinic was closed", so it is bounded by `limit` — a weekend of missed hourly runs is
    /// a fact to report, not 48 runs to launch (ADR-095's catch-up policy).
    public func dates(after date: Date, through end: Date, calendar: Calendar = .current, limit: Int = 64) -> [Date] {
        var out: [Date] = []
        var cursor = date
        while out.count < limit, let next = nextDate(after: cursor, calendar: calendar), next <= end {
            out.append(next)
            cursor = next
        }
        return out
    }
}
