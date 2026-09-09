import SwiftUI
import ClinicCore

/// The Marketplace screen (ADR-084): find, inspect and install Claude Code plugins without leaving Clinic.
/// Shown in the content area like the new-session screen, not as a tab — it owns no session.
struct MarketplaceScreen: View {
    @Environment(MarketplaceModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            MarketplaceFooter()
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(item: $model.pending) { ConfirmCommandSheet(pending: $0) }
        .task { model.loadIfNeeded() }
    }

    // MARK: Header

    private var header: some View {
        @Bindable var model = model
        return VStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "storefront.fill").font(.title3).foregroundStyle(Color.accentColor)
                Text("Marketplace").font(.title3.weight(.semibold))
                Text("Plugins for Claude Code").font(.callout).foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Button { Task { await model.refresh() } } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(model.isLoading)
                .help("Re-read the catalogue from the Claude CLI")
            }
            HStack(spacing: 10) {
                Picker("", selection: $model.section) {
                    ForEach(MarketplaceModel.Section.allCases) { section in
                        Text(label(for: section)).tag(section)
                    }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()

                if model.section != .marketplaces {
                    SearchField(text: $model.query, prompt: model.section == .installed ? "Filter installed" : "Search plugins")
                        .frame(maxWidth: 320)
                }
                if model.section == .discover {
                    Menu {
                        Button("All categories") { model.category = nil }
                        Divider()
                        ForEach(model.categories, id: \.self) { c in Button(c.capitalized) { model.category = c } }
                    } label: {
                        Text(model.category?.capitalized ?? "All categories")
                    }
                    .menuStyle(.button).fixedSize()
                    .disabled(model.categories.isEmpty)

                    Menu {
                        ForEach(MarketplaceModel.Sort.allCases) { s in Button(s.label) { model.sort = s } }
                    } label: {
                        Label(model.sort.label, systemImage: "arrow.up.arrow.down")
                    }
                    .menuStyle(.button).fixedSize()
                }
                Spacer(minLength: 0)
                if model.isLoading { ProgressView().controlSize(.small) }
            }
        }
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)
    }

    private func label(for section: MarketplaceModel.Section) -> String {
        switch section {
        case .discover: model.entries.isEmpty ? "Discover" : "Discover (\(model.filtered.count))"
        case .installed: model.installed.isEmpty ? "Installed" : "Installed (\(model.installed.count))"
        case .marketplaces: model.marketplaces.isEmpty ? "Marketplaces" : "Marketplaces (\(model.marketplaces.count))"
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if model.cliAvailable == false {
            ContentUnavailableView {
                Label("Claude Code was not found", systemImage: "terminal")
            } description: {
                Text("Clinic runs `claude plugin` to read and change your plugins, and could not find `claude` on the PATH a GUI app inherits — /usr/bin, /bin, /opt/homebrew/bin, /usr/local/bin and ~/.local/bin.")
            } actions: {
                Button("Try Again") { Task { await model.refresh() } }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.section == .marketplaces {
            MarketplaceSourcesList()
        } else {
            HStack(spacing: 0) {
                pluginList.frame(width: 340)
                Divider()
                Group {
                    if let entry = model.selected {
                        PluginDetail(entry: entry)
                    } else {
                        ContentUnavailableView("Nothing selected", systemImage: "puzzlepiece.extension",
                                               description: Text("Pick a plugin to see what it installs and what it costs."))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var pluginList: some View {
        @Bindable var model = model
        return List(selection: $model.selectedId) {
            ForEach(model.visible) { entry in
                PluginRow(entry: entry).tag(entry.id)
            }
        }
        .listStyle(.inset)
        .overlay {
            if model.visible.isEmpty && !model.isLoading {
                if model.section == .installed {
                    ContentUnavailableView("No plugins installed", systemImage: "shippingbox",
                                           description: Text("Install one from Discover."))
                } else if model.entries.isEmpty {
                    ContentUnavailableView("No plugins to show", systemImage: "shippingbox",
                                           description: Text("Add a marketplace to see what it offers."))
                } else {
                    ContentUnavailableView.search(text: model.query)
                }
            }
        }
    }
}

// MARK: - Rows

/// One plugin in the Discover / Installed list.
struct PluginRow: View {
    let entry: PluginEntry

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: entry.isInstalled ? "checkmark.circle.fill" : "puzzlepiece.extension")
                .font(.system(size: 13))
                .foregroundStyle(entry.isInstalled ? (entry.isEnabled ? AnyShapeStyle(Color.green) : AnyShapeStyle(.secondary)) : AnyShapeStyle(.tertiary))
                .frame(width: 16, height: 16)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(entry.name).font(.body.weight(.semibold)).lineLimit(1)
                    if entry.isBlocked {
                        Image(systemName: "exclamationmark.triangle.fill").font(.caption2).foregroundStyle(.orange)
                            .help(entry.blockedReason ?? "")
                    }
                    if entry.isInstalled && !entry.isEnabled {
                        Text("disabled").font(.caption2).foregroundStyle(.secondary)
                            .padding(.horizontal, 5).padding(.vertical, 1).background(.quaternary, in: Capsule())
                    }
                    Spacer(minLength: 0)
                    if let n = entry.installCount {
                        Label(PluginEntry.shortCount(n), systemImage: "arrow.down.circle")
                            .font(.caption2).foregroundStyle(.tertiary).labelStyle(.titleAndIcon)
                    }
                }
                if !entry.description.isEmpty {
                    Text(entry.description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                HStack(spacing: 6) {
                    if let author = entry.author { Text(author).font(.caption2).foregroundStyle(.tertiary).lineLimit(1) }
                    if let category = entry.category {
                        Text(category).font(.caption2).foregroundStyle(.tertiary)
                            .padding(.horizontal, 5).padding(.vertical, 1).background(.quaternary, in: Capsule())
                    }
                }
            }
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Detail

/// Everything the local manifests and catalogue cache know about one plugin, and the actions for it.
struct PluginDetail: View {
    @Environment(MarketplaceModel.self) private var model
    let entry: PluginEntry

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                title
                if let reason = entry.blockedReason { blockedBanner(reason) }
                if !entry.description.isEmpty {
                    Text(entry.description).font(.body).foregroundStyle(.primary).textSelection(.enabled)
                }
                actions
                if let components = entry.components, !components.isEmpty { inventory(components) }
                facts
            }
            .frame(maxWidth: 620, alignment: .leading)
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var title: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(entry.name).font(.title2.weight(.semibold)).textSelection(.enabled)
                if let v = entry.version {
                    Text(v).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 2).background(.quaternary, in: Capsule())
                }
                if entry.isInstalled {
                    Label(entry.isEnabled ? "Installed" : "Installed · disabled", systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(entry.isEnabled ? Color.green : Color.secondary)
                }
            }
            HStack(spacing: 6) {
                if let author = entry.author { Text(author) }
                if let category = entry.category { Text("·"); Text(category) }
                Text("·"); Text(entry.marketplace)
                if let n = entry.installCount { Text("·"); Text("\(PluginEntry.shortCount(n)) installs") }
            }
            .font(.callout).foregroundStyle(.secondary)
        }
    }

    private func blockedBanner(_ reason: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Anthropic has flagged this plugin").font(.callout.weight(.semibold))
                Text(reason).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private var actions: some View {
        HStack(spacing: 8) {
            if entry.isInstalled {
                Button(entry.isEnabled ? "Disable" : "Enable") { model.setEnabled(entry, !entry.isEnabled) }
                Button("Update") { model.update(entry) }
                Button("Uninstall", role: .destructive) { model.uninstall(entry) }
            } else {
                Button("Install") { model.install(entry) }.buttonStyle(.borderedProminent)
            }
            if let url = entry.homepageURL {
                Button { NSWorkspace.shared.open(url) } label: { Label("Homepage", systemImage: "arrow.up.right.square") }
            }
            Spacer(minLength: 0)
        }
        .disabled(model.runningCommand != nil)
    }

    /// Skills, agents, hooks and MCP servers — what actually lands in a session.
    private func inventory(_ components: PluginComponents) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What it adds").font(.callout.weight(.semibold))
            ForEach(components.groups, id: \.label) { group in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(group.label) (\(group.names.count))").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    Text(group.names.joined(separator: ", ")).font(.caption).foregroundStyle(.primary).textSelection(.enabled)
                }
            }
            if let tokens = entry.alwaysOnTokens {
                Divider().padding(.vertical, 2)
                HStack(spacing: 6) {
                    Image(systemName: "gauge.with.dots.needle.33percent").foregroundStyle(.secondary)
                    Text("\(PluginEntry.shortTokens(tokens)) added to every session")
                    if let model = entry.tokenModel {
                        Text("(\(TabFooter.shortModel(model)))").foregroundStyle(.tertiary)
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    private var facts: some View {
        VStack(alignment: .leading, spacing: 4) {
            fact("Plugin id", entry.id)
            if let source = entry.sourceLabel { fact("Source", source) }
            if let scope = entry.scope { fact("Scope", scope) }
            if let date = entry.installedAt {
                fact("Installed", date.formatted(date: .abbreviated, time: .shortened))
            }
        }
        .font(.caption)
    }

    private func fact(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).foregroundStyle(.tertiary).frame(width: 70, alignment: .leading)
            Text(value).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }
}

// MARK: - Marketplaces

/// The sources plugins come from: add one by `owner/repo`, a URL or a local path.
struct MarketplaceSourcesList: View {
    @Environment(MarketplaceModel.self) private var model

    var body: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                TextField("owner/repo, a git URL, or a local path", text: $model.marketplaceSource)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.addMarketplace(model.marketplaceSource) }
                Button("Add Marketplace") { model.addMarketplace(model.marketplaceSource) }
                    .disabled(model.marketplaceSource.trimmingCharacters(in: .whitespaces).isEmpty)
                Button { model.updateMarketplace(nil) } label: { Label("Update All", systemImage: "arrow.triangle.2.circlepath") }
                    .disabled(model.marketplaces.isEmpty)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .disabled(model.runningCommand != nil)
            Divider()
            List {
                ForEach(model.marketplaces) { ref in
                    MarketplaceSourceRow(ref: ref)
                }
            }
            .listStyle(.inset)
            .overlay {
                if model.marketplaces.isEmpty && !model.isLoading {
                    ContentUnavailableView("No marketplaces", systemImage: "building.2",
                                           description: Text("Add anthropics/claude-plugins-official to start, or any GitHub repo with a marketplace manifest."))
                }
            }
        }
    }
}

struct MarketplaceSourceRow: View {
    @Environment(MarketplaceModel.self) private var model
    let ref: MarketplaceRef

    private var pluginCount: Int { model.entries.filter { $0.marketplace == ref.name }.count }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: ref.sourceKind == "local" ? "folder" : "building.2")
                .foregroundStyle(.secondary).frame(width: 16).padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(ref.name).font(.body.weight(.semibold))
                    Text(ref.sourceKind).font(.caption2).foregroundStyle(.secondary)
                        .padding(.horizontal, 5).padding(.vertical, 1).background(.quaternary, in: Capsule())
                    Text("\(pluginCount) plugins").font(.caption2).foregroundStyle(.tertiary)
                }
                Text(ref.origin.isEmpty ? "—" : ref.origin)
                    .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(1)
                if let updated = ref.lastUpdated {
                    Text("Updated \(updated.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                if let url = ref.homepageURL {
                    Button { NSWorkspace.shared.open(url) } label: { Image(systemName: "arrow.up.right.square") }
                        .buttonStyle(.borderless).help("Open \(ref.origin)")
                }
                Button("Update") { model.updateMarketplace(ref) }
                Button("Remove", role: .destructive) { model.removeMarketplace(ref) }
            }
            .disabled(model.runningCommand != nil)
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Footer and confirmation

/// What the screen is doing, and the standing caveat: nothing here changes a session already running.
struct MarketplaceFooter: View {
    @Environment(MarketplaceModel.self) private var model

    var body: some View {
        @Bindable var model = model
        return HStack(spacing: 8) {
            if let command = model.runningCommand {
                ProgressView().controlSize(.small)
                Text(command).font(.system(.caption, design: .monospaced)).lineLimit(1).truncationMode(.middle)
            } else if let error = model.runError {
                Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                Text(error).font(.caption).foregroundStyle(.primary).lineLimit(2).textSelection(.enabled)
                Spacer(minLength: 8)
                Button("Dismiss") { model.runError = nil }.buttonStyle(.borderless)
            } else if let done = model.lastSucceeded {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("\(done) — takes effect in sessions started from now on.").font(.caption)
            } else if let error = model.loadError {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(error).font(.caption).lineLimit(2)
            } else {
                Image(systemName: "info.circle").foregroundStyle(.tertiary)
                Text("Installing or toggling a plugin affects sessions you start afterwards, not ones already running.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }
}

/// The command Clinic is about to hand the CLI, shown in full before it runs (ADR-084).
struct ConfirmCommandSheet: View {
    @Environment(MarketplaceModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let pending: MarketplaceModel.Pending

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(pending.title).font(.title3.weight(.semibold))
            Text(pending.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Clinic will run").font(.caption).foregroundStyle(.tertiary)
                Text(pending.command)
                    .font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            }
            Text("Clinic never edits ~/.claude itself; the Claude CLI owns those files.")
                .font(.caption2).foregroundStyle(.tertiary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(pending.isDestructive ? "Continue" : "Run", role: pending.isDestructive ? .destructive : nil) {
                    model.runPending()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

/// A plain search field; `.searchable` belongs to a navigation container, which this screen is not part of.
struct SearchField: View {
    @Binding var text: String
    let prompt: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.caption).foregroundStyle(.secondary)
            TextField(prompt, text: $text).textFieldStyle(.plain)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    }
}
