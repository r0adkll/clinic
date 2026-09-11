import Foundation

/// Who ran a check, read from where its details link points (ADR-116).
///
/// `gh`'s status rollup does not say which app produced a check run, but the link does: an Actions
/// run lives under `/actions/runs/`, and every other CI service links to its own host. The panel
/// draws the provider's mark beside the check, because "the Codecov check failed" and "the build
/// failed" are different problems.
public enum CheckProvider: String, Hashable, Sendable, CaseIterable {
    case githubActions, gitlabCI, codecov, circleCI, buildkite, vercel, netlify, travisCI, bitrise, jenkins, sonarCloud
    /// Anything unrecognised, and a status with no link.
    case other

    public init(_ check: PullRequest.Check) {
        let ranByActions = !(check.workflow ?? "").isEmpty
        guard let url = check.detailsURL, let host = url.host?.lowercased() else {
            self = ranByActions ? .githubActions : .other
            return
        }
        let path = url.path
        let labels = host.split(separator: ".")
        func on(_ domain: String) -> Bool { host == domain || host.hasSuffix("." + domain) }

        if path.contains("/actions/runs/") { self = .githubActions }
        else if on("circleci.com") { self = .circleCI }
        else if on("buildkite.com") { self = .buildkite }
        else if on("vercel.com") { self = .vercel }
        else if on("netlify.com") || on("netlify.app") { self = .netlify }
        else if on("travis-ci.com") || on("travis-ci.org") { self = .travisCI }
        else if on("bitrise.io") { self = .bitrise }
        else if on("codecov.io") { self = .codecov }
        else if on("sonarcloud.io") { self = .sonarCloud }
        else if labels.contains("jenkins") { self = .jenkins }
        else if labels.contains("gitlab") && (path.contains("/-/pipelines/") || path.contains("/-/jobs/")) { self = .gitlabCI }
        else { self = ranByActions ? .githubActions : .other }
    }

    public var name: String {
        switch self {
        case .githubActions: "GitHub Actions"
        case .gitlabCI: "GitLab CI"
        case .codecov: "Codecov"
        case .circleCI: "CircleCI"
        case .buildkite: "Buildkite"
        case .vercel: "Vercel"
        case .netlify: "Netlify"
        case .travisCI: "Travis CI"
        case .bitrise: "Bitrise"
        case .jenkins: "Jenkins"
        case .sonarCloud: "SonarQube Cloud"
        case .other: "External check"
        }
    }
}
