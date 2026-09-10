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

struct PreferencesView: View {
    /// The Test Notification button goes through the real attention router (ADR-097).
    let tabs: TabStore
    @Environment(UsageService.self) private var usage
    @Environment(SnapshotService.self) private var snapshots
    @AppStorage(Prefs.reopenLastSession) private var reopenLastSession = false
    @AppStorage(Prefs.defaultModel) private var defaultModel = "default"
    @AppStorage(Prefs.hookTrace) private var hookTrace = false
    @AppStorage("ClinicShowUsage") private var showUsage = true
    @AppStorage("ClinicShowTabBar") private var showTabBar = true
    @AppStorage("ClinicMergeMethod") private var mergeMethod = "squash"
    @AppStorage("ClinicArchiveWorktree") private var archiveWorktree = "ask"
    @AppStorage("ClinicCheckForUpdates") private var checkForUpdates = true
    @AppStorage("ClinicShowStatusItem") private var showStatusItem = true
    @AppStorage("ClinicQuitBehaviour") private var quitBehaviour = "ask"
    /// Smoke tests pick a tab with `-ClinicPreferencesTab <name>`.
    @State private var tab = UserDefaults.standard.string(forKey: "ClinicPreferencesTab") ?? "general"
    /// Registering a login item or the wake agent can be refused in System Settings; show why.
    @State private var wakeError: String?

    var body: some View {
        TabView(selection: $tab) {
            Form {
                Toggle("Reopen last session on launch", isOn: $reopenLastSession)
                Toggle("Check for updates daily", isOn: $checkForUpdates)
                Toggle("Show menu bar icon", isOn: $showStatusItem)
                Picker("When quitting with running sessions", selection: $quitBehaviour) {
                    Text("Ask").tag("ask"); Text("Quit (stop cleanly)").tag("quit"); Text("Background all").tag("background"); Text("Hide the window instead").tag("hide")
                }
                Toggle("Show tab bar", isOn: $showTabBar)
                Toggle("Show Claude usage in the sidebar", isOn: $showUsage)
                LabeledContent("Claude account") {
                    if usage.isConnected {
                        HStack { Text("Connected").foregroundStyle(.secondary); Button("Disconnect") { usage.disconnect() } }
                    } else {
                        Button("Connect…") { Task { await usage.connect() } }
                    }
                }
                Text("Connecting reads Claude Code's sign-in from your Keychain to show plan usage; nothing is stored by Clinic.").font(.caption).foregroundStyle(.secondary)
                Picker("When archiving a session in a worktree", selection: $archiveWorktree) {
                    Text("Ask").tag("ask"); Text("Always trash the worktree").tag("always"); Text("Never trash").tag("never")
                }
                Picker("Merge pull requests with", selection: $mergeMethod) {
                    Text("Squash").tag("squash"); Text("Merge commit").tag("merge"); Text("Rebase").tag("rebase")
                }
                Picker("Default model for new sessions", selection: $defaultModel) {
                    ForEach(["default", "sonnet", "opus", "haiku"], id: \.self) { Text($0.capitalized).tag($0) }
                }
                Text("Per-project choices in the New Session sheet override this.").font(.caption).foregroundStyle(.secondary)

                Toggle("Launch Clinic at login", isOn: Binding(
                    get: { LaunchAtLogin.isEnabled },
                    set: { wakeError = LaunchAtLogin.setEnabled($0) }))
                Toggle("Run automations when Clinic isn't open", isOn: Binding(
                    get: { AutomationWake.isEnabled },
                    set: { wakeError = AutomationWake.setEnabled($0) }))
                Text("Automations normally run only while Clinic is running. With this on, a small background helper reopens Clinic hidden every five minutes so anything due can run — which means a job set for 09:00 may start as late as 09:04. Quitting Clinic on purpose switches it off until your next login.")
                    .font(.caption).foregroundStyle(.secondary)
                if let wakeError {
                    Label(wakeError, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                }
            }
            .formStyle(.grouped)
            .tag("general")
            .tabItem { Label("General", systemImage: "gear") }

            NotificationPreferences(tabs: tabs)
            .tag("notifications")
            .tabItem { Label("Notifications", systemImage: "bell") }

            Form {
                Text("Tools the agent can call on Clinic through MCP. Each session started from Clinic sees the enabled ones.").font(.caption).foregroundStyle(.secondary)
                ForEach(MCPToolSpec.all) { spec in ToolToggle(spec: spec) }
            }
            .formStyle(.grouped)
            .tag("tools")
            .tabItem { Label("Session tools", systemImage: "wrench.and.screwdriver") }

            ShortcutsPreferences()
            .tag("shortcuts")
            .tabItem { Label("Shortcuts", systemImage: "keyboard") }

            Form {
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
                LabeledContent("Diff snapshots") {
                    HStack(spacing: 8) {
                        Text(snapshots.diskUsage == 0 ? "None" : ByteCountFormatter.string(fromByteCount: snapshots.diskUsage, countStyle: .file))
                            .foregroundStyle(.secondary).monospacedDigit()
                        Button("Clear") { snapshots.clear() }.disabled(snapshots.diskUsage == 0)
                    }
                }
                Text("Turn diffs are git trees Clinic writes to its own object store; your repositories are never written to. Clearing them loses the turn history, not any work.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Clinic never writes to ~/.claude. Its own state lives in Application Support.").font(.caption).foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            .tag("diagnostics")
            .task { snapshots.refreshDiskUsage() }
            .tabItem { Label("Diagnostics", systemImage: "stethoscope") }
        }
        .frame(width: 560, height: 420)
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
                Text("Notifications are posted when a session finishes or needs you and Clinic is not in front of it.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Sound") {
                if player.sounds.isEmpty {
                    Text("Clinic uses the standard notification sound. Add your own audio files to hear those instead.")
                        .font(.caption).foregroundStyle(.secondary)
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
                    .frame(height: min(CGFloat(player.sounds.sounds.count) * 24 + 10, 154))
                    .alternatingRowBackgrounds()
                    Text(player.sounds.sounds.count == 1
                         ? "Every notification plays this file."
                         : "Notifications take these in turn, top to bottom, so two in a row never sound alike. Drag to reorder.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                HStack {
                    Button("Add Sound…", action: addSounds)
                    Spacer()
                    Button("Test Notification", action: test)
                }
            }

            if let message {
                Label(message, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
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
