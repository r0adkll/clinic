import SwiftUI
import ClinicCore

/// The Sounds screen (ADR-199): OpenPeon sound packs to browse, hear and install, and which of
/// Clinic's moments they voice. Shown in the content area like the Marketplace; it owns no session.
struct SoundsScreen: View {
    @Environment(SoundPackStore.self) private var store

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            SoundsFooter()
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task { store.loadIfNeeded() }
    }

    // MARK: Header

    private var header: some View {
        @Bindable var store = store
        return VStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "speaker.wave.2.fill").font(.title3).foregroundStyle(Color.accent)
                Text("Sounds").font(.title3.weight(.semibold))
                Text("OpenPeon sound packs for your sessions").font(.callout).foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Button { NSWorkspace.shared.open(URL(string: "https://openpeon.com")!) } label: {
                    Label("openpeon.com", systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.borderless)
                Button { Task { await store.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .disabled(store.isLoading)
                    .help("Read the OpenPeon registry again, and look for packs on this Mac")
            }
            HStack(spacing: 10) {
                Picker("", selection: $store.section) {
                    ForEach(SoundPackStore.Section.allCases) { section in Text(label(for: section)).tag(section) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                if store.section != .events {
                    SearchField(text: $store.query, prompt: store.section == .installed ? "Filter installed" : "Search packs, games, voices")
                        .frame(maxWidth: 320)
                }
                Spacer(minLength: 0)
                if store.isLoading { ProgressView().controlSize(.small) }
            }
            if store.section == .browse, !store.topTags.isEmpty { tagFilter }
        }
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)
    }

    private func label(for section: SoundPackStore.Section) -> String {
        switch section {
        case .browse: store.registry.isEmpty ? "Browse" : "Browse (\(store.registry.count))"
        case .installed:
            store.installed.isEmpty ? "Installed"
                : "Installed (\(store.installed.count))" + (store.updateCount > 0 ? " · \(store.updateCount) update\(store.updateCount == 1 ? "" : "s")" : "")
        case .events: "Events"
        }
    }

    private var tagFilter: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                SoundTagChip(label: "All", selected: store.tag == nil) { store.tag = nil }
                ForEach(store.topTags, id: \.self) { tag in
                    SoundTagChip(label: tag, selected: store.tag == tag) { store.tag = store.tag == tag ? nil : tag }
                }
            }
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch store.section {
        case .events:
            SoundEventsView()
        case .browse, .installed:
            HStack(spacing: 0) {
                list.frame(width: 340)
                Divider()
                Group {
                    if let name = store.selectedId, store.entry(name) != nil || store.installedPack(name) != nil {
                        SoundPackDetail(name: name).id(name)
                    } else {
                        ContentUnavailableView("Nothing selected", systemImage: "waveform",
                                               description: Text("Pick a pack to hear its lines."))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var list: some View {
        @Bindable var store = store
        return List(selection: $store.selectedId) {
            if store.section == .browse {
                ForEach(store.visibleEntries) { entry in
                    SoundPackRow(name: entry.name, title: entry.displayName, subtitle: entry.description,
                                 detail: rowDetail(entry), badge: entry.trustTier).tag(entry.name)
                }
            } else {
                ForEach(store.visibleInstalled) { pack in
                    SoundPackRow(name: pack.id, title: pack.manifest.displayName, subtitle: pack.manifest.description ?? "",
                                 detail: installedDetail(pack), badge: nil).tag(pack.id)
                }
            }
        }
        .listStyle(.inset)
        .overlay {
            if store.section == .browse && store.visibleEntries.isEmpty && !store.isLoading {
                if store.registry.isEmpty {
                    ContentUnavailableView {
                        Label("No packs to show", systemImage: "waveform.slash")
                    } description: {
                        Text(store.loadError ?? "The OpenPeon registry has not been read yet.")
                    } actions: {
                        Button("Try Again") { Task { await store.refresh() } }
                    }
                } else {
                    ContentUnavailableView.search(text: store.query)
                }
            } else if store.section == .installed && store.visibleInstalled.isEmpty {
                if store.installed.isEmpty {
                    ContentUnavailableView("No packs installed", systemImage: "speaker.slash",
                                           description: Text("Install one from Browse. Packs in ~/.openpeon or peon-ping's folder show up here too."))
                } else {
                    ContentUnavailableView.search(text: store.query)
                }
            }
        }
    }

    private func rowDetail(_ entry: SoundRegistry.Entry) -> String {
        var parts: [String] = []
        if let author = entry.authorName { parts.append(author) }
        if let lines = entry.soundCount { parts.append("\(lines) lines") }
        if let language = entry.language, language != "en" { parts.append(language) }
        parts.append(contentsOf: entry.tags.prefix(2))
        return parts.joined(separator: " · ")
    }

    private func installedDetail(_ pack: InstalledSoundPack) -> String {
        var parts = ["v\(pack.manifest.version)", "\(pack.manifest.allLines.count) lines"]
        if pack.origin != .clinic { parts.append("from \(pack.origin.label)") }
        if store.update(for: pack) != nil { parts.append("update available") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Rows

struct SoundPackRow: View {
    @Environment(SoundPackStore.self) private var store
    let name: String
    let title: String
    let subtitle: String
    let detail: String
    let badge: String?

    private var isInstalled: Bool { store.installedPack(name) != nil }
    private var isDefault: Bool { store.settings.defaultPack == name && isInstalled }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isDefault ? "speaker.wave.2.fill" : isInstalled ? "checkmark.circle.fill" : "waveform")
                .font(.system(size: 13))
                .foregroundStyle(isDefault ? AnyShapeStyle(Color.accent) : isInstalled ? AnyShapeStyle(Color.green) : AnyShapeStyle(.tertiary))
                .frame(width: 16, height: 16)
                .padding(.top, 1)
                .help(isDefault ? "The default pack" : isInstalled ? "Installed" : "")
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title).font(.body.weight(.semibold)).lineLimit(1)
                    if let badge, badge != "community" { TrustBadge(tier: badge) }
                    Spacer(minLength: 0)
                }
                if !subtitle.isEmpty {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Text(detail).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
        .padding(.vertical, 3)
    }
}

/// The registry's own word for who stands behind a pack.
struct TrustBadge: View {
    let tier: String

    var body: some View {
        Label(tier.capitalized, systemImage: tier == "official" ? "checkmark.seal.fill" : "checkmark.seal")
            .labelStyle(.titleAndIcon)
            .font(.caption2)
            .foregroundStyle(tier == "official" ? Color.accent : Color.secondary)
            .help(tier == "official" ? "Published by OpenPeon" : tier == "verified" ? "Reviewed by OpenPeon" : "Submitted by the community")
    }
}

struct SoundTagChip: View {
    let label: String
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.callout)
                .foregroundStyle(selected ? Color.accent : Color.secondary)
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(selected ? Color.accent.opacity(0.16) : Color.primary.opacity(hovering ? 0.11 : 0.07), in: Capsule())
                .overlay(Capsule().strokeBorder(selected ? Color.accent.opacity(0.35) : Color.primary.opacity(0.08)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Detail

/// One pack: who made it, what it costs, and every line it would say, each with a ▶.
struct SoundPackDetail: View {
    @Environment(SoundPackStore.self) private var store
    let name: String

    private var entry: SoundRegistry.Entry? { store.entry(name) }
    private var pack: InstalledSoundPack? { store.installedPack(name) }
    private var manifest: CESPManifest? { store.manifest(for: name) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                title
                if let description = entry?.description ?? pack?.manifest.description, !description.isEmpty {
                    Text(description).font(.body).textSelection(.enabled)
                }
                actions
                lines
                facts
            }
            .frame(maxWidth: 620, alignment: .leading)
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { if let entry { store.loadManifest(for: entry) } }
    }

    private var displayName: String { pack?.manifest.displayName ?? entry?.displayName ?? name }

    private var title: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(displayName).font(.title2.weight(.semibold)).textSelection(.enabled)
                Text(pack?.manifest.version ?? entry?.version ?? "")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 2).background(.quaternary, in: Capsule())
                if let tier = entry?.trustTier { TrustBadge(tier: tier) }
                if let pack {
                    Label(pack.origin == .clinic ? "Installed" : "Found in \(pack.origin.label)", systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(.green)
                }
            }
            let author = pack?.manifest.author?.name ?? entry?.authorName
            let license = pack?.manifest.license ?? entry?.license
            HStack(spacing: 6) {
                if let author { Text(author) }
                if let license { Text("·"); Text(license) }
                if let language = pack?.manifest.language ?? entry?.language { Text("·"); Text(language) }
                if let bytes = entry?.totalSizeBytes { Text("·"); Text(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)) }
            }
            .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            let busy = store.installing.contains(name)
            if let pack {
                if store.settings.defaultPack == name {
                    Label("Default pack", systemImage: "speaker.wave.2.fill").foregroundStyle(Color.accent)
                } else {
                    Button("Use as Default") { store.settings.defaultPack = name }.buttonStyle(.borderedProminent)
                }
                if let update = store.update(for: pack) {
                    Button("Update to \(update.version)") { store.install(update) }.disabled(busy)
                }
                if pack.origin == .clinic {
                    Button("Uninstall", role: .destructive) { store.uninstall(pack) }.disabled(busy)
                }
            } else if let entry {
                Button("Install") { store.install(entry) }.buttonStyle(.borderedProminent).disabled(busy)
            }
            if busy { ProgressView().controlSize(.small) }
            if let entry {
                Button { NSWorkspace.shared.open(URL(string: "https://github.com/\(entry.sourceRepo)")!) } label: {
                    Label("Source", systemImage: "arrow.up.right.square")
                }
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var lines: some View {
        if let manifest {
            VStack(alignment: .leading, spacing: 10) {
                Text("What it says").font(.callout.weight(.semibold))
                ForEach(CESPCategory.allCases) { category in
                    let lines = manifest.lines(for: category)
                    if !lines.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Image(systemName: category.symbol).foregroundStyle(Color.accent).frame(width: 16)
                                Text(category.title).font(.caption.weight(.semibold))
                                Text(category.rawValue).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                                if store.settings.disabledCategories.contains(category) {
                                    Text("off").font(.caption2).foregroundStyle(.secondary)
                                        .padding(.horizontal, 5).padding(.vertical, 1).background(.quaternary, in: Capsule())
                                }
                            }
                            FlowLines(lines: lines, name: name)
                        }
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        } else if let entry, !entry.previews.isEmpty {
            HStack(spacing: 6) {
                ForEach(entry.previews, id: \.path) { preview in
                    LineButton(label: preview.label ?? (preview.path as NSString).lastPathComponent, path: preview.path, name: name)
                }
                ProgressView().controlSize(.small)
            }
        }
    }

    private var facts: some View {
        VStack(alignment: .leading, spacing: 4) {
            fact("Name", name)
            if let entry { fact("Source", "\(entry.sourceRepo) @ \(entry.sourceRef)" + (entry.sourcePath == "." ? "" : " / \(entry.sourcePath)")) }
            if let pack { fact("Folder", pack.directory.path) }
            if let tags = entry?.tags, !tags.isEmpty { fact("Tags", tags.joined(separator: ", ")) }
        }
        .font(.caption)
    }

    private func fact(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).foregroundStyle(.tertiary).frame(width: 60, alignment: .leading)
            Text(value).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }
}

/// A category's lines, wrapping onto as many rows as they need.
private struct FlowLines: View {
    let lines: [CESPManifest.Line]
    let name: String

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(lines, id: \.path) { line in
                LineButton(label: line.label.isEmpty ? (line.file as NSString).lastPathComponent : line.label, path: line.path, name: name)
            }
        }
    }
}

/// One line as a capsule that plays it, and reads ■ while it does.
private struct LineButton: View {
    @Environment(SoundPackStore.self) private var store
    let label: String
    let path: String
    let name: String
    @State private var hovering = false

    var body: some View {
        let playing = store.isPreviewing(path, of: name)
        Button { store.togglePreview(path, of: name) } label: {
            HStack(spacing: 4) {
                Image(systemName: playing ? "stop.fill" : "play.fill").font(.system(size: 8))
                Text(label).lineLimit(1)
            }
            .font(.caption)
            .foregroundStyle(playing ? Color.accent : Color.primary)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(playing ? Color.accent.opacity(0.16) : Color.primary.opacity(hovering ? 0.11 : 0.06), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(label)
    }
}

// MARK: - Events

/// What Clinic voices: each witness and each category can be switched off on its own (ADR-199).
struct SoundEventsView: View {
    @Environment(SoundPackStore.self) private var store

    var body: some View {
        @Bindable var store = store
        Form {
            Section {
                Toggle("Stay quiet for the tab I'm looking at", isOn: $store.settings.quietOnScreen)
            } footer: {
                Text("A pack line replaces the notification sound for the same moment. Where the pack has no line, or the moment is switched off here, your notification sound plays as before.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Claude Code") {
                ForEach(SoundWitness.allCases.filter(\.isHook)) { witnessRow($0) }
            }
            Section("Clinic") {
                ForEach(SoundWitness.allCases.filter { !$0.isHook }) { witnessRow($0) }
            }
            Section {
                ForEach(CESPCategory.allCases) { category in
                    Toggle(isOn: categoryBinding(category)) {
                        HStack(spacing: 8) {
                            Image(systemName: category.symbol).foregroundStyle(Color.accent).frame(width: 18)
                            Text(category.title)
                            Text(category.rawValue).font(.caption.monospaced()).foregroundStyle(.tertiary)
                            if let count = defaultLineCount(category) {
                                Text(count == 0 ? "no lines" : "\(count) line\(count == 1 ? "" : "s")")
                                    .font(.caption).foregroundStyle(count == 0 ? .tertiary : .secondary)
                            }
                        }
                    }
                }
            } header: {
                Text("Categories")
            } footer: {
                Text("Categories are OpenPeon's. Switching one off silences every moment above that maps to it. Line counts are for the default pack.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 720)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func witnessRow(_ witness: SoundWitness) -> some View {
        Toggle(isOn: Binding(
            get: { !store.settings.disabledWitnesses.contains(witness) },
            set: { on in if on { store.settings.disabledWitnesses.remove(witness) } else { store.settings.disabledWitnesses.insert(witness) } }
        )) {
            HStack(spacing: 8) {
                Text(witness.title)
                Spacer(minLength: 8)
                Label(witness.category.rawValue, systemImage: witness.category.symbol)
                    .font(.caption.monospaced())
                    .foregroundStyle(store.settings.disabledCategories.contains(witness.category) ? .tertiary : .secondary)
            }
        }
    }

    private func categoryBinding(_ category: CESPCategory) -> Binding<Bool> {
        Binding(
            get: { !store.settings.disabledCategories.contains(category) },
            set: { on in if on { store.settings.disabledCategories.remove(category) } else { store.settings.disabledCategories.insert(category) } }
        )
    }

    private func defaultLineCount(_ category: CESPCategory) -> Int? {
        store.pack(for: nil).map { $0.manifest.lines(for: category).count }
    }
}

// MARK: - Footer

/// The master switch, the volume and the default pack, under every section.
struct SoundsFooter: View {
    @Environment(SoundPackStore.self) private var store

    var body: some View {
        @Bindable var store = store
        HStack(spacing: 10) {
            Toggle("Sounds", isOn: $store.settings.enabled).toggleStyle(.switch).controlSize(.small)
                .help("Off, every moment makes the notification sound it made before packs")
            Image(systemName: "speaker.fill").font(.caption).foregroundStyle(.secondary)
            Slider(value: $store.settings.volume, in: 0...1) { editing in if !editing { store.sampleVolume() } }
                .controlSize(.small).frame(width: 110)
                .disabled(!store.settings.enabled)
            Image(systemName: "speaker.wave.3.fill").font(.caption).foregroundStyle(.secondary)
            Menu {
                ForEach(store.installed) { pack in
                    Button(pack.manifest.displayName) { store.settings.defaultPack = pack.id }
                }
                if store.installed.isEmpty { Text("Install a pack from Browse") }
            } label: {
                Text(store.pack(for: nil)?.manifest.displayName ?? "No default pack")
            }
            .menuStyle(.button).fixedSize()
            .disabled(!store.settings.enabled)
            .help("The pack every session speaks with")
            Divider().frame(height: 14)
            status
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }

    @ViewBuilder
    private var status: some View {
        switch store.message {
        case .failed(let text):
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
            Text(text).font(.caption).lineLimit(2).textSelection(.enabled)
            Button("Dismiss") { store.message = nil }.buttonStyle(.borderless)
        case .done(let text):
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Text(text).font(.caption).lineLimit(1)
        case nil:
            if let error = store.loadError {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(error).font(.caption).lineLimit(2)
            } else {
                Text("Packs play through Focus, like your own notification sounds.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
