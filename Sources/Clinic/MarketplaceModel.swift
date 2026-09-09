import Foundation
import Observation
import ClinicCore
import os

/// State behind the Marketplace screen (ADR-084). One instance for the app, so the catalogue survives
/// switching to a session and back, and every window sees the same install state.
///
/// Nothing here writes `~/.claude`: reads come from `PluginCatalog`, changes are argv handed to
/// `PluginService`, and each one is confirmed by the user first.
@MainActor
@Observable
final class MarketplaceModel {
    enum Section: String, CaseIterable, Identifiable {
        case discover, installed, marketplaces
        var id: String { rawValue }
        var label: String {
            switch self {
            case .discover: "Discover"
            case .installed: "Installed"
            case .marketplaces: "Marketplaces"
            }
        }
    }

    enum Sort: String, CaseIterable, Identifiable {
        case popular, name
        var id: String { rawValue }
        var label: String { self == .popular ? "Most installed" : "Name" }
    }

    /// A mutation waiting on the confirmation sheet — the ADR's "shown in full before it runs".
    struct Pending: Identifiable {
        let id = UUID()
        var operation: PluginService.Operation
        var title: String
        /// What this will do, in a sentence.
        var detail: String
        /// Past tense, for the footer once it has run.
        var success: String
        var isDestructive = false
        var command: String { PluginService.displayCommand(operation) }
    }

    private let service = PluginService()
    private let log = Logger(subsystem: "com.r0adkll.clinic", category: "marketplace")

    var section: Section = .discover
    var query = ""
    var category: String?
    var sort: Sort = .popular
    var selectedId: String?
    var marketplaceSource = ""

    private(set) var entries: [PluginEntry] = []
    private(set) var marketplaces: [MarketplaceRef] = []
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    /// nil until the first check; false means no `claude` on PATH.
    private(set) var cliAvailable: Bool?
    private(set) var loadError: String?

    var pending: Pending?
    private(set) var runningCommand: String?
    /// The last failure, kept on screen until the next command or a dismissal.
    var runError: String?
    var lastSucceeded: String?

    // MARK: Reading

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false; hasLoaded = true }
        let available = await service.isAvailable()
        cliAvailable = available
        guard available else { entries = []; marketplaces = []; return }
        do {
            async let catalog = service.catalog()
            async let refs = service.marketplaces()
            entries = try await catalog
            marketplaces = try await refs
            loadError = nil
        } catch {
            loadError = (error as? PluginError)?.message ?? error.localizedDescription
            log.error("catalog failed: \(self.loadError ?? "", privacy: .public)")
        }
        if let selectedId, !entries.contains(where: { $0.id == selectedId }) { self.selectedId = nil }
    }

    /// Loads once per app run; the sidebar row should feel instant on later visits.
    func loadIfNeeded() {
        guard !hasLoaded, !isLoading else { return }
        Task { await refresh() }
    }

    // MARK: Derived lists

    var installed: [PluginEntry] { entries.filter(\.isInstalled) }

    var categories: [String] {
        Set(entries.compactMap(\.category)).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// The Discover list: search, category, then the chosen order.
    var filtered: [PluginEntry] {
        let base = entries.filter { entry in
            entry.matches(query) && (category == nil || entry.category == category)
        }
        switch sort {
        case .name: return base
        case .popular: return base.sorted { ($0.installCount ?? -1) > ($1.installCount ?? -1) }
        }
    }

    var visible: [PluginEntry] {
        switch section {
        case .discover: filtered
        case .installed: installed.filter { $0.matches(query) }
        case .marketplaces: []
        }
    }

    var selected: PluginEntry? { selectedId.flatMap { id in entries.first { $0.id == id } } }

    // MARK: Mutations — each one goes through the confirmation sheet

    func install(_ entry: PluginEntry) {
        pending = Pending(operation: .install(entry.id, .user), title: "Install \(entry.name)?",
                          detail: "Installs \(entry.name) from \(entry.marketplace) for your user account. It becomes available in sessions you start afterwards.",
                          success: "Installed \(entry.name)")
    }

    func uninstall(_ entry: PluginEntry) {
        pending = Pending(operation: .uninstall(entry.id, scope(for: entry)), title: "Uninstall \(entry.name)?",
                          detail: "Removes \(entry.name) from your \(scope(for: entry).rawValue) scope.",
                          success: "Uninstalled \(entry.name)", isDestructive: true)
    }

    func setEnabled(_ entry: PluginEntry, _ enabled: Bool) {
        pending = Pending(operation: enabled ? .enable(entry.id) : .disable(entry.id),
                          title: enabled ? "Enable \(entry.name)?" : "Disable \(entry.name)?",
                          detail: enabled
                              ? "\(entry.name) loads in sessions you start afterwards."
                              : "\(entry.name) stays installed but stops loading in new sessions.",
                          success: enabled ? "Enabled \(entry.name)" : "Disabled \(entry.name)")
    }

    func update(_ entry: PluginEntry) {
        pending = Pending(operation: .update(entry.id, scope(for: entry)), title: "Update \(entry.name)?",
                          detail: "Fetches the latest version from \(entry.marketplace). Running sessions keep the version they started with.",
                          success: "Updated \(entry.name)")
    }

    func addMarketplace(_ source: String) {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        pending = Pending(operation: .marketplaceAdd(trimmed), title: "Add marketplace?",
                          detail: "Claude Code clones \(trimmed) into ~/.claude/plugins/marketplaces and reads its plugin manifest. Nothing is installed yet.",
                          success: "Added \(trimmed)")
    }

    func removeMarketplace(_ ref: MarketplaceRef) {
        pending = Pending(operation: .marketplaceRemove(ref.name), title: "Remove \(ref.name)?",
                          detail: "Stops offering its plugins. Plugins already installed from it are not removed.",
                          success: "Removed \(ref.name)", isDestructive: true)
    }

    func updateMarketplace(_ ref: MarketplaceRef?) {
        pending = Pending(operation: .marketplaceUpdate(ref?.name),
                          title: ref.map { "Update \($0.name)?" } ?? "Update every marketplace?",
                          detail: "Re-fetches the plugin list from source. Installed plugins are untouched.",
                          success: ref.map { "Updated \($0.name)" } ?? "Updated every marketplace")
    }

    /// Runs the confirmed command, then re-reads the catalogue so the screen reflects what actually happened.
    func runPending() {
        guard let pending else { return }
        self.pending = nil
        runError = nil
        lastSucceeded = nil
        runningCommand = pending.command
        Task {
            defer { runningCommand = nil }
            do {
                try await service.perform(pending.operation)
                lastSucceeded = pending.success
                if case .marketplaceAdd = pending.operation { marketplaceSource = "" }
                await refresh()
            } catch {
                runError = (error as? PluginError)?.message ?? error.localizedDescription
                log.error("\(pending.command, privacy: .public) failed: \(self.runError ?? "", privacy: .public)")
            }
        }
    }

    /// Uninstall and update need the scope the plugin was installed into; `user` is the default everything else uses.
    private func scope(for entry: PluginEntry) -> PluginService.Scope {
        entry.scope.flatMap(PluginService.Scope.init(rawValue:)) ?? .user
    }
}
