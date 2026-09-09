import Foundation

/// A starting point in the Automations gallery (ADR-095).
///
/// Templates are **data, not code**: they live in `Resources/automation-templates.json`, so adding
/// one is an edit to a JSON file and the gallery grows without touching Swift. Each declares its own
/// permission posture — report-shaped templates run `plan` and are structurally incapable of stalling
/// on a write; code-shaped ones run `acceptEdits` and get the worktree that implies.
public struct AutomationTemplate: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var icon: String
    public var blurb: String
    public var prompt: String
    /// A cron expression. Parsed at load; a template whose schedule does not parse is dropped rather
    /// than shipped broken, and `bundledProblems` says which.
    public var schedule: String
    public var scope: Scope
    public var model: String?
    public var effort: String?
    public var permissionMode: Automation.PermissionMode
    /// A CLI the prompt depends on. The gallery greys the tile and says why when it is missing,
    /// reusing the discovery [[ADR-086 Tool Discovery and gh Availability]] already does.
    public var requiredTool: String?

    public enum Scope: String, Codable, Sendable, Hashable {
        /// Needs a repository; the gallery asks which project when the tile is used.
        case project
        /// Answers a question rather than touching a repo, so it runs in the Chats directory.
        case chat
    }

    public var parsedSchedule: CronSchedule? { try? CronSchedule(schedule) }

    /// Builds an automation from the template. The name is the template's until the user renames it.
    public func makeAutomation(target: Automation.Target) -> Automation {
        Automation(name: name,
                   prompt: prompt,
                   target: target,
                   schedule: parsedSchedule ?? .daily(hour: 9, minute: 0),
                   model: model,
                   effort: effort,
                   permissionMode: permissionMode,
                   templateId: id)
    }
}

public extension AutomationTemplate {
    /// Templates shipped with the app, in file order — the gallery shows them as written rather than
    /// sorted, so the JSON controls the reading order.
    static let bundled: [AutomationTemplate] = loadBundled().templates

    /// Templates that failed to load, for the test that asserts this is empty. Keeping the failures
    /// rather than throwing means one malformed template cannot empty the gallery.
    static let bundledProblems: [String] = loadBundled().problems

    private static func loadBundled() -> (templates: [AutomationTemplate], problems: [String]) {
        guard let url = Bundle.module.url(forResource: "automation-templates", withExtension: "json"),
              let data = try? Data(contentsOf: url)
        else { return ([], ["automation-templates.json is missing from the bundle"]) }
        do {
            let all = try JSONDecoder().decode([AutomationTemplate].self, from: data)
            var good: [AutomationTemplate] = []
            var problems: [String] = []
            for t in all {
                if t.parsedSchedule == nil { problems.append("\(t.id): schedule \"\(t.schedule)\" does not parse") }
                else if t.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { problems.append("\(t.id): empty prompt") }
                else { good.append(t) }
            }
            return (good, problems)
        } catch {
            return ([], ["automation-templates.json did not decode: \(error)"])
        }
    }
}
