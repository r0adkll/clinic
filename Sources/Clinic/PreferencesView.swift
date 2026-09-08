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

    var body: some View {
        TabView {
            Form {
                Toggle("Reopen last session on launch", isOn: $reopenLastSession)
                Toggle("Check for updates daily", isOn: $checkForUpdates)
                Toggle("Show menu bar icon", isOn: $showStatusItem)
                Toggle("Show tab bar", isOn: $showTabBar)
                Toggle("Show Claude usage in the sidebar", isOn: $showUsage)
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
            .tabItem { Label("General", systemImage: "gear") }

            Form {
                Toggle("Play a sound with notifications", isOn: $notificationSound)
                Text("Notifications are posted when a session finishes or needs you and Clinic is not in front of it.").font(.caption).foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            .tabItem { Label("Notifications", systemImage: "bell") }

            Form {
                Text("Tools the agent can call on Clinic through MCP. Each session started from Clinic sees the enabled ones.").font(.caption).foregroundStyle(.secondary)
                ForEach(MCPToolSpec.all) { spec in ToolToggle(spec: spec) }
            }
            .formStyle(.grouped)
            .tabItem { Label("Session tools", systemImage: "wrench.and.screwdriver") }

            Form {
                Toggle("Record hook payloads to a trace file", isOn: $hookTrace)
                LabeledContent("Trace and state files") {
                    Button("Reveal in Finder") {
                        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Clinic")
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
            .tabItem { Label("Diagnostics", systemImage: "stethoscope") }
        }
        .frame(width: 520, height: 360)
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
