import Foundation

/// The preset picker's vocabulary, expressed *over* cron rather than beside it (ADR-095): every
/// preset builds a `CronSchedule`, and `preset` reads one back so the editor opens on the segment
/// that matches whatever the automation actually holds — including one typed by hand that happens to
/// be a preset.
public extension CronSchedule {
    enum Preset: Equatable, Sendable, Hashable {
        case hourly
        case everyNHours(Int)
        case daily(hour: Int, minute: Int)
        case weekly(weekday: Int, hour: Int, minute: Int)   // weekday 0 = Sunday
        case custom
    }

    static var hourly: CronSchedule { try! CronSchedule("0 * * * *") }

    static func everyNHours(_ n: Int) -> CronSchedule {
        let n = max(1, min(23, n))
        return n == 1 ? hourly : (try? CronSchedule("0 */\(n) * * *")) ?? hourly
    }

    static func daily(hour: Int, minute: Int) -> CronSchedule {
        (try? CronSchedule("\(clamp(minute, 0, 59)) \(clamp(hour, 0, 23)) * * *")) ?? hourly
    }

    static func weekly(weekday: Int, hour: Int, minute: Int) -> CronSchedule {
        (try? CronSchedule("\(clamp(minute, 0, 59)) \(clamp(hour, 0, 23)) * * \(clamp(weekday, 0, 6))")) ?? hourly
    }

    private static func clamp(_ v: Int, _ lo: Int, _ hi: Int) -> Int { max(lo, min(hi, v)) }

    /// Which preset this expression *is*, judged on what it matches rather than on how it was typed,
    /// so `0 0-23 * * *` opens the picker on Hourly just as `0 * * * *` does.
    var preset: Preset {
        let everyDay = daysOfMonth.count == 31 && months.count == 12
        guard everyDay, minutes.count == 1, let minute = minutes.first else { return .custom }

        if daysOfWeek.count == 7 {
            if hours.count == 24 { return .hourly }
            if hours.count == 1, let hour = hours.first { return .daily(hour: hour, minute: minute) }
            // An even stride from midnight is "every N hours"; anything else is a custom hour list.
            let sorted = hours.sorted()
            if sorted.count > 1, sorted.first == 0, 24 % sorted.count == 0 {
                let step = 24 / sorted.count
                if sorted == Array(stride(from: 0, to: 24, by: step)) { return .everyNHours(step) }
            }
            return .custom
        }
        if daysOfWeek.count == 1, let weekday = daysOfWeek.first, hours.count == 1, let hour = hours.first {
            return .weekly(weekday: weekday, hour: hour, minute: minute)
        }
        return .custom
    }

    /// A one-line description for the row and the detail pane. Falls back to the raw expression,
    /// which is honest: a schedule Clinic cannot phrase in English is better shown as cron than
    /// approximated.
    func summary(calendar: Calendar = .current, locale: Locale = .current) -> String {
        // A *complete* date, not bare hour-and-minute components. Under-specified components leave
        // `Calendar.date(from:)` free to return nil, and the fallback below renders 24-hour where the
        // formatter renders 12-hour — so a failure here would not look like a failure, it would look
        // like a different time format appearing on some machines and not others.
        func time(_ hour: Int, _ minute: Int) -> String {
            let c = DateComponents(year: 2001, month: 1, day: 1, hour: hour, minute: minute)
            guard let date = calendar.date(from: c) else { return String(format: "%02d:%02d", hour, minute) }
            let f = DateFormatter(); f.locale = locale; f.timeStyle = .short; f.dateStyle = .none
            f.calendar = calendar
            f.timeZone = calendar.timeZone
            return f.string(from: date)
        }
        switch preset {
        case .hourly:
            return minutes.first == 0 ? "Every hour" : "Every hour at :\(String(format: "%02d", minutes.first ?? 0))"
        case .everyNHours(let n):
            return "Every \(n) hours"
        case .daily(let h, let m):
            return "Every day at \(time(h, m))"
        case .weekly(let w, let h, let m):
            let symbols = DateFormatter(); symbols.locale = locale
            let name = symbols.weekdaySymbols[safe: w] ?? "day \(w)"
            return "Every \(name) at \(time(h, m))"
        case .custom:
            return phrasedCustom(calendar: calendar, locale: locale, time: time) ?? expression
        }
    }

    /// Phrasing for the shapes that are not presets but are still ordinary English — chiefly
    /// "weekdays at nine", which the picker has no segment for and which three of the eight shipped
    /// templates use. Without this the gallery shows tiles that speak cron.
    private func phrasedCustom(calendar: Calendar, locale: Locale, time: (Int, Int) -> String) -> String? {
        guard daysOfMonth.count == 31, months.count == 12,
              minutes.count == 1, let minute = minutes.first,
              hours.count == 1, let hour = hours.first,
              (1...6).contains(daysOfWeek.count)
        else { return nil }

        let at = time(hour, minute)
        if daysOfWeek == [1, 2, 3, 4, 5] { return "Every weekday at \(at)" }
        if daysOfWeek == [0, 6] { return "Every weekend day at \(at)" }

        let f = DateFormatter(); f.locale = locale
        let names = daysOfWeek.sorted().compactMap { f.shortWeekdaySymbols[safe: $0] }
        guard !names.isEmpty else { return nil }
        return "Every \(names.joined(separator: ", ")) at \(at)"
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
