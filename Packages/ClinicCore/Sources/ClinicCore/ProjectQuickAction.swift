import Foundation

/// The buttons a project's header shows under the pointer (ADR-211), chosen in Settings. They always
/// appear in this declaration order, before the ⋯ menu, which keeps every action whatever is chosen.
public enum ProjectQuickAction: String, CaseIterable, Sendable {
    case newSession, newWorktreeSession, continueLast, openShell, run, openIn, gitPull, group, openOnGitHub, copyPath, showInFinder

    /// What a header shows before anything is chosen: the old "+", and the two the user asked for.
    public static let defaults: [ProjectQuickAction] = [.newSession, .group, .gitPull]
    /// At most this many, so the buttons cannot crowd out the project's name.
    public static let maxChosen = 5
    /// The `UserDefaults` key holding the choice.
    public static let defaultsKey = "ClinicProjectQuickActions"

    /// Reads a stored choice: nil (never chosen) is the defaults, and an empty string is none. Unknown
    /// names are dropped, the rest put in declaration order and capped.
    public static func parse(_ stored: String?) -> [ProjectQuickAction] {
        guard let stored else { return defaults }
        let chosen = Set(stored.split(separator: ",").compactMap { ProjectQuickAction(rawValue: String($0)) })
        return Array(allCases.filter(chosen.contains).prefix(maxChosen))
    }

    public static func serialize(_ actions: [ProjectQuickAction]) -> String {
        allCases.filter(actions.contains).prefix(maxChosen).map(\.rawValue).joined(separator: ",")
    }

    /// Chats has no repository, no run configurations and no group, so only these make sense on it.
    public var appliesToChats: Bool {
        switch self {
        case .newSession, .continueLast, .openShell, .copyPath, .showInFinder: true
        default: false
        }
    }
}
