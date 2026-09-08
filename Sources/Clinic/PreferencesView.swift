import SwiftUI
import ClinicCore

/// Milestone 2 preferences (ADR-038 lifted the "no window" rule for milestone 2). Keys are UserDefaults-backed.
enum Prefs {
    static let reopenLastSession = "ClinicReopenLastSession"
    static let defaultModel = "ClinicDefaultModel"
    static let notificationSound = "ClinicNotificationSound"
    static let hookTrace = "ClinicHookTrace"
}

struct PreferencesView: View {
    @Environment(UsageService.self) private var usage
    @AppStorage(Prefs.reopenLastSession) private var reopenLastSession = false
    @AppStorage(Prefs.defaultModel) private var defaultModel = "default"
    @AppStorage(Prefs.notificationSound) private var notificationSound = false
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
            }
            .formStyle(.grouped)
            .tag("general")
            .tabItem { Label("General", systemImage: "gear") }

            Form {
                Toggle("Play a sound with notifications", isOn: $notificationSound)
                Text("Notifications are posted when a session finishes or needs you and Clinic is not in front of it.").font(.caption).foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
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
                Text("Clinic never writes to ~/.claude. Its own state lives in Application Support.").font(.caption).foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            .tag("diagnostics")
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
