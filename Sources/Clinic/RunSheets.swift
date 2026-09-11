import AppKit
import SwiftUI
import ClinicCore

/// The Run sheets (ADR-122): the editor, the IDE import, and ⌃⌘R's picker.
struct RunSheet: View {
    @Environment(TabStore.self) private var tabs
    let request: RunSheetRequest
    @State private var mode: RunSheetRequest.Mode

    init(request: RunSheetRequest) {
        self.request = request
        _mode = State(initialValue: request.mode)
    }

    private var context: RunContext {
        let state = tabs.runs.fileState(checkout: request.checkout, projectPath: request.projectPath)
        return RunContext(tab: request.tabId.flatMap { id in tabs.tabs.first { $0.id == id } }, checkout: request.checkout,
                          projectPath: request.projectPath, file: state?.file, fileError: state?.error)
    }

    var body: some View {
        Group {
            switch mode {
            case .edit: RunEditorSheet(context: context, onImport: { mode = .importIDE })
            case .importIDE: RunImportSheet(context: context)
            case .choose: RunPickerSheet(context: context, onEdit: { mode = .edit })
            }
        }
        .task { tabs.runs.ensureLoaded(checkout: request.checkout, projectPath: request.projectPath) }
    }
}

/// The accent-tile header every "new"/editor sheet in Clinic opens with (ADR-121's look).
private struct RunSheetHeader: View {
    let symbol: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 12) {
            AccentTile(symbol: symbol, size: 34, glyph: 17)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title2.weight(.semibold))
                Text(subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            }
            Spacer()
        }
    }
}

// MARK: - Editor

/// One configuration while it is being edited. Compound members are held by `uid`, so renaming a new
/// configuration (which renames its id on save) cannot orphan a compound that includes it.
private struct EditableConfig: Identifiable, Equatable {
    struct EnvRow: Identifiable, Equatable { let id = UUID(); var key: String; var value: String }

    let uid = UUID()
    var id: String
    var isNew: Bool
    var name: String
    var icon: String
    var command: String
    var directory: String
    var env: [EnvRow]
    var rerun: Bool
    var device: RunDevicePlatform?
    var members: [UUID]?
    var extra: [String: JSONValue]

    var isCompound: Bool { members != nil }

    init(_ c: RunConfiguration, isNew: Bool = false) {
        id = c.id; self.isNew = isNew; name = c.name; icon = c.symbol; command = c.command ?? ""
        directory = c.directory ?? ""; env = (c.env ?? [:]).sorted { $0.key < $1.key }.map { EnvRow(key: $0.key, value: $0.value) }
        rerun = c.reruns; device = c.device; members = nil; extra = c.extra
    }
}

struct RunEditorSheet: View {
    @Environment(TabStore.self) private var tabs
    @Environment(\.dismiss) private var dismiss
    let context: RunContext
    let onImport: () -> Void

    @State private var configs: [EditableConfig] = []
    @State private var selection: UUID?
    @State private var loaded = false
    @State private var saveError: String?
    @State private var browsingIcon: IconTarget?

    /// The icon browser's target, while it is open (ADR-125).
    private struct IconTarget: Identifiable { let id: UUID }

    var body: some View {
        VStack(spacing: 0) {
            RunSheetHeader(symbol: "play.fill", title: "Run Configurations",
                           subtitle: context.projectName + " · " + RunConfigurationFile.relativePath)
                .padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 16)
            Divider()
            if let error = context.fileError {
                ContentUnavailableView {
                    Label("run.json can’t be read", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error + "\nFix the file, or ask Claude to; Clinic won’t overwrite it.")
                } actions: {
                    Button("Reveal run.json") { tabs.revealRunFile(context) }
                }
                .frame(maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    list.frame(width: 236)
                    Divider()
                    detail.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            Divider()
            footer.padding(.horizontal, 20).padding(.vertical, 14)
        }
        .frame(width: 800, height: 600)
        .onAppear(perform: load)
        // `-ClinicBrowseIconOnLaunch YES` (ADR-038): open the symbol browser on the first configuration,
        // which is a sheet inside a sheet and so beyond a smoke run's reach otherwise.
        .task {
            guard UserDefaults.standard.bool(forKey: "ClinicBrowseIconOnLaunch"), let first = configs.first else { return }
            try? await Task.sleep(for: .seconds(2))
            browsingIcon = IconTarget(id: first.uid)
        }
        .sheet(item: $browsingIcon) { target in
            SymbolBrowser(initial: configs.first { $0.uid == target.id }?.icon ?? "play.fill") { name in
                if let j = configs.firstIndex(where: { $0.uid == target.id }) { configs[j].icon = name }
            }
        }
    }

    // MARK: List

    private var list: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(configs) { c in
                    HStack(spacing: 9) {
                        AccentTile(symbol: SFSymbolCatalog.resolved(c.icon), size: 26, glyph: 14)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(c.name.isEmpty ? "Untitled" : c.name).lineLimit(1)
                            Text(subtitle(c)).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .padding(.vertical, 2)
                    .tag(c.uid)
                }
                .onMove { configs.move(fromOffsets: $0, toOffset: $1) }
            }
            .listStyle(.sidebar)
            Divider()
            HStack(spacing: 2) {
                Menu {
                    Button("New Configuration") { add(RunConfiguration(id: "", name: "New Configuration", command: "")) }
                    Button("New Compound") { addCompound() }
                    let suggestions = tabs.runs.suggestions(checkout: context.checkout, projectPath: context.projectPath)
                        .filter { s in !configs.contains { $0.command == s.command } }
                    if !suggestions.isEmpty {
                        Section("Detected") {
                            ForEach(suggestions) { s in
                                Button { add(s) } label: { Text(s.name); Text(s.command ?? "") }
                            }
                        }
                    }
                } label: { Image(systemName: "plus") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().padding(.horizontal, 6)
                Button { remove() } label: { Image(systemName: "minus") }
                    .buttonStyle(.borderless).disabled(selection == nil).padding(.horizontal, 6)
                Spacer()
                if (tabs.runs.importCounts[context.projectPath] ?? 0) > 0 {
                    Button("Import…", action: onImport).buttonStyle(.borderless).font(.callout).padding(.trailing, 8)
                }
            }
            .frame(height: 30)
        }
        .background(Color.primary.opacity(0.03))
    }

    private func subtitle(_ c: EditableConfig) -> String {
        if let members = c.members {
            let names = members.compactMap { uid in configs.first { $0.uid == uid }?.name }
            return names.isEmpty ? "No members" : names.joined(separator: " + ")
        }
        return c.command.isEmpty ? "No command" : c.command
    }

    // MARK: Detail

    @ViewBuilder private var detail: some View {
        if let i = configs.firstIndex(where: { $0.uid == selection }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    row("Name") { TextField("Name", text: $configs[i].name).textFieldStyle(.roundedBorder) }
                    row("Icon") { iconPicker(for: i) }
                    if configs[i].isCompound { membersEditor(for: i) } else { commandEditor(for: i) }
                }
                .padding(.horizontal, 24).padding(.vertical, 20)
            }
        } else {
            ContentUnavailableView {
                Label(configs.isEmpty ? "No configurations yet" : "Nothing selected", systemImage: "play.rectangle")
            } description: {
                Text(configs.isEmpty ? "Add one with +, pick a detected one, or let Claude write them." : "Choose a configuration on the left.")
            } actions: {
                if configs.isEmpty {
                    Button { dismiss(); tabs.setUpRunsWithClaude(projectPath: context.projectPath) } label: {
                        Label("Set Up with Claude…", systemImage: "sparkles")
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                }
            }
        }
    }

    private func row<C: View>(_ label: String, top: Bool = false, @ViewBuilder content: () -> C) -> some View {
        HStack(alignment: top ? .firstTextBaseline : .center, spacing: 12) {
            Text(label).foregroundStyle(.secondary).frame(width: 96, alignment: .trailing)
            VStack(alignment: .leading, spacing: 6) { content() }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func iconPicker(for i: Int) -> some View {
        let current = configs[i].icon
        let known = SFSymbolCatalog.exists(current)
        // The configuration's own icon leads, whether or not it is one of the quick picks: an agent
        // writes `run.json`, and it reaches well beyond any row that fits here (ADR-125).
        let quick = SFSymbolCatalog.suggested.contains(current) ? SFSymbolCatalog.suggested : [current] + SFSymbolCatalog.suggested
        return VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(28), spacing: 6), count: 12), alignment: .leading, spacing: 6) {
                ForEach(Array(quick.prefix(24)), id: \.self) { symbol in
                    let on = current == symbol
                    Button { configs[i].icon = symbol } label: {
                        Image(systemName: SFSymbolCatalog.resolved(symbol))
                            .font(.system(size: 13))
                            .frame(width: 28, height: 28)
                            .foregroundStyle(on ? Color.accentColor : Color.secondary)
                            .background(on ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
                            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(on ? Color.accentColor.opacity(0.5) : .clear))
                    }
                    .buttonStyle(.plain)
                    .help(symbol)
                }
            }
            HStack(spacing: 8) {
                Button("Browse Symbols…") { browsingIcon = IconTarget(id: configs[i].uid) }
                    .controlSize(.small)
                SymbolVariantControl(symbol: $configs[i].icon)
                if known {
                    Text(current).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            if !known {
                Label("“\(current)” isn’t a symbol on this Mac, so the play glyph stands in. Browse for one, or type its exact name.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private func commandEditor(for i: Int) -> some View {
        row("Command", top: true) {
            TextEditor(text: $configs[i].command)
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(5)
                .frame(height: 64)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.primary.opacity(0.1)))
            Label("Saving lets Claude run this from a session in \(context.projectName).", systemImage: "checkmark.shield")
                .font(.caption).foregroundStyle(.secondary)
        }
        row("Device") {
            Picker("", selection: $configs[i].device) {
                Text("None").tag(RunDevicePlatform?.none)
                ForEach(RunDevicePlatform.allCases) { p in Text(p.title).tag(RunDevicePlatform?.some(p)) }
            }
            .labelsHidden()
            .fixedSize()
            if let platform = configs[i].device {
                Text("Clinic gets the device chosen in the toolbar ready, booting it if needed, and runs the command with \(platform.environmentKey) set.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        row("Directory") {
            HStack(spacing: 6) {
                TextField(".", text: $configs[i].directory).textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced))
                Button("Choose…") { chooseDirectory(for: i) }
            }
        }
        row("Environment", top: true) { envEditor(for: i) }
        row("") {
            Toggle("Re-run after each turn that changes files", isOn: $configs[i].rerun).toggleStyle(.switch).controlSize(.small)
            Text("Only when it has already run in that checkout.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func envEditor(for i: Int) -> some View {
        VStack(spacing: 0) {
            HStack { Text("Name").frame(maxWidth: .infinity, alignment: .leading); Text("Value").frame(maxWidth: .infinity, alignment: .leading) }
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 8).padding(.vertical, 4)
            ForEach($configs[i].env) { $row in
                Divider()
                HStack(spacing: 8) {
                    TextField("NAME", text: $row.key)
                    TextField("value", text: $row.value)
                }
                .textFieldStyle(.plain)
                .font(.system(size: 11.5, design: .monospaced))
                .padding(.horizontal, 8).padding(.vertical, 5)
            }
            Divider()
            HStack(spacing: 2) {
                Button { configs[i].env.append(.init(key: "", value: "")) } label: { Image(systemName: "plus") }
                Button { if !configs[i].env.isEmpty { configs[i].env.removeLast() } } label: { Image(systemName: "minus") }
                    .disabled(configs[i].env.isEmpty)
                Spacer()
            }
            .buttonStyle(.borderless).padding(.horizontal, 6).frame(height: 24)
        }
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.primary.opacity(0.1)))
    }

    private func membersEditor(for i: Int) -> some View {
        row("Starts", top: true) {
            let candidates = configs.filter { !$0.isCompound && $0.uid != configs[i].uid }
            if candidates.isEmpty {
                Text("Add the configurations it should start first.").foregroundStyle(.secondary)
            }
            ForEach(candidates) { c in
                Toggle(c.name.isEmpty ? "Untitled" : c.name, isOn: Binding(
                    get: { configs[i].members?.contains(c.uid) ?? false },
                    set: { on in
                        var m = configs[i].members ?? []
                        if on { m.append(c.uid) } else { m.removeAll { $0 == c.uid } }
                        configs[i].members = m
                    }))
                .toggleStyle(.checkbox)
            }
            Text("All of them start at once, each in its own Run pane.").font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Button { tabs.revealRunFile(context) } label: { Label("Reveal run.json", systemImage: "doc") }
                .buttonStyle(.borderless).font(.callout)
            if let problem = validation ?? saveError {
                Text(problem).font(.caption).foregroundStyle(.orange).lineLimit(2)
            }
            Spacer()
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).controlSize(.large)
            Button("Save") { save() }.keyboardShortcut(.defaultAction).controlSize(.large)
                .disabled(context.fileError != nil || validation != nil)
        }
    }

    private var validation: String? {
        for c in configs {
            if c.name.trimmingCharacters(in: .whitespaces).isEmpty { return "Every configuration needs a name." }
            if c.isCompound, (c.members ?? []).isEmpty { return "“\(c.name)” starts nothing." }
            if !c.isCompound, c.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "“\(c.name)” has no command." }
        }
        return nil
    }

    // MARK: Model

    private func load() {
        guard !loaded else { return }
        loaded = true
        let file = context.file ?? RunConfigurationFile()
        var editable = file.configurations.map { EditableConfig($0) }
        for (i, c) in file.configurations.enumerated() where c.isCompound {
            editable[i].members = (c.compound ?? []).compactMap { id in editable.first { $0.id == id }?.uid }
        }
        configs = editable
        selection = configs.first?.uid
    }

    private func add(_ c: RunConfiguration) {
        var e = EditableConfig(c, isNew: true)
        if e.icon.isEmpty { e.icon = "play.fill" }
        configs.append(e)
        selection = e.uid
    }

    private func addCompound() {
        var e = EditableConfig(RunConfiguration(id: "", name: "New Compound", icon: "square.stack"), isNew: true)
        e.members = []
        configs.append(e)
        selection = e.uid
    }

    private func remove() {
        guard let uid = selection, let i = configs.firstIndex(where: { $0.uid == uid }) else { return }
        configs.remove(at: i)
        for j in configs.indices { configs[j].members?.removeAll { $0 == uid } }
        selection = configs[safeIndex: min(i, configs.count - 1)]?.uid
    }

    private func chooseDirectory(for i: Int) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = URL(fileURLWithPath: context.checkout)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let root = context.checkout.hasSuffix("/") ? context.checkout : context.checkout + "/"
        configs[i].directory = url.path == context.checkout ? "" : url.path.hasPrefix(root) ? String(url.path.dropFirst(root.count)) : url.path
    }

    private func save() {
        var file = context.file ?? RunConfigurationFile()
        var taken = Set(configs.filter { !$0.isNew }.map(\.id))
        var ids: [UUID: String] = [:]
        for c in configs {
            if c.isNew || c.id.isEmpty {
                let id = RunConfiguration.makeId(from: c.name, avoiding: taken)
                taken.insert(id)
                ids[c.uid] = id
            } else {
                ids[c.uid] = c.id
            }
        }
        file.configurations = configs.map { c in
            var out = RunConfiguration(id: ids[c.uid] ?? c.id, name: c.name.trimmingCharacters(in: .whitespaces),
                                       icon: c.icon == "play.fill" ? nil : c.icon)
            if let members = c.members {
                out.compound = members.compactMap { ids[$0] }
            } else {
                out.command = c.command.trimmingCharacters(in: .whitespacesAndNewlines)
                let dir = c.directory.trimmingCharacters(in: .whitespaces)
                out.directory = dir.isEmpty || dir == "." ? nil : dir
                let env = Dictionary(c.env.filter { !$0.key.isEmpty }.map { ($0.key, $0.value) }, uniquingKeysWith: { _, last in last })
                out.env = env.isEmpty ? nil : env
                out.rerunAfterTurn = c.rerun ? true : nil
                out.device = c.device
            }
            out.extra = c.extra
            return out
        }
        if let d = file.defaultId, file.configuration(d) == nil { file.defaultId = nil }
        do {
            try tabs.runs.save(file, checkout: context.checkout, projectPath: context.projectPath)
            dismiss()
        } catch {
            saveError = "Couldn’t save: \(error.localizedDescription)"
        }
    }
}

private extension Array {
    subscript(safeIndex index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

// MARK: - Import

/// A one-time copy of the project's IDE run configurations into `run.json`, with a reason for everything
/// that cannot come across (ADR-122).
struct RunImportSheet: View {
    @Environment(TabStore.self) private var tabs
    @Environment(\.dismiss) private var dismiss
    let context: RunContext
    @State private var candidates: [RunImportCandidate] = []
    @State private var chosen: Set<String> = []
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            RunSheetHeader(symbol: "square.and.arrow.down", title: "Import Run Configurations",
                           subtitle: "Found \(candidates.count) in \(context.projectName) · copied once into \(RunConfigurationFile.relativePath)")
                .padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 16)
            Divider()
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(candidates) { c in row(c) }
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
            }
            .frame(maxHeight: .infinity)
            Divider()
            HStack(spacing: 8) {
                Button { dismiss(); tabs.setUpRunsWithClaude(projectPath: context.projectPath) } label: {
                    Label("Set Up with Claude…", systemImage: "sparkles")
                }
                .buttonStyle(.borderless).foregroundStyle(Color.accentColor)
                if let error { Text(error).font(.caption).foregroundStyle(.orange) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).controlSize(.large)
                Button("Import \(chosen.count)") { importChosen() }.keyboardShortcut(.defaultAction).controlSize(.large)
                    .disabled(chosen.isEmpty || context.fileError != nil)
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
        }
        .frame(width: 620, height: 500)
        .task {
            let root = URL(fileURLWithPath: context.projectPath)
            let found = await Task.detached { RunImporter.candidates(in: root) }.value
            candidates = found
            chosen = Set(found.filter { $0.configuration != nil && $0.defaultSelected }.map(\.id))
        }
    }

    private func row(_ c: RunImportCandidate) -> some View {
        let importable = c.configuration != nil
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Toggle("", isOn: Binding(get: { chosen.contains(c.id) }, set: { on in
                // A compound brings its members with it; they are what it starts.
                if on { chosen.insert(c.id); chosen.formUnion(c.memberIds) } else { chosen.remove(c.id) }
            }))
            .toggleStyle(.checkbox).labelsHidden().disabled(!importable)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(c.name)
                    Text(c.kindLabel).font(.caption).foregroundStyle(.secondary)
                }
                if let problem = c.problem {
                    Text(problem).font(.caption).foregroundStyle(importable ? Color.orange : Color.secondary)
                } else if let command = c.configuration?.command {
                    Text(command).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                } else if let members = c.configuration?.compound {
                    Text(members.joined(separator: " + ") + ", at once").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(chosen.contains(c.id) ? Color.primary.opacity(0.04) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .opacity(importable ? 1 : 0.55)
    }

    private func importChosen() {
        let selected = candidates.filter { chosen.contains($0.id) }
        let merged = RunImporter.importing(selected, into: context.file ?? RunConfigurationFile())
        do {
            try tabs.runs.save(merged, checkout: context.checkout, projectPath: context.projectPath)
            dismiss()
        } catch {
            self.error = "Couldn’t save: \(error.localizedDescription)"
        }
    }
}

// MARK: - Picker (⌃⌘R)

/// Chooses what ⌘R runs. ↩ chooses, ⌘↩ chooses and runs; a detected entry can only be run. With nothing
/// configured it is also where ⌘R lands, so it offers the ways to set configurations up.
struct RunPickerSheet: View {
    @Environment(TabStore.self) private var tabs
    @Environment(\.dismiss) private var dismiss
    let context: RunContext
    let onEdit: () -> Void
    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var focused: Bool

    private struct Item: Identifiable {
        let config: RunConfiguration
        let detected: Bool
        var id: String { (detected ? "d:" : "c:") + config.id + (config.command ?? "") }
    }

    private var items: [Item] {
        let saved = (context.file?.configurations ?? []).map { Item(config: $0, detected: false) }
        let detected = tabs.runs.suggestions(checkout: context.checkout, projectPath: context.projectPath).map { Item(config: $0, detected: true) }
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let all = saved + detected
        guard !q.isEmpty else { return all }
        return all.filter { $0.config.name.lowercased().contains(q) || ($0.config.command ?? "").lowercased().contains(q) }
    }

    var body: some View {
        let selectedId = tabs.runs.selectedConfiguration(projectPath: context.projectPath, in: context.file)?.id
        VStack(spacing: 0) {
            TextField("Choose what ⌘R runs in \(context.projectName)", text: $query)
                .textFieldStyle(.plain).font(.title3).padding(12)
                .focused($focused)
                .onSubmit { choose(run: NSEvent.modifierFlags.contains(.command)) }
                .onChange(of: query) { highlighted = 0 }
                .onKeyPress(.downArrow) { highlighted = min(highlighted + 1, max(items.count - 1, 0)); return .handled }
                .onKeyPress(.upArrow) { highlighted = max(highlighted - 1, 0); return .handled }
                .onKeyPress(.escape) { dismiss(); return .handled }
            Divider()
            if items.isEmpty {
                ContentUnavailableView {
                    Label(query.isEmpty ? "Nothing to run yet" : "No matches", systemImage: "play.rectangle")
                } description: {
                    Text(query.isEmpty ? "Claude can read the build and write this project’s run configurations." : "")
                }
                .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                        HStack(spacing: 9) {
                            AccentTile(symbol: item.config.uiSymbol, size: 24, glyph: 12)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.config.name).lineLimit(1)
                                Text(item.config.command ?? (item.config.compound ?? []).joined(separator: " + "))
                                    .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            if item.detected {
                                Text("detected").font(.caption2).foregroundStyle(.secondary)
                                    .padding(.horizontal, 5).padding(.vertical, 1).background(.quaternary, in: Capsule())
                            } else if item.config.id == selectedId {
                                Image(systemName: "checkmark").font(.caption.weight(.semibold)).foregroundStyle(Color.accentColor)
                            }
                            RunStatusGlyph(run: tabs.runs.run(of: item.config, checkout: context.checkout), idleSymbol: "", size: 11)
                        }
                        .padding(.vertical, 2)
                        .listRowBackground(i == highlighted ? Color.accentColor.opacity(0.2) : Color.clear)
                        .contentShape(Rectangle())
                        .onTapGesture { highlighted = i; choose(run: false) }
                    }
                }
                .listStyle(.plain)
            }
            Divider()
            HStack(spacing: 14) {
                Button { dismiss(); tabs.setUpRunsWithClaude(projectPath: context.projectPath) } label: { Label("Set Up with Claude…", systemImage: "sparkles") }
                Button("Edit Configurations…", action: onEdit).disabled(context.fileError != nil)
                Spacer()
                Text("↩ Choose   ⌘↩ Run").font(.caption).foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless).font(.callout)
            .padding(.horizontal, 12).frame(height: 36)
        }
        .frame(width: 560, height: 420)
        .onAppear { focused = true }
    }

    private func choose(run: Bool) {
        guard items.indices.contains(highlighted) else { return }
        let item = items[highlighted]
        if item.detected {
            tabs.run(item.config, in: context)
        } else {
            tabs.runs.select(item.config.id, projectPath: context.projectPath)
            if run { tabs.run(item.config, in: context) }
        }
        dismiss()
    }
}
