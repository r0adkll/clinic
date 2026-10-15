import SwiftUI
import ClinicCore

/// The Sounds screen (ADR-199, ADR-200): OpenPeon sound packs to browse, hear and install, and which of
/// Clinic's moments they voice. Shown in the content area like the Marketplace; it owns no session.
///
/// Browse is three columns: filters (language, franchise, tags, quality), the list, and the pack's
/// page. The filter column folds away by itself in a window too narrow for three, and comes back with
/// the button beside the search.
struct SoundsScreen: View {
    @Environment(SoundPackStore.self) private var store
    /// Whether the reader wants the filter column in a window wide enough for it.
    @AppStorage("ClinicSoundsFiltersShown") private var filtersPreferred = true
    /// A choice made in a narrow window, where the column is folded unless asked for.
    @State private var narrowOverride: Bool?
    @AppStorage("ClinicPeonPingBannerDismissed") private var peonPingDismissed = false

    /// Below this content width the filter column folds by itself.
    private static let roomForFilters: CGFloat = 900

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if store.peonPing != nil && !peonPingDismissed {
                PeonPingBanner { peonPingDismissed = true }
                Divider()
            }
            content
            Divider()
            SoundsFooter()
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            store.loadIfNeeded()
            store.detectPeonPing()
        }
    }

    // MARK: Header

    private var header: some View {
        @Bindable var store = store
        return HStack(spacing: 10) {
            Image(systemName: "speaker.wave.2.fill").font(.title3).foregroundStyle(Color.accent)
            Text("Sounds").font(.title3.weight(.semibold))
            Text("OpenPeon sound packs for your sessions").font(.callout).foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 12)
            if store.isLoading { ProgressView().controlSize(.small) }
            Picker("", selection: $store.section) {
                ForEach(SoundPackStore.Section.allCases) { section in Text(label(for: section)).tag(section) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            Menu {
                Button("Refresh") { Task { await store.refresh() } }
                Button("Open openpeon.com") { NSWorkspace.shared.open(URL(string: "https://openpeon.com/packs")!) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("Refresh the registry, or open openpeon.com")
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
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

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch store.section {
        case .events:
            SoundEventsView()
        case .browse, .installed:
            GeometryReader { geometry in
                let width = geometry.size.width
                let wide = width >= Self.roomForFilters
                let showFilters = store.section == .browse && (wide ? filtersPreferred : (narrowOverride ?? false))
                let listWidth: CGFloat = width - (showFilters ? 221 : 0) < 760 ? 290 : 320
                HStack(spacing: 0) {
                    if showFilters {
                        SoundFilterColumn().frame(width: 220)
                        Divider()
                    }
                    SoundPackList(filtersShown: showFilters) {
                        if wide { filtersPreferred.toggle() } else { narrowOverride = !showFilters }
                    }
                    .frame(width: listWidth)
                    Divider()
                    Group {
                        if let name = store.selectedId, store.entry(name) != nil || store.installedPack(name) != nil {
                            SoundPackDetail(name: name).id(name)
                        } else {
                            ContentUnavailableView("Nothing selected", systemImage: "waveform",
                                                   description: Text("Pick a pack to hear what it says."))
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }
}

// MARK: - Filter column

/// Language, franchise, tags and quality (ADR-200). Every count is what ticking that box would show.
struct SoundFilterColumn: View {
    @Environment(SoundPackStore.self) private var store
    @State private var folded: Set<SoundPackFilter.Facet> = []
    @State private var showingAll: Set<SoundPackFilter.Facet> = []
    @State private var franchiseQuery = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                section(.language, "Language") { languageRows }
                section(.franchise, "Franchise") { franchiseRows }
                section(.tag, "Tags") { tagChips }
                section(.quality, "Quality") { qualityRows }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
        }
        .background(Color.primary.opacity(0.025))
    }

    private func picked(_ facet: SoundPackFilter.Facet) -> Int {
        facet == .quality ? store.filter.values(.quality).count + store.filter.values(.trust).count : store.filter.values(facet).count
    }

    private func section<Content: View>(_ facet: SoundPackFilter.Facet, _ title: String, @ViewBuilder content: () -> Content) -> some View {
        let open = !folded.contains(facet)
        return VStack(alignment: .leading, spacing: 2) {
            Button {
                if open { folded.insert(facet) } else { folded.remove(facet) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .frame(width: 10)
                    Text(title).font(.subheadline.weight(.semibold))
                    Spacer(minLength: 4)
                    if picked(facet) > 0 {
                        Text("\(picked(facet))").font(.caption.weight(.semibold)).foregroundStyle(Color.accent)
                    }
                }
                .foregroundStyle(.secondary)
                .padding(.vertical, 6).padding(.horizontal, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(title), \(open ? "expanded" : "collapsed")")
            if open { content().padding(.leading, 4).padding(.bottom, 6) }
        }
    }

    private func toggle(_ value: String, _ facet: SoundPackFilter.Facet) -> Binding<Bool> {
        Binding(get: { store.filter.contains(value, in: facet) }, set: { _ in store.filter.toggle(value, in: facet) })
    }

    private func row(_ value: String, _ facet: SoundPackFilter.Facet, label: String, detail: String? = nil, count: Int) -> some View {
        Toggle(isOn: toggle(value, facet)) {
            HStack(spacing: 6) {
                Text(label).lineLimit(1)
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                Spacer(minLength: 4)
                Text("\(count)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.checkbox)
        .padding(.vertical, 1)
        // A value that would show nothing with the other filters as they are stays, but steps back.
        .opacity(count == 0 && !store.filter.contains(value, in: facet) ? 0.45 : 1)
        .accessibilityLabel("\(label), \(count) packs")
    }

    /// The first `limit`, then the rest on request; anything ticked always shows.
    private func limited<T>(_ facet: SoundPackFilter.Facet, _ all: [T], _ limit: Int, value: (T) -> String) -> [T] {
        guard !showingAll.contains(facet) else { return all }
        let ticked = store.filter.values(facet)
        return Array(all.prefix(limit)) + all.dropFirst(limit).filter { ticked.contains(value($0)) }
    }

    @ViewBuilder
    private func more(_ facet: SoundPackFilter.Facet, total: Int, shown: Int, noun: String) -> some View {
        if total > shown || showingAll.contains(facet) {
            Button(showingAll.contains(facet) ? "Show fewer" : "All \(total) \(noun)") {
                if showingAll.contains(facet) { showingAll.remove(facet) } else { showingAll.insert(facet) }
            }
            .buttonStyle(.link).font(.caption).padding(.leading, 20).padding(.top, 2)
        }
    }

    // Language: the Mac's own languages first, then the most common.
    @ViewBuilder
    private var languageRows: some View {
        let counts = store.catalog.counts(.language, store.filter)
        let preferred = Locale.preferredLanguages.compactMap { Locale(identifier: $0).language.languageCode?.identifier }
        let all = store.catalog.values(.language).sorted { a, b in
            let pa = preferred.firstIndex(of: a.value) ?? .max, pb = preferred.firstIndex(of: b.value) ?? .max
            return pa != pb ? pa < pb : a.total > b.total
        }
        let shown = limited(.language, all, 5) { $0.value }
        ForEach(shown, id: \.value) { item in
            let names = SoundLanguage.names(item.value)
            row(item.value, .language, label: names.native, detail: names.native == names.local ? item.value.uppercased() : names.local,
                count: counts[item.value] ?? 0)
        }
        more(.language, total: all.count, shown: shown.count, noun: "languages")
    }

    @ViewBuilder
    private var franchiseRows: some View {
        let counts = store.catalog.counts(.franchise, store.filter)
        // Most common first, with the packs that have none at the end however many they are.
        let all = store.catalog.values(.franchise).sorted { a, b in
            (a.value == SoundCatalog.noFranchise ? 1 : 0) < (b.value == SoundCatalog.noFranchise ? 1 : 0)
        }
        if showingAll.contains(.franchise) {
            SearchField(text: $franchiseQuery, prompt: "Filter franchises").padding(.vertical, 3)
        }
        let matching = franchiseQuery.isEmpty ? all : all.filter { $0.value.localizedCaseInsensitiveContains(franchiseQuery) }
        let shown = limited(.franchise, matching, 8) { $0.value }
        ForEach(shown, id: \.value) { item in
            row(item.value, .franchise, label: item.value == SoundCatalog.noFranchise ? "No franchise" : item.value,
                count: counts[item.value] ?? 0)
        }
        more(.franchise, total: all.count, shown: shown.count, noun: "franchises")
    }

    @ViewBuilder
    private var tagChips: some View {
        let counts = store.catalog.counts(.tag, store.filter)
        let all = store.catalog.values(.tag)
        let shown = limited(.tag, all, 12) { $0.value }
        FlowLayout(spacing: 5) {
            ForEach(shown, id: \.value) { item in
                let count = counts[item.value] ?? 0
                let selected = store.filter.contains(item.value, in: .tag)
                SoundTagChip(label: item.value, count: count, selected: selected) {
                    store.filter.toggle(item.value, in: .tag)
                }
                .opacity(count == 0 && !selected ? 0.45 : 1)
            }
        }
        .padding(.vertical, 2)
        more(.tag, total: all.count, shown: shown.count, noun: "tags")
    }

    @ViewBuilder
    private var qualityRows: some View {
        let quality = store.catalog.counts(.quality, store.filter)
        let trust = store.catalog.counts(.trust, store.filter)
        row("gold", .quality, label: "Gold", count: quality["gold"] ?? 0)
        row("silver", .quality, label: "Silver", count: quality["silver"] ?? 0)
        Divider().padding(.vertical, 3)
        row("official", .trust, label: "Official", detail: "by OpenPeon", count: trust["official"] ?? 0)
        row("verified", .trust, label: "Verified", detail: "reviewed", count: trust["verified"] ?? 0)
        row("community", .trust, label: "Community", count: trust["community"] ?? 0)
    }
}

/// A language's name in itself and in the reader's language, from the system's own tables.
enum SoundLanguage {
    static func names(_ code: String) -> (native: String, local: String) {
        let own = Locale(identifier: code)
        let native = own.localizedString(forLanguageCode: code).map { $0.capitalized(with: own) } ?? code.uppercased()
        let local = Locale.current.localizedString(forLanguageCode: code).map { $0.capitalized(with: .current) } ?? code.uppercased()
        return (native, local)
    }
}

// MARK: - List column

struct SoundPackList: View {
    @Environment(SoundPackStore.self) private var store
    let filtersShown: Bool
    let toggleFilters: () -> Void

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    if store.section == .browse { filterButton }
                    SearchField(text: $store.filter.query, prompt: store.section == .installed ? "Filter installed" : "Search packs, lines, authors")
                }
                if store.section == .browse {
                    HStack(spacing: 8) {
                        Text(countLabel).font(.caption).foregroundStyle(.secondary)
                        Spacer(minLength: 4)
                        Picker("Sort", selection: $store.filter.sort) {
                            ForEach(SoundPackFilter.Sort.allCases) { Text($0.label).tag($0) }
                        }
                        .labelsHidden().controlSize(.small).fixedSize()
                        .help("Sort the list")
                    }
                    if store.filter.activeCount > 0 { activeChips }
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            Divider()
            list
        }
    }

    private var countLabel: String {
        let shown = store.visible.count, total = store.registry.count
        return shown == total ? "\(total) packs" : "\(shown) of \(total) packs"
    }

    private var filterButton: some View {
        Button(action: toggleFilters) {
            Image(systemName: "line.3.horizontal.decrease")
                .foregroundStyle(store.filter.activeCount > 0 ? AnyShapeStyle(Color.accent) : AnyShapeStyle(.secondary))
                .frame(width: 24, height: 22)
                .overlay(alignment: .topTrailing) {
                    if !filtersShown && store.filter.activeCount > 0 {
                        Text("\(store.filter.activeCount)")
                            .font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                            .padding(.horizontal, 3).frame(minWidth: 13, minHeight: 13)
                            .background(Color.accent, in: Capsule())
                            .offset(x: 5, y: -4)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(filtersShown ? "Hide filters" : "Show filters")
        .accessibilityLabel(filtersShown ? "Hide filters" : "Show filters")
    }

    /// What is ticked, each removable, and a way to untick it all.
    private var activeChips: some View {
        let f = store.filter
        var chips: [(String, SoundPackFilter.Facet, String)] = []
        for code in f.values(.language).sorted() { chips.append((SoundLanguage.names(code).native, .language, code)) }
        for name in f.values(.franchise).sorted() { chips.append((name == SoundCatalog.noFranchise ? "No franchise" : name, .franchise, name)) }
        for tag in f.values(.tag).sorted() { chips.append(("#" + tag, .tag, tag)) }
        for q in f.values(.quality).sorted() { chips.append((q.capitalized, .quality, q)) }
        for t in f.values(.trust).sorted() { chips.append((t.capitalized, .trust, t)) }
        return FlowLayout(spacing: 5) {
            ForEach(chips, id: \.2) { chip in
                Button { store.filter.toggle(chip.2, in: chip.1) } label: {
                    HStack(spacing: 3) { Text(chip.0); Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                        .font(.caption).foregroundStyle(Color.accent)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Color.accent.opacity(0.16), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove filter \(chip.0)")
            }
            Button("Clear all") { store.filter.clear() }.buttonStyle(.link).font(.caption)
        }
    }

    private var list: some View {
        @Bindable var store = store
        return ScrollViewReader { proxy in
            List(selection: $store.selectedId) {
                if store.section == .browse {
                    ForEach(store.visible) { pack in SoundPackRow(name: pack.id).tag(pack.id) }
                } else {
                    ForEach(store.visibleInstalled) { pack in SoundPackRow(name: pack.id).tag(pack.id) }
                }
            }
            .listStyle(.inset)
            .overlay { emptyState }
            // New results start at the top, not wherever the last ones were scrolled to.
            .onChange(of: store.filter) {
                if let first = store.visible.first?.id { proxy.scrollTo(first, anchor: .top) }
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if store.section == .browse && store.visible.isEmpty && !store.isLoading {
            if store.registry.isEmpty {
                ContentUnavailableView {
                    Label("No packs to show", systemImage: "waveform.slash")
                } description: {
                    Text(store.loadError ?? "The OpenPeon registry has not been read yet.")
                } actions: {
                    Button("Try Again") { Task { await store.refresh() } }
                }
            } else {
                ContentUnavailableView {
                    Label("No pack matches", systemImage: "line.3.horizontal.decrease.circle")
                } actions: {
                    Button("Clear Filters") { store.filter.clear() }
                }
            }
        } else if store.section == .installed && store.visibleInstalled.isEmpty {
            if store.installed.isEmpty {
                ContentUnavailableView("No packs installed", systemImage: "speaker.slash",
                                       description: Text("Install one from Browse. Packs in ~/.openpeon or peon-ping's folder show up here too."))
            } else {
                ContentUnavailableView.search(text: store.filter.query)
            }
        }
    }
}

/// One pack in the list: its name, what it is and where it stands here.
struct SoundPackRow: View {
    @Environment(SoundPackStore.self) private var store
    let name: String

    var body: some View {
        let pack = store.catalog.pack(name)
        let installed = store.installedPack(name)
        let title = installed?.manifest.displayName ?? pack?.entry.displayName ?? name
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).font(.body.weight(.semibold)).lineLimit(1)
                    if installed != nil {
                        Text(store.settings.defaultPack == name ? "Default" : "Installed")
                            .font(.caption).foregroundStyle(store.settings.defaultPack == name ? Color.accent : Color.green)
                    }
                }
                Text(meta(pack, installed)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            let languages = pack?.entry.languages ?? installed?.manifest.language.map { [$0] } ?? []
            if !languages.isEmpty {
                Text(languages.map { $0.uppercased() }.joined(separator: "·"))
                    .font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(.secondary)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.tertiary))
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }

    private func meta(_ pack: SoundCatalog.Pack?, _ installed: InstalledSoundPack?) -> String {
        var parts: [String] = []
        if let franchise = pack?.franchise { parts.append(franchise) }
        if let lines = pack?.entry.soundCount ?? installed.map({ $0.manifest.allLines.count }) { parts.append("\(lines) lines") }
        if let quality = pack?.entry.quality { parts.append(quality.capitalized) }
        if let author = pack?.entry.authorName ?? installed?.manifest.author?.name { parts.append(author) }
        if installed != nil, store.isInRotation(name) { parts.append("in rotation") }
        let projects = store.projects(using: name)
        if installed != nil, !projects.isEmpty {
            parts.append(projects.count == 1 ? (projects[0] as NSString).lastPathComponent : "\(projects.count) projects")
        }
        if let installed, installed.origin != .clinic { parts.append("from \(installed.origin.label)") }
        if let installed, store.update(for: installed) != nil { parts.append("update available") }
        return parts.joined(separator: " · ")
    }
}

struct SoundTagChip: View {
    let label: String
    var count: Int?
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(label)
                if let count { Text("\(count)").monospacedDigit().opacity(0.6) }
            }
            .font(.caption)
            .foregroundStyle(selected ? Color.accent : Color.secondary)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(selected ? Color.accent.opacity(0.16) : Color.primary.opacity(hovering ? 0.11 : 0.07), in: Capsule())
            .overlay(Capsule().strokeBorder(selected ? Color.accent.opacity(0.35) : Color.primary.opacity(0.08)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("Tag \(label)\(count.map { ", \($0) packs" } ?? "")")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Pack page

/// One pack, the way openpeon.com shows it (ADR-200): who made it, what it is, the actions, and every
/// line it says under the moment that plays it.
struct SoundPackDetail: View {
    @Environment(SoundPackStore.self) private var store
    @Environment(SessionStore.self) private var sessions
    let name: String
    @State private var expanded: Set<CESPCategory> = []

    private var pack: SoundCatalog.Pack? { store.catalog.pack(name) }
    private var entry: SoundRegistry.Entry? { pack?.entry }
    private var installed: InstalledSoundPack? { store.installedPack(name) }
    private var manifest: CESPManifest? { store.manifest(for: name) }
    private var displayName: String { installed?.manifest.displayName ?? entry?.displayName ?? name }

    /// Lines shown per category before *Show all*.
    private static let linesShown = 6

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                hero
                chips
                if let description, !description.isEmpty {
                    Text(description).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
                actionBar
                lines
                related
                source
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(.horizontal, 22).padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { if let entry { store.loadManifest(for: entry) } }
    }

    /// The registry's description, unless it only says the name again.
    private var description: String? {
        let text = entry?.description ?? installed?.manifest.description ?? ""
        return text.lowercased().hasPrefix(displayName.lowercased() + " sound pack") ? nil : text
    }

    private var initials: String {
        displayName.split(whereSeparator: { $0 == " " || $0 == "(" }).prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
    }

    private var hero: some View {
        HStack(spacing: 14) {
            Text(initials)
                .font(.system(size: 17, weight: .bold)).foregroundStyle(Color.accent)
                .frame(width: 48, height: 48)
                .background(Color.accent.opacity(0.16), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(displayName).font(.title2.weight(.bold)).lineLimit(2).textSelection(.enabled)
                HStack(spacing: 4) {
                    if let franchise = pack?.franchise {
                        Button(franchise) {
                            store.filter.set([franchise], in: .franchise)
                            store.section = .browse
                        }
                        .buttonStyle(.link)
                        .help("Show every \(franchise) pack")
                        Text("·")
                    }
                    if let author = entry?.authorName ?? installed?.manifest.author?.name { Text("by \(author)") }
                }
                .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var chips: some View {
        var items: [(String, Color?)] = []
        if let quality = entry?.quality { items.append((quality.uppercased(), quality == "gold" ? .yellow : nil)) }
        if let trust = entry?.trustTier, trust != "community" { items.append((trust.capitalized, .blue)) }
        if let version = installed?.manifest.version ?? entry?.version { items.append(("v" + version, nil)) }
        for code in entry?.languages ?? [] { items.append(("\(SoundLanguage.names(code).native) (\(code.uppercased()))", nil)) }
        if let license = entry?.license ?? installed?.manifest.license { items.append((license, nil)) }
        if let count = entry?.soundCount ?? manifest.map({ $0.allLines.count }) { items.append(("\(count) lines", nil)) }
        if let manifest { items.append(("\(manifest.voicedCategories.count) of 9 categories", nil)) }
        if let bytes = entry?.totalSizeBytes { items.append((ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file), nil)) }
        return FlowLayout(spacing: 5) {
            ForEach(items, id: \.0) { item in
                Text(item.0)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(item.1.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.secondary))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder((item.1 ?? .secondary).opacity(0.35)))
            }
        }
    }

    private var actionBar: some View {
        let busy = store.installing.contains(name)
        let isDefault = store.settings.defaultPack == name && installed != nil
        return HStack(spacing: 8) {
            if let installed {
                if isDefault {
                    Label("Default pack", systemImage: "speaker.wave.2.fill").foregroundStyle(Color.accent).font(.callout.weight(.medium))
                } else {
                    Button("Use as Default") { store.settings.defaultPack = name }.buttonStyle(.borderedProminent)
                }
                if let update = store.update(for: installed) {
                    Button("Update to \(update.version)") { store.install(update) }.disabled(busy)
                }
            } else if let entry {
                Button("Install") { store.install(entry) }.buttonStyle(.borderedProminent).disabled(busy)
            }
            projectMenu.disabled(installed == nil)
            Button(store.isInRotation(name) ? "In Rotation ✓" : "Add to Rotation") { store.toggleRotation(name) }
                .disabled(installed == nil)
                .help(installed == nil ? "Install it first" : "Sessions with no pack of their own draw one from the rotation and keep it")
            if busy { ProgressView().controlSize(.small) }
            Spacer(minLength: 8)
            Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            if let installed, installed.origin == .clinic {
                Menu {
                    Button("Uninstall", role: .destructive) { store.uninstall(installed) }
                } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .disabled(busy)
                .accessibilityLabel("More actions")
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    /// *Use for Project ▸*: every project, ticked where this is its pack.
    private var projectMenu: some View {
        Menu("Use for Project") {
            ForEach(sessions.projects) { project in
                Toggle(project.name, isOn: Binding(
                    get: { sessions.state.soundPacks.byProject[project.path] == name },
                    set: { on in store.setPack(on ? name : nil, forProject: project.path) }))
            }
        }
        .fixedSize()
        .help("Give a project this voice: its sessions speak with it unless one has its own")
    }

    /// Where this pack is heard: as the default, in the rotation, for which projects.
    private var status: String {
        guard let installed else { return "Every file is checked as it installs" }
        var uses: [String] = []
        if store.settings.defaultPack == name { uses.append("Default") }
        if store.isInRotation(name) { uses.append("In the rotation") }
        let projects = store.projects(using: name).map { ($0 as NSString).lastPathComponent }
        if !projects.isEmpty { uses.append(projects.count <= 2 ? projects.joined(separator: ", ") : "\(projects.count) projects") }
        if uses.isEmpty { return installed.origin == .clinic ? "Installed" : "Found in \(installed.origin.label)" }
        return uses.joined(separator: " · ")
    }

    @ViewBuilder
    private var lines: some View {
        if let manifest {
            ForEach(CESPCategory.allCases) { category in
                let all = manifest.lines(for: category)
                if !all.isEmpty { categoryBlock(category, all) }
            }
            let missing = CESPCategory.allCases.filter { manifest.lines(for: $0).isEmpty }
            if !missing.isEmpty {
                Text("No lines for \(missing.map { $0.title.lowercased() }.formatted(.list(type: .and))). Those moments play your notification sound instead.")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3])).foregroundStyle(.tertiary))
            }
        } else {
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Reading what it says…").foregroundStyle(.secondary) }
                .font(.callout)
        }
    }

    private func categoryBlock(_ category: CESPCategory, _ all: [CESPManifest.Line]) -> some View {
        let open = expanded.contains(category)
        let shown = open ? all : Array(all.prefix(Self.linesShown))
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(category.rawValue)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(Color.accent)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                Text(category.title).font(.headline)
                Text(category.whenClinicPlays).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 6)], alignment: .leading, spacing: 6) {
                ForEach(Array(shown.enumerated()), id: \.offset) { _, line in
                    LineTile(label: line.label.isEmpty ? (line.file as NSString).lastPathComponent : line.label, path: line.path, name: name)
                }
            }
            if all.count > Self.linesShown {
                Button(open ? "Show fewer" : "Show all \(all.count)") {
                    if open { expanded.remove(category) } else { expanded.insert(category) }
                }
                .buttonStyle(.link).font(.caption)
            }
        }
        .padding(.top, 6)
    }

    @ViewBuilder
    private var related: some View {
        let others: [SoundCatalog.Pack] = {
            guard let pack else { return [] }
            if let franchise = pack.franchise { return store.catalog.packs.filter { $0.franchise == franchise && $0.id != name } }
            guard let tag = pack.entry.tags.dropFirst().first else { return [] }
            return store.catalog.packs.filter { $0.entry.tags.contains(tag) && $0.id != name }
        }()
        if !others.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(pack?.franchise.map { "More from \($0)" } ?? "Related packs").font(.headline)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 8)], alignment: .leading, spacing: 8) {
                    ForEach(others.prefix(4)) { other in
                        Button { store.selectedId = other.id } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(other.entry.displayName).font(.callout.weight(.semibold)).lineLimit(1)
                                Text([other.entry.soundCount.map { "\($0) lines" }, other.entry.languages.first?.uppercased(), other.entry.authorName]
                                    .compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.top, 10)
        }
    }

    @ViewBuilder
    private var source: some View {
        if let entry {
            Button {
                NSWorkspace.shared.open(URL(string: "https://github.com/\(entry.sourceRepo)")!)
            } label: {
                Label("\(entry.sourceRepo)\(entry.sourcePath == "." ? "" : "/" + entry.sourcePath) @ \(entry.sourceRef)", systemImage: "arrow.up.right.square")
            }
            .buttonStyle(.link).font(.caption)
        }
    }
}

extension CESPCategory {
    /// What makes Clinic play this category (ADR-199). Categories with no witness yet say so.
    var whenClinicPlays: String {
        switch self {
        case .sessionStart: "when a session starts or resumes"
        case .taskAcknowledge: "when you send a prompt"
        case .taskComplete: "a turn, run or checks finish, or a child reports"
        case .taskError: "an API error, a failed run, failing checks"
        case .inputRequired: "permission, a question, a Grill round"
        case .userSpam: "three prompts in ten seconds"
        case .sessionEnd: "when a session ends"
        case .resourceLimit: "context or the plan window past 90%, a rate limit"
        case .taskProgress: "a turn still running after ten minutes, if turned on"
        }
    }
}

/// One line as a tile that plays it, and reads ■ while it does.
private struct LineTile: View {
    @Environment(SoundPackStore.self) private var store
    let label: String
    let path: String
    let name: String
    @State private var hovering = false

    var body: some View {
        let playing = store.isPreviewing(path, of: name)
        Button { store.togglePreview(path, of: name) } label: {
            HStack(spacing: 8) {
                Image(systemName: playing ? "stop.fill" : "play.fill")
                    .font(.system(size: 9)).foregroundStyle(playing ? Color.white : Color.primary)
                    .frame(width: 22, height: 22)
                    .background(playing ? AnyShapeStyle(Color.accent) : AnyShapeStyle(.quaternary), in: Circle())
                Text(label).font(.callout).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).frame(height: 36)
            .background(Color.primary.opacity(hovering ? 0.08 : 0.04), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(playing ? Color.accent.opacity(0.6) : Color.primary.opacity(0.1)))
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(label)
        .accessibilityLabel("\(playing ? "Stop" : "Play") \(label)")
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
            get: { witness.isOptIn ? store.settings.enabledOptIns.contains(witness) : !store.settings.disabledWitnesses.contains(witness) },
            set: { store.settings.set(witness, on: $0) }
        )) {
            HStack(spacing: 8) {
                Text(witness.title)
                if witness.isOptIn { Text("off by default").font(.caption).foregroundStyle(.tertiary) }
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
                .accessibilityLabel("Volume")
            Image(systemName: "speaker.wave.3.fill").font(.caption).foregroundStyle(.secondary)
            Menu {
                ForEach(store.installed) { pack in
                    Button(pack.manifest.displayName) { store.settings.defaultPack = pack.id }
                }
                if store.installed.isEmpty { Text("Install a pack from Browse") }
            } label: {
                Text(store.settings.defaultPack.flatMap(store.installedPack).map { "Default: \($0.manifest.displayName)" } ?? "No default pack")
            }
            .menuStyle(.button).fixedSize()
            .disabled(!store.settings.enabled)
            .help("The pack a session speaks with when nothing else gives it one")
            SoundRotationMenu().disabled(!store.settings.enabled)
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

// MARK: - Choosing a pack (ADR-201)

/// *Sound Pack ▸* in a project's or a session's menu: Automatic, or one installed pack.
struct SoundPackMenu: View {
    @Environment(SoundPackStore.self) private var store
    @Environment(SessionStore.self) private var sessions

    enum Target {
        case project(String)
        case session(SessionID)
    }

    let target: Target

    private var chosen: String? {
        switch target {
        case .project(let path): sessions.state.soundPacks.byProject[path]
        case .session(let id): sessions.state.soundPacks.bySession[id]
        }
    }

    private func set(_ name: String?) {
        switch target {
        case .project(let path): store.setPack(name, forProject: path)
        case .session(let id): store.setPack(name, forSession: id)
        }
    }

    /// What Automatic means here, in words: the session's family, project, draw or the default.
    private var automatic: String {
        switch target {
        case .project:
            if !store.settings.rotation.isEmpty { return "Automatic (the rotation)" }
            return store.settings.defaultPack.flatMap(store.installedPack).map { "Automatic (\($0.manifest.displayName))" } ?? "Automatic"
        case .session(let id):
            guard chosen == nil else { return "Automatic" }
            return store.choice(for: id, draw: false).map { "Automatic (\(store.describe($0)))" } ?? "Automatic"
        }
    }

    var body: some View {
        Menu("Sound Pack") {
            Toggle(automatic, isOn: Binding(get: { chosen == nil }, set: { _ in set(nil) }))
            if !store.installed.isEmpty { Divider() }
            ForEach(store.installed) { pack in
                Toggle(pack.manifest.displayName, isOn: Binding(get: { chosen == pack.id }, set: { _ in set(pack.id) }))
            }
            Divider()
            Button("Browse Sound Packs…") { NotificationCenter.default.post(name: .clinicSounds, object: nil) }
        }
    }
}

/// The footer's rotation: which installed packs sessions draw from.
struct SoundRotationMenu: View {
    @Environment(SoundPackStore.self) private var store

    var body: some View {
        let count = store.settings.rotation.filter { store.installedPack($0) != nil }.count
        Menu {
            ForEach(store.installed) { pack in
                Toggle(pack.manifest.displayName, isOn: Binding(get: { store.isInRotation(pack.id) }, set: { _ in store.toggleRotation(pack.id) }))
            }
            if store.installed.isEmpty { Text("Install packs from Browse") }
            Divider()
            Button("Clear Rotation") { store.settings.rotation = [] }.disabled(store.settings.rotation.isEmpty)
        } label: {
            Text(count == 0 ? "No rotation" : "Rotation · \(count)")
        }
        .menuStyle(.button).fixedSize()
        .help("Sessions with no pack of their own, and none from their project, each draw one of these and keep it")
    }
}

// MARK: - peon-ping (ADR-203)

/// Says peon-ping is here too, what that means for Clinic's sessions, and what Clinic can do about it.
struct PeonPingBanner: View {
    @Environment(SoundPackStore.self) private var store
    let dismiss: () -> Void
    @State private var importing: PeonPing.Import?

    var body: some View {
        @Bindable var store = store
        let found = store.peonPing
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: found?.hooksInstalled == true ? "speaker.wave.2.bubble" : "square.and.arrow.down")
                .font(.title3).foregroundStyle(Color.accent)
            VStack(alignment: .leading, spacing: 6) {
                Text(found?.hooksInstalled == true ? "peon-ping is installed too" : "peon-ping's settings are here")
                    .font(.callout.weight(.semibold))
                Text(found?.hooksInstalled == true
                     ? "Its hooks in ~/.claude/settings.json play in Clinic's sessions as well, so each moment is heard twice. “peon pause” silences it everywhere; Clinic can quiet it in its own sessions and leave it playing elsewhere."
                     : "Clinic can take its default pack, volume, categories, rotation and per-folder packs.")
                    // Bounded, never fixedSize: measured for the window's minimum size at almost no width,
                    // an unbounded paragraph made the window taller than the screen (ADR-178).
                    .font(.caption).foregroundStyle(.secondary).lineLimit(3)
                HStack(spacing: 12) {
                    if found?.hooksInstalled == true {
                        Toggle("Quiet it in Clinic's sessions", isOn: $store.settings.quietPeonPing)
                            .toggleStyle(.checkbox)
                            .help("Sessions started from now on get a paused peon-ping of their own (CLAUDE_PEON_DIR). Running ones keep theirs.")
                    }
                    if found?.config != nil {
                        Button("Import Its Settings…") { importing = store.peonPingImport() }
                    }
                }
                .font(.callout)
            }
            Spacer(minLength: 8)
            Button(action: dismiss) { Image(systemName: "xmark").font(.caption.weight(.bold)) }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Color.accent.opacity(0.06))
        .sheet(item: Binding(get: { importing.map(ImportBox.init) }, set: { importing = $0?.plan })) { box in
            PeonPingImportSheet(plan: box.plan)
        }
    }

    private struct ImportBox: Identifiable {
        let plan: PeonPing.Import
        var id: Int { 0 }
    }
}

/// What importing peon-ping's settings will change, shown before it does (ADR-203).
struct PeonPingImportSheet: View {
    @Environment(SoundPackStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let plan: PeonPing.Import

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import peon-ping's settings").font(.title3.weight(.semibold))
            if plan.isEmpty {
                Text("Nothing in its config has a place in Clinic yet.").foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                if let pack = plan.defaultPack { line("Default pack", name(pack)) }
                if let volume = plan.volume { line("Volume", "\(Int((volume * 100).rounded()))%") }
                if !plan.disabledCategories.isEmpty { line("Turned off", plan.disabledCategories.map(\.title).sorted().joined(separator: ", ")) }
                if !plan.rotation.isEmpty { line("Rotation", plan.rotation.map(name).joined(separator: ", ")) }
                ForEach(plan.projectPacks.sorted(by: { $0.key < $1.key }), id: \.key) { path, pack in
                    line((path as NSString).lastPathComponent, name(pack) + (store.sessions?.state.soundPacks.byProject[path] != nil ? " (keeps its own)" : ""))
                }
            }
            .font(.callout)
            if !plan.missingPacks.isEmpty {
                Text("Not installed, so left out: \(plan.missingPacks.joined(separator: ", ")). Install them from Browse and import again.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if !plan.unmatchedRules.isEmpty {
                Text("Folder rules that match no project here: \(plan.unmatchedRules.joined(separator: ", ")).")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Text("peon-ping's own files are only read.").font(.caption2).foregroundStyle(.tertiary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Import") { store.apply(plan); dismiss() }
                    .keyboardShortcut(.defaultAction).disabled(plan.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func name(_ pack: String) -> String { store.installedPack(pack)?.manifest.displayName ?? pack }

    private func line(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
            Text(value)
        }
    }
}
