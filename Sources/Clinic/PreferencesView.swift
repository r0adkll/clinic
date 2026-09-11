import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ClinicCore

/// Milestone 2 preferences (ADR-038 lifted the "no window" rule for milestone 2). Keys are UserDefaults-backed.
enum Prefs {
    static let reopenLastSession = "ClinicReopenLastSession"
    static let defaultModel = "ClinicDefaultModel"
    /// Master on/off. The files it plays, if any, are ADR-097's `NotificationSounds.defaultsKey`.
    static let notificationSound = "ClinicNotificationSound"
    static let hookTrace = "ClinicHookTrace"
}

/// The panes of the settings window (ADR-108). One word each, and each one a subject rather than a
/// bucket: what was "General" held startup, window chrome, an account, session defaults and a git
/// preference in one flat list.
enum SettingsPane: String, CaseIterable, Identifiable {
    case general, sessions, notifications, shortcuts, advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .sessions: "Sessions"
        case .notifications: "Notifications"
        case .shortcuts: "Shortcuts"
        case .advanced: "Advanced"
        }
    }

    /// The outline glyphs the rest of Clinic draws with — `terminal`, `bell`, `wrench` and the two
    /// the settings tabs already used. The `.fill` variants a System Settings tile wants were the
    /// only filled symbols in the app, and they read as someone else's icon set.
    var symbol: String {
        switch self {
        case .general: "gear"
        case .sessions: "terminal"
        case .notifications: "bell"
        case .shortcuts: "keyboard"
        case .advanced: "wrench.and.screwdriver"
        }
    }

    /// Smoke tests pick a pane with `-ClinicPreferencesTab <name>`. The names predate ADR-108, which
    /// folded the MCP tool list into Sessions and renamed Diagnostics, so the old two still resolve.
    static func named(_ raw: String?) -> SettingsPane {
        switch raw {
        case "tools": .sessions
        case "diagnostics": .advanced
        default: SettingsPane(rawValue: raw ?? "") ?? .general
        }
    }
}

/// The settings window (ADR-108): a source list beside one pane, in a window the reader can resize
/// and that remembers the size. The panes are far too different in length to share one fixed frame —
/// Shortcuts is ~40 rows and Advanced is four.
struct PreferencesView: View {
    static let windowID = "settings"

    /// The Test Notification button goes through the real attention router (ADR-097).
    let tabs: TabStore
    @State private var selection: SettingsPane? = SettingsPane.named(UserDefaults.standard.string(forKey: "ClinicPreferencesTab"))

    private var pane: SettingsPane { selection ?? .general }

    var body: some View {
        NavigationSplitView {
            // The `List` is wrapped rather than being the column's root: a bare list as the root of a
            // split view's sidebar renders as an inset floating panel with the title bar above it,
            // where Clinic's main window — whose sidebar is also a `VStack` around a `List` — gets
            // the flat, full-height column the traffic lights sit on. This is that column.
            VStack(spacing: 0) {
                List(SettingsPane.allCases, selection: $selection) { pane in
                    Label { Text(pane.title) } icon: { SettingsPaneIcon(pane: pane) }
                        .tag(pane)
                }
                .listStyle(.sidebar)
            }
            .navigationSplitViewColumnWidth(215)
        } detail: {
            Group {
                switch pane {
                case .general: GeneralPane().settingsColumn()
                case .sessions: SessionsPane().settingsColumn()
                case .notifications: NotificationPreferences(tabs: tabs).settingsColumn()
                case .shortcuts: ShortcutsPreferences()
                case .advanced: AdvancedPane().settingsColumn()
                }
            }
            .frame(minWidth: 430, maxWidth: .infinity, maxHeight: .infinity)
            // The pane's name belongs in the title bar and nowhere else: naming it again at the top
            // of the content said the same word twice, one line apart. The title bar is also what
            // gives the window a toolbar, which is what runs the source list up behind the traffic
            // lights.
            .navigationTitle(pane.title)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 660, idealWidth: 780, maxWidth: .infinity,
               minHeight: 430, idealHeight: 560, maxHeight: .infinity)
        .background(SettingsWindowConfigurator())
    }
}

/// Makes the settings window resizable and gives it a frame of its own to remember.
///
/// SwiftUI's `Settings` scene sizes its window from the content, so a fixed `.frame` on the content
/// is what made the old window unresizable. The flexible frame above is most of the fix; the style
/// mask is asserted anyway because the scene decides the mask once, before the content has a size.
private struct SettingsWindowConfigurator: View {
    static let autosave = "ClinicSettings"

    var body: some View {
        WindowAccessor { window in
            window.styleMask.insert(.resizable)
            guard window.frameAutosaveName != Self.autosave else { return }
            // Nothing saved under our own name yet: a first run, or the first launch after ADR-108,
            // where the window would otherwise inherit the 560 × 508 frame the old fixed-size one
            // left in SwiftUI's slot — narrower than this window's minimum, so it would open
            // clamped to its floor rather than at a comfortable size.
            let hasSaved = UserDefaults.standard.object(forKey: "NSWindow Frame " + Self.autosave) != nil
            window.setFrameAutosaveName(Self.autosave)
            // The `Settings` scene sets the window's content size from the SwiftUI content *after*
            // the view lands in it, so a frame applied here is overwritten a moment later. One turn
            // of the run loop later it sticks, and AppKit keeps it from then on.
            Task { @MainActor in
                window.styleMask.insert(.resizable)
                // The scene pins the window to the content's measured size by clamping both ends.
                // The floor is real (the panes stop reading below it); the ceiling is not.
                window.contentMinSize = NSSize(width: 660, height: 430)
                window.contentMaxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
                if hasSaved { window.setFrameUsingName(Self.autosave) }
                else { window.setContentSize(NSSize(width: 780, height: 560)); window.center() }
            }
        }
        .frame(width: 0, height: 0)
    }
}

// MARK: - Shared chrome

/// A source-list tile: one of Clinic's own glyphs on a rounded square that takes the system accent
/// colour. The tile is what makes a source list read as a *settings* source list; the accent is what
/// keeps it Clinic's rather than System Settings' box of crayons, and it means the five panes are
/// distinguished by their glyph, which is the part that carries meaning.
private struct SettingsPaneIcon: View {
    let pane: SettingsPane

    var body: some View {
        Image(systemName: pane.symbol)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color.accentColor)
            .frame(width: 20, height: 20)
            .background(Color.accentColor.opacity(0.16), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

enum SettingsMetrics {
    /// The pane's column. A grouped `Form` caps and centres its own boxes once it is wider than
    /// about this, so pinning the column here keeps every pane on one measure rather than letting a
    /// zoomed window decide. It also bounds the pane's ideal width: a `Section` footer is one long
    /// unwrapped line of text, and left to itself it asked for a 1027 pt window on first open.
    static let column: CGFloat = 760
    /// The grouped form's own inset from that column, for chrome that has to line up with its boxes.
    static let inset: CGFloat = 22
}

extension View {
    /// Holds a pane to the column, centred in whatever width the window has.
    func settingsColumn() -> some View {
        frame(maxWidth: SettingsMetrics.column).frame(maxWidth: .infinity)
    }
}

// MARK: - General

private struct GeneralPane: View {
    @Environment(UsageService.self) private var usage
    @AppStorage(Prefs.reopenLastSession) private var reopenLastSession = false
    @AppStorage("ClinicCheckForUpdates") private var checkForUpdates = true
    @AppStorage("ClinicShowTabBar") private var showTabBar = true
    @AppStorage("ClinicShowStatusItem") private var showStatusItem = true
    @AppStorage("ClinicShowUsage") private var showUsage = true
    @AppStorage("ClinicQuitBehaviour") private var quitBehaviour = "ask"
    /// Registering a login item or the wake agent can be refused in System Settings; show why, next
    /// to the toggle that was refused rather than at the foot of the pane.
    @State private var loginError: String?
    @State private var wakeError: String?

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Launch Clinic at login", isOn: Binding(
                    get: { LaunchAtLogin.isEnabled },
                    set: { loginError = LaunchAtLogin.setEnabled($0) }))
                RefusalLabel(loginError)
                Toggle("Reopen the last session on launch", isOn: $reopenLastSession)
                Toggle("Check for updates daily", isOn: $checkForUpdates)
            }

            Section {
                Toggle("Run automations when Clinic isn't open", isOn: Binding(
                    get: { AutomationWake.isEnabled },
                    set: { wakeError = AutomationWake.setEnabled($0) }))
                RefusalLabel(wakeError)
            } header: {
                Text("Automations")
            } footer: {
                Text("Automations normally run only while Clinic is running. With this on, a small background helper reopens Clinic hidden every five minutes so anything due can run — which means a job set for 09:00 may start as late as 09:04. Quitting Clinic on purpose switches it off until your next login.")
            }

            Section("Window") {
                Toggle("Show the tab bar", isOn: $showTabBar)
                Toggle("Show the menu bar icon", isOn: $showStatusItem)
                Picker("When quitting with running sessions", selection: $quitBehaviour) {
                    Text("Ask").tag("ask")
                    Text("Quit (stop cleanly)").tag("quit")
                    Text("Background all").tag("background")
                    Text("Hide the window instead").tag("hide")
                }
            }

            Section {
                LabeledContent("Account") {
                    if usage.isConnected {
                        HStack(spacing: 8) {
                            Text("Connected").foregroundStyle(.secondary)
                            Button("Disconnect") { usage.disconnect() }
                        }
                    } else {
                        Button("Connect…") { Task { await usage.connect() } }
                    }
                }
                Toggle("Show usage in the sidebar", isOn: $showUsage)
                    .disabled(!usage.isConnected)
            } header: {
                Text("Claude account")
            } footer: {
                Text("Connecting reads Claude Code's sign-in from your Keychain to show plan usage; nothing is stored by Clinic.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Sessions

private struct SessionsPane: View {
    @AppStorage(Prefs.defaultModel) private var defaultModel = "default"
    @AppStorage("ClinicArchiveWorktree") private var archiveWorktree = "ask"
    @AppStorage("ClinicMergeMethod") private var mergeMethod = "squash"

    var body: some View {
        Form {
            Section {
                Picker("Default model", selection: $defaultModel) {
                    ForEach(["default", "sonnet", "opus", "haiku"], id: \.self) { Text($0.capitalized).tag($0) }
                }
            } header: {
                Text("New sessions")
            } footer: {
                Text("Per-project choices in the New Session sheet override this.")
            }

            Section("Archiving") {
                Picker("When the session is in a worktree", selection: $archiveWorktree) {
                    Text("Ask").tag("ask")
                    Text("Always trash the worktree").tag("always")
                    Text("Never trash").tag("never")
                }
            }

            Section("Pull requests") {
                Picker("Merge with", selection: $mergeMethod) {
                    Text("Squash").tag("squash")
                    Text("Merge commit").tag("merge")
                    Text("Rebase").tag("rebase")
                }
            }

            Section("Agent tools") {
                // Above the list rather than in the section's footer: this introduces seven rows of
                // bare tool names, and a footer would only reach the reader after all of them.
                Text("Tools the agent can call on Clinic through MCP. Each session started from Clinic sees the enabled ones.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(MCPToolSpec.all) { spec in ToolToggle(spec: spec) }
            }
        }
        .formStyle(.grouped)
    }
}

struct ToolToggle: View {
    let spec: MCPToolSpec
    @State private var on: Bool = false
    var body: some View {
        Toggle(isOn: $on) {
            VStack(alignment: .leading, spacing: 1) {
                Text(spec.name).font(.system(.body, design: .monospaced))
                Text(spec.description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .onAppear { on = MCPToolService.isEnabled(spec) }
        .onChange(of: on) { UserDefaults.standard.set(on, forKey: "ClinicTool_" + spec.name) }
    }
}

// MARK: - Advanced

private struct AdvancedPane: View {
    @Environment(SnapshotService.self) private var snapshots
    @AppStorage(Prefs.hookTrace) private var hookTrace = false

    var body: some View {
        Form {
            Section {
                Toggle("Record hook payloads to a trace file", isOn: $hookTrace)
                LabeledContent("Trace and state files") {
                    Button("Reveal in Finder") {
                        let dir = ClinicPaths.appSupport.appendingPathComponent("Clinic")
                        NSWorkspace.shared.activateFileViewerSelecting([dir])
                    }
                }
                LabeledContent("Unified log") {
                    Button("Copy log command") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("/usr/bin/log show --info --predicate 'subsystem == \"com.r0adkll.clinic\" OR subsystem == \"com.mitchellh.ghostty\"' --last 10m --style compact", forType: .string)
                    }
                }
            } header: {
                Text("Diagnostics")
            } footer: {
                Text("Clinic never writes to ~/.claude. Its own state lives in Application Support.")
            }

            Section {
                LabeledContent("On disk") {
                    HStack(spacing: 8) {
                        Text(snapshots.diskUsage == 0 ? "None" : ByteCountFormatter.string(fromByteCount: snapshots.diskUsage, countStyle: .file))
                            .foregroundStyle(.secondary).monospacedDigit()
                        Button("Clear") { snapshots.clear() }.disabled(snapshots.diskUsage == 0)
                    }
                }
            } header: {
                Text("Diff snapshots")
            } footer: {
                Text("Turn diffs are git trees Clinic writes to its own object store; your repositories are never written to. Clearing them loses the turn history, not any work.")
            }
        }
        .formStyle(.grouped)
        .task { snapshots.refreshDiskUsage() }
    }
}

/// A refusal from System Settings, in the row under the toggle that was refused. Draws nothing when
/// there is nothing to say, so the section does not reserve a gap for an error that never comes.
private struct RefusalLabel: View {
    let text: String?
    init(_ text: String?) { self.text = text }
    var body: some View {
        if let text {
            Label(text, systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.orange)
        }
    }
}

// MARK: - Notifications

/// The Notifications pane: the master switch, the sound rotation, and the two ways to test it (ADR-097).
struct NotificationPreferences: View {
    let tabs: TabStore
    @Environment(NotificationSoundPlayer.self) private var player
    @AppStorage(Prefs.notificationSound) private var notificationSound = false
    /// Why the last ▶ or Add made no noise, if it made none.
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                Toggle("Play a sound with notifications", isOn: $notificationSound)
            } footer: {
                Text("Notifications are posted when a session finishes or needs you and Clinic is not in front of it.")
            }

            Section {
                if player.sounds.isEmpty {
                    Text("Clinic uses the standard notification sound. Add your own audio files to hear those instead.")
                        .foregroundStyle(.secondary)
                } else {
                    List {
                        ForEach(player.sounds.sounds) { sound in
                            SoundRow(sound: sound, message: $message)
                        }
                        .onMove { player.sounds.move(fromOffsets: $0, toOffset: $1) }
                        .onDelete { offsets in
                            for id in offsets.map({ player.sounds.sounds[$0].id }) { player.sounds.remove(id) }
                        }
                    }
                    // The window is resizable now (ADR-108), so the rotation can show a dozen files
                    // before it starts scrolling instead of six.
                    .frame(height: min(CGFloat(player.sounds.sounds.count) * 24 + 10, 298))
                    .alternatingRowBackgrounds()
                }

                HStack {
                    Button("Add Sound…", action: addSounds)
                    Spacer()
                    Button("Test Notification", action: test)
                }
                RefusalLabel(message)
            } header: {
                Text("Sound")
            } footer: {
                Text(player.sounds.sounds.count > 1
                     ? "Notifications take these in turn, top to bottom, so two in a row never sound alike. Drag to reorder."
                     : "Every notification plays this file.")
                    .opacity(player.sounds.isEmpty ? 0 : 1)
            }
        }
        .formStyle(.grouped)
    }

    private func addSounds() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio]
        panel.prompt = "Add"
        panel.message = "Choose audio files to play with notifications."
        guard panel.runModal() == .OK else { return }
        message = nil
        for url in panel.urls { player.sounds.append(path: url.path) }
    }

    /// The real router, not a shortcut around it: a test that took a private path would be testing
    /// something other than the thing it is trusted to test.
    private func test() {
        message = notificationSound ? nil : "Sound is off, so this notification is silent."
        tabs.notify(nil, sessionId: nil, title: "Clinic", body: "This is a test notification.", kind: .finished)
    }
}

private struct SoundRow: View {
    let sound: NotificationSounds.Sound
    @Binding var message: String?
    @Environment(NotificationSoundPlayer.self) private var player

    var body: some View {
        let readable = player.isReadable(sound)
        HStack(spacing: 8) {
            Button {
                message = player.preview(sound)
            } label: {
                Image(systemName: "play.circle")
            }
            .buttonStyle(.borderless).disabled(!readable).help("Play this sound")
            Text(sound.name).lineLimit(1).truncationMode(.middle)
            if !readable {
                Text("missing").font(.caption).foregroundStyle(.orange)
                    .help(sound.path + " is no longer readable. It is skipped until it comes back.")
            }
            Spacer()
            Button {
                message = nil
                player.sounds.remove(sound.id)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless).help("Remove")
        }
        .help(sound.path)
    }
}
