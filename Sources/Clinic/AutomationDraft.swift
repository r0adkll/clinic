import Foundation
import ClinicCore

/// Editable state behind the automation editor (ADR-095).
///
/// A struct of loose fields rather than an `Automation` under edit, for the same reason the new
/// session screen keeps a draft: the schedule is being *built* — a preset, a time, a weekday, or raw
/// cron — and only becomes a `CronSchedule` when it parses. Holding a half-typed expression in a
/// value that refuses to exist unless valid does not work.
struct AutomationDraft: Identifiable {
    var id: UUID
    /// nil when creating; set when editing an existing automation.
    var editing: UUID?
    var name: String
    var prompt: String
    var target: Automation.Target
    var permissionMode: Automation.PermissionMode
    var model: String?
    var effort: String?
    var catchUp: Automation.CatchUpPolicy
    var notifyOn: Automation.NotifyPolicy
    var stallMinutes: Int
    var keepRuns: Int
    var autoPrune: Bool
    var templateId: String?
    var isEnabled: Bool

    // Schedule, held as the picker's parts plus the raw field so a half-typed expression survives.
    var preset: PresetKind
    var hour: Int
    var minute: Int
    var weekday: Int
    var everyNHours: Int
    var customExpression: String

    enum PresetKind: String, CaseIterable, Identifiable {
        case hourly, everyNHours, daily, weekly, custom
        var id: String { rawValue }
        var title: String {
            switch self {
            case .hourly: "Hourly"
            case .everyNHours: "Every N hours"
            case .daily: "Daily"
            case .weekly: "Weekly"
            case .custom: "Custom"
            }
        }
    }

    /// The schedule as it currently stands, or nil while the custom field does not parse.
    var schedule: CronSchedule? {
        switch preset {
        case .hourly: CronSchedule.hourly
        case .everyNHours: CronSchedule.everyNHours(everyNHours)
        case .daily: CronSchedule.daily(hour: hour, minute: minute)
        case .weekly: CronSchedule.weekly(weekday: weekday, hour: hour, minute: minute)
        case .custom: try? CronSchedule(customExpression)
        }
    }

    /// Why the custom field is refused, phrased for a person rather than a parser.
    var scheduleError: String? {
        guard preset == .custom else { return nil }
        guard !customExpression.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        do { _ = try CronSchedule(customExpression); return nil }
        catch let error as CronSchedule.ParseError { return error.description }
        catch { return "\(error)" }
    }

    /// True when this came from a template that needs a repository. Such a prompt talks about "this
    /// repository", so letting it fall back to the Chats scratch directory would produce an
    /// automation that is silently about nothing — which is what happens on a machine with no
    /// projects registered yet.
    var requiresProject: Bool {
        guard let templateId else { return false }
        return AutomationTemplate.bundled.first { $0.id == templateId }?.scope == .project
    }

    var missingProject: Bool {
        guard requiresProject else { return false }
        if case .project = target { return false }
        return true
    }

    var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && schedule != nil
            && !missingProject
    }

    /// Blank, for "New automation".
    init(target: Automation.Target) {
        id = UUID(); editing = nil; name = ""; prompt = ""; self.target = target
        permissionMode = .plan; model = nil; effort = nil
        catchUp = .runOnce; notifyOn = .problemsOnly
        stallMinutes = Int(Automation.defaultStallTimeout / 60); keepRuns = 5; autoPrune = false
        templateId = nil; isEnabled = true
        preset = .daily; hour = 9; minute = 0; weekday = 1; everyNHours = 6
        customExpression = "0 9 * * *"
    }

    /// From a template tile.
    init(template: AutomationTemplate, target: Automation.Target) {
        self.init(target: target)
        name = template.name
        prompt = template.prompt
        permissionMode = template.permissionMode
        model = template.model
        effort = template.effort
        templateId = template.id
        if let schedule = template.parsedSchedule { apply(schedule) }
    }

    /// From an existing automation, for Edit.
    init(automation: Automation) {
        self.init(target: automation.target)
        id = automation.id
        editing = automation.id
        name = automation.name
        prompt = automation.prompt
        permissionMode = automation.permissionMode
        model = automation.model
        effort = automation.effort
        catchUp = automation.catchUp
        notifyOn = automation.notifyOn
        stallMinutes = max(1, Int(automation.stallTimeout / 60))
        keepRuns = automation.keepRuns
        autoPrune = automation.autoPrune
        templateId = automation.templateId
        isEnabled = automation.isEnabled
        apply(automation.schedule)
    }

    /// Opens the picker on the segment the schedule actually *is*, including one typed by hand that
    /// happens to be a preset.
    private mutating func apply(_ schedule: CronSchedule) {
        customExpression = schedule.expression
        switch schedule.preset {
        case .hourly: preset = .hourly
        case .everyNHours(let n): preset = .everyNHours; everyNHours = n
        case .daily(let h, let m): preset = .daily; hour = h; minute = m
        case .weekly(let w, let h, let m): preset = .weekly; weekday = w; hour = h; minute = m
        case .custom: preset = .custom
        }
    }

    /// Applies the draft onto a new or existing automation.
    func makeAutomation(existing: Automation?) -> Automation? {
        guard let schedule, isValid else { return nil }
        var a = existing ?? Automation(name: name, prompt: prompt, target: target, schedule: schedule)
        a.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        a.prompt = prompt
        a.target = target
        a.schedule = schedule
        a.permissionMode = permissionMode
        a.model = model
        a.effort = effort
        a.catchUp = catchUp
        a.notifyOn = notifyOn
        a.stallTimeout = TimeInterval(max(1, stallMinutes) * 60)
        a.keepRuns = max(0, keepRuns)
        a.autoPrune = autoPrune
        a.templateId = templateId
        a.isEnabled = isEnabled
        return a
    }
}
