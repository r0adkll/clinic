import Foundation
import Observation
import os
import ClinicCore

/// Cache and refresh of pull requests for open tabs (ADR-053).
@MainActor
@Observable
final class PRStore {
    private static let log = Logger(subsystem: "com.r0adkll.clinic", category: "github")
    let service = GitHubService()
    private(set) var availability: GitHubService.Availability?
    private(set) var viewerLogin: String?
    private(set) var pullRequests: [String: PullRequest] = [:]   // by ref id (url)
    private(set) var diffs: [String: UnifiedDiff] = [:]
    private(set) var errors: [String: String] = [:]
    private(set) var loading: Set<String> = []
    private var pollTask: Task<Void, Never>?
    var openRefsProvider: (() -> [PullRequestRef])?

    func start() {
        Task { await refreshAvailability() }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))
                guard let self else { return }
                for ref in self.openRefsProvider?() ?? [] where self.pullRequests[ref.id]?.state != .merged { await self.refresh(ref) }
            }
        }
    }

    /// Re-runs `gh auth status`. The page's "Retry" calls this, so a `gh auth login` in another
    /// window is picked up without restarting Clinic.
    func refreshAvailability() async {
        availability = await service.availability()
        viewerLogin = availability?.isReady == true ? await service.viewerLogin() : nil
    }

    func pullRequest(for ref: PullRequestRef) -> PullRequest? { pullRequests[ref.id] }

    func mark(for ref: PullRequestRef) -> PullRequestMark? {
        pullRequests[ref.id].map { PullRequestMark(pr: $0, viewerLogin: viewerLogin) }
    }

    func aggregateMark(for refs: [PullRequestRef]) -> PullRequestMark? {
        PullRequestMark.aggregate(refs.compactMap { mark(for: $0) })
    }

    func ensureLoaded(_ refs: [PullRequestRef]) {
        for ref in refs where pullRequests[ref.id] == nil && !loading.contains(ref.id) { Task { await refresh(ref) } }
    }

    func refresh(_ ref: PullRequestRef) async {
        guard availability?.isReady != false else { return }
        loading.insert(ref.id); defer { loading.remove(ref.id) }
        do {
            pullRequests[ref.id] = try await service.pullRequest(ref)
            errors[ref.id] = nil
        } catch {
            errors[ref.id] = "\(error)"
            Self.log.warning("pr \(ref.url.absoluteString, privacy: .public): \(error, privacy: .public)")
        }
    }

    func loadDiff(_ ref: PullRequestRef) async {
        do { diffs[ref.id] = try await service.diff(ref); errors[ref.id] = nil } catch { errors[ref.id] = "\(error)" }
    }

    func perform(_ ref: PullRequestRef, _ op: @escaping @Sendable (GitHubService) async throws -> Void) async {
        do { try await op(service); errors[ref.id] = nil } catch { errors[ref.id] = "\(error)" }
        await refresh(ref)
    }

    var mergeMethod: GitHubService.MergeMethod {
        GitHubService.MergeMethod(rawValue: UserDefaults.standard.string(forKey: "ClinicMergeMethod") ?? "squash") ?? .squash
    }
}
