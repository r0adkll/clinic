import AppKit
import Observation
import SwiftUI
import ClinicCore

/// The devices runs target, and each project's choice among them (ADR-124).
@MainActor
@Observable
final class RunDeviceStore {
    /// As last listed; nil for a platform not listed yet.
    private(set) var devices: [RunDevicePlatform: [RunDevice]] = [:]
    private(set) var loading: Set<RunDevicePlatform> = []
    /// Boots under way, by device, so two runs that need the same emulator wait for one boot.
    @ObservationIgnored private var inflight: [String: Task<[String: String], any Error>] = [:]
    let sessions: SessionStore

    init(sessions: SessionStore) { self.sessions = sessions }

    func refresh(_ platform: RunDevicePlatform, projectPath: String) {
        guard !loading.contains(platform) else { return }
        loading.insert(platform)
        Task {
            let list = await RunDeviceProbe.list(platform, projectRoot: projectPath)
            devices[platform] = list
            loading.remove(platform)
        }
    }

    /// What a run in this project would use: the remembered device while it is listed, else a running
    /// one, else the first emulator or simulator (which the run boots).
    func chosen(_ platform: RunDevicePlatform, projectPath: String) -> RunDevice? {
        RunDeviceChoice.pick(devices[platform] ?? [], remembered: sessions.state.runDeviceByProject[projectPath]?[platform.rawValue])
    }

    func choose(_ device: RunDevice, projectPath: String) {
        guard sessions.state.runDeviceByProject[projectPath]?[device.platform.rawValue] != device.id else { return }
        sessions.update { $0.runDeviceByProject[projectPath, default: [:]][device.platform.rawValue] = device.id }
    }

    /// Lists afresh (so "running" is current), picks, and gets the device ready. Returns the device and
    /// the environment the command needs.
    func prepare(_ platform: RunDevicePlatform, projectPath: String,
                 progress: @escaping @Sendable (String) -> Void) async throws -> (RunDevice, [String: String]) {
        let list = await RunDeviceProbe.list(platform, projectRoot: projectPath)
        devices[platform] = list
        guard let device = chosen(platform, projectPath: projectPath) else {
            throw RunDeviceError(platform == .android
                ? "No Android device is connected and there are no emulators. Connect a device, or create an emulator in Android Studio's Device Manager."
                : "No iOS simulators are installed. Add one in Xcode's Devices and Simulators window.")
        }
        if device.isRunning, device.problem == nil {
            return (device, try await RunDeviceProbe.prepare(device, projectRoot: projectPath, progress: progress))
        }
        let task = inflight[device.id] ?? Task { try await RunDeviceProbe.prepare(device, projectRoot: projectPath, progress: progress) }
        inflight[device.id] = task
        defer { inflight[device.id] = nil; refresh(platform, projectPath: projectPath) }
        // A stopped run's prepare task is cancelled, but the shared boot is not: another run may be
        // waiting on it, and a booted emulator is worth having. The stopped run ignores the result.
        return (device, try await task.value)
    }
}

// MARK: - Toolbar

/// The device capsule beside the Run pill (ADR-124), shown while the selected configuration installs
/// onto a device: which device the next run uses, and a popover of every one it could.
struct RunDeviceControl: View {
    @Environment(TabStore.self) private var tabs
    let platform: RunDevicePlatform
    let projectPath: String
    @State private var showingDevices = false

    private var store: RunDeviceStore { tabs.runs.devices }

    var body: some View {
        let device = store.chosen(platform, projectPath: projectPath)
        Button { showingDevices.toggle() } label: {
            HStack(spacing: 7) {
                Image(systemName: device?.symbol ?? "iphone").font(.system(size: 12))
                    .foregroundStyle(device?.isRunning == true ? .primary : .secondary)
                Text(label(device)).lineLimit(1).truncationMode(.tail)
                    .foregroundStyle(device == nil ? .secondary : .primary)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
            }
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 12)
            .frame(width: 176, height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help(device))
        .popover(isPresented: $showingDevices, arrowEdge: .bottom) {
            RunDevicePopover(platform: platform, projectPath: projectPath)
        }
        .task(id: projectPath) { if store.devices[platform] == nil { store.refresh(platform, projectPath: projectPath) } }
        .onChange(of: showingDevices) { if showingDevices { store.refresh(platform, projectPath: projectPath) } }
        .task {
            guard UserDefaults.standard.string(forKey: "ClinicToolbarPopoverOnLaunch") == "device" else { return }
            try? await Task.sleep(for: .seconds(5))
            showingDevices = true
        }
    }

    private func label(_ device: RunDevice?) -> String {
        if let device { return device.name }
        if store.devices[platform] == nil { return "Looking…" }
        return platform == .android ? "No devices" : "No simulators"
    }

    private func help(_ device: RunDevice?) -> String {
        guard let device else { return "Choose the \(platform.title.lowercased()) runs install onto" }
        return device.isRunning ? "Runs install onto \(device.name)" : "Runs boot \(device.name) first, then install onto it"
    }
}

/// Every device a run could target, grouped as Android Studio and Xcode group them.
struct RunDevicePopover: View {
    @Environment(TabStore.self) private var tabs
    let platform: RunDevicePlatform
    let projectPath: String

    private var store: RunDeviceStore { tabs.runs.devices }

    var body: some View {
        let list = store.devices[platform] ?? []
        let chosen = store.chosen(platform, projectPath: projectPath)
        PopoverMenu(width: 320) {
            if list.isEmpty {
                PopoverMenuNote(text: store.loading.contains(platform) ? "Looking for devices…"
                                : platform == .android
                                    ? "No devices or emulators. Connect a device with USB debugging on, or create an emulator in Android Studio's Device Manager."
                                    : "No simulators. Add one in Xcode's Devices and Simulators window.")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(groups(list), id: \.title) { group in
                            PopoverMenuHeader(title: group.title)
                            ForEach(group.devices) { device in
                                PopoverMenuRow(title: device.name, subtitle: device.problem,
                                               trailing: trailing(device), checked: device.id == chosen?.id) {
                                    store.choose(device, projectPath: projectPath)
                                } icon: { Image(systemName: device.symbol) }
                                .disabled(device.problem != nil)
                            }
                        }
                    }
                }
                .frame(maxHeight: 420)
                .fixedSize(horizontal: false, vertical: true)
            }
            PopoverMenuDivider()
            PopoverMenuRow(title: store.loading.contains(platform) ? "Refreshing…" : "Refresh", checked: list.isEmpty ? nil : false) {
                store.refresh(platform, projectPath: projectPath)
            } icon: { Image(systemName: "arrow.clockwise") }
        }
    }

    private struct Group { let title: String; let devices: [RunDevice] }

    private func groups(_ list: [RunDevice]) -> [Group] {
        switch platform {
        case .android:
            return [Group(title: "Connected", devices: list.filter { $0.serial != nil }),
                    Group(title: "Emulators", devices: list.filter { $0.serial == nil })].filter { !$0.devices.isEmpty }
        case .ios:
            var out = [Group(title: "Booted", devices: list.filter(\.isRunning))]
            var runtimes: [String] = []
            for d in list where !d.isRunning { if let r = d.detail, !runtimes.contains(r) { runtimes.append(r) } }
            out += runtimes.map { r in Group(title: r, devices: list.filter { !$0.isRunning && $0.detail == r }) }
            return out.filter { !$0.devices.isEmpty }
        }
    }

    private func trailing(_ device: RunDevice) -> String? {
        if device.problem != nil { return nil }
        switch device.kind {
        case .physical: return device.serial
        case .emulator: return device.isRunning ? "running" : "boots"
        case .simulator: return device.isRunning ? device.detail : nil
        }
    }
}

/// The platforms the selected configuration needs a device for — one capsule each.
extension TabStore {
    func devicePlatforms(for tab: Tab) -> [RunDevicePlatform] {
        guard let ctx = runContext(for: tab), let file = ctx.file,
              let config = runs.selectedConfiguration(projectPath: ctx.projectPath, in: file) else { return [] }
        var out: [RunDevicePlatform] = []
        for member in file.members(of: config) { if let p = member.device, !out.contains(p) { out.append(p) } }
        return out
    }
}
