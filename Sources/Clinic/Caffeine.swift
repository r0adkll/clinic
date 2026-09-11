import AppKit
import SwiftUI
import Observation
import ClinicCore

/// Keeps the Mac awake (ADR-075, ADR-119): always while on, or only while an agent works.
///
/// Both switches persist. ADR-075 turned caffeine off on every launch, and a relaunch — an update,
/// a crash, a rebuild — dropped the assertion without a word while nothing on screen had asked for
/// it; `pmset -g log` showed it as `ClientDied` and the user as caffeine "not always working".
@MainActor
@Observable
final class CaffeineController {
    static let enabledKey = "ClinicCaffeine"
    static let whileWorkingKey = "ClinicCaffeineWhileWorking"

    var isOn = UserDefaults.standard.bool(forKey: enabledKey) {
        didSet { persist(isOn, Self.enabledKey); apply() }
    }
    /// Hold the assertion only while `workingCount > 0` rather than for as long as caffeine is on.
    var onlyWhileWorking = UserDefaults.standard.bool(forKey: whileWorkingKey) {
        didSet { persist(onlyWhileWorking, Self.whileWorkingKey); apply() }
    }
    /// Tabs mid-turn plus detached agents mid-task, from the provider given to `start`.
    private(set) var workingCount = 0
    /// True while the sleep assertion is held: what the toolbar's steaming cup shows.
    private(set) var isHolding = false
    @ObservationIgnored private var activity: NSObjectProtocol?
    @ObservationIgnored private var heldReason: String?
    @ObservationIgnored private var countWorking: (@MainActor () -> Int)?

    init() { apply() }

    enum Mode: CaseIterable {
        case alwaysOn, agentBased

        var title: String {
            switch self {
            case .alwaysOn: "Always On"
            case .agentBased: "Agent Based"
            }
        }
    }

    /// What every menu shows: one checked mode while on, none while off. Choosing a mode turns caffeine
    /// on in it; turning off keeps the mode, so a click on the cup brings back the last one.
    var mode: Mode? {
        get { isOn ? (onlyWhileWorking ? .agentBased : .alwaysOn) : nil }
        set {
            if let newValue { onlyWhileWorking = newValue == .agentBased }
            isOn = newValue != nil
        }
    }

    /// `count` must read only observable state; it is re-run whenever that state changes.
    func start(countingWorking count: @escaping @MainActor () -> Int) {
        countWorking = count
        observe()
    }

    private func observe() {
        guard let countWorking else { return }
        let n = withObservationTracking { countWorking() } onChange: {
            Task { @MainActor [weak self] in self?.observe() }
        }
        guard n != workingCount else { return }
        workingCount = n
        apply()
    }

    private func apply() {
        let reason: String? = !isOn ? nil
            : !onlyWhileWorking ? "Clinic caffeine mode"
            : workingCount > 0 ? "Clinic caffeine mode: an agent is working" : nil
        guard reason != heldReason else { return }
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = reason.map { ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled], reason: $0) }
        heldReason = reason
        if isHolding != (reason != nil) { isHolding = reason != nil }
    }

    /// A smoke instance shares `UserDefaults` with the live app, so what it toggles stays its own.
    private func persist(_ value: Bool, _ key: String) {
        guard !ClinicPaths.isSmokeInstance else { return }
        UserDefaults.standard.set(value, forKey: key)
    }

    // MARK: - Indicator

    /// Outline when off or waiting for an agent, a full cup when always on, steam while an agent keeps it on.
    var symbol: String {
        guard isOn else { return "cup.and.saucer" }
        guard onlyWhileWorking else { return "cup.and.saucer.fill" }
        return isHolding ? "cup.and.heat.waves.fill" : "cup.and.saucer"
    }

    var help: String {
        switch mode {
        case nil: "Caffeine: keep the Mac awake. Click for \(lastMode.title); the menu picks Always On or Agent Based"
        case .alwaysOn: "Caffeine is Always On: the Mac will not sleep"
        case .agentBased: isHolding ? "Caffeine is keeping the Mac awake: \(workingPhrase)"
                                    : "Caffeine is Agent Based: it keeps the Mac awake while an agent works"
        }
    }

    /// What caffeine is doing right now: the header over the modes in every menu.
    var statusLine: String {
        switch mode {
        case nil: "Caffeine is off"
        case .alwaysOn: "Caffeine is keeping the Mac awake"
        case .agentBased: isHolding ? "Caffeine is keeping the Mac awake: \(workingPhrase)" : "Caffeine is waiting for an agent to work"
        }
    }

    /// Turns caffeine off, or back on in the last mode: the cup's click and the rebindable shortcut.
    func toggle() { isOn.toggle() }
    var toggleTitle: String { isOn ? "Turn Caffeine Off" : "Turn Caffeine On (\(lastMode.title))" }

    /// The mode a click on the cup turns on.
    private var lastMode: Mode { onlyWhileWorking ? .agentBased : .alwaysOn }

    private var workingPhrase: String { workingCount == 1 ? "1 agent working" : "\(workingCount) agents working" }
}

/// The two modes under the status line, shared by the toolbar menu and the View menu.
///
/// `mode` and `status` are read in the caller's body, so the caller re-renders when they change. That
/// is enough for the View menu; the toolbar also needs `CaffeineToolbarMenu`'s `.id`.
struct CaffeineModeItems: View {
    let caffeine: CaffeineController
    let mode: CaffeineController.Mode?
    let status: String

    init(caffeine: CaffeineController) {
        self.caffeine = caffeine
        mode = caffeine.mode
        status = caffeine.statusLine
    }

    var body: some View {
        Section(status) {
            ForEach(CaffeineController.Mode.allCases, id: \.self) { m in
                Toggle(m.title, isOn: Binding(get: { mode == m }, set: { caffeine.mode = $0 ? m : nil }))
            }
        }
    }
}

/// The toolbar's cup (ADR-119): a click toggles caffeine, the menu picks its mode.
struct CaffeineToolbarMenu: View {
    let caffeine: CaffeineController
    let hint: String

    var body: some View {
        Menu {
            CaffeineModeItems(caffeine: caffeine)
        } label: {
            Image(nsImage: Self.glyph(caffeine.symbol, accent: caffeine.isOn))
                .renderingMode(caffeine.isOn ? .original : .template)
                .accessibilityLabel("Caffeine")
        } primaryAction: {
            caffeine.toggle()
        }
        .menuIndicator(.visible)
        .help(caffeine.help + hint)
        // The toolbar builds this menu once per item and never refreshes it — new inputs included —
        // so a mode chosen from it was not checked the next time it opened. A new identity whenever
        // the header would change makes a new item, and with it a current menu.
        .id(caffeine.statusLine)
    }

    /// A toolbar menu draws its label as a template, dropping `foregroundStyle`; only an image that
    /// is not a template keeps the accent, as the Open In menu's app icon does. Every state is drawn
    /// on one canvas because the steaming cup is 4 pt narrower than the plain one, and the toolbar
    /// would otherwise shift each time an agent starts or stops.
    private static func glyph(_ symbol: String, accent: Bool) -> NSImage {
        var config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        if accent { config = config.applying(NSImage.SymbolConfiguration(paletteColors: [.controlAccentColor])) }
        guard let symbolImage = NSImage(systemSymbolName: symbol, accessibilityDescription: "Caffeine")?.withSymbolConfiguration(config)
        else { return NSImage() }
        let image = NSImage(size: NSSize(width: 24, height: 18), flipped: false) { rect in
            let s = symbolImage.size
            symbolImage.draw(in: NSRect(x: (rect.width - s.width) / 2, y: (rect.height - s.height) / 2, width: s.width, height: s.height))
            return true
        }
        image.isTemplate = !accent
        return image
    }
}
