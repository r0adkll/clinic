import AppKit
import SwiftUI
import Observation
import ClinicCore

/// Keeps the Mac awake (ADR-075, ADR-119, ADR-150): always while on, or only while an agent works.
///
/// Only idle *system* sleep is inhibited. The display sleeps on its own timer in every mode, which is
/// the behaviour the user reviewed and kept on 2026-09-14; the popover's note says so.
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
    /// True while the sleep assertion is held: the cup the toolbar fills in.
    private(set) var isHolding = false
    @ObservationIgnored private var activity: NSObjectProtocol?
    @ObservationIgnored private var heldReason: String?
    @ObservationIgnored private var countWorking: (@MainActor () -> Int)?

    init() { apply() }

    enum Mode: CaseIterable {
        case alwaysOn, agentBased

        /// Both names finish "keep the Mac awake…", so the two rows read as two answers to one
        /// question. *Agent Based* named a mechanism and did not pair with *Always On* (ADR-150).
        var title: String {
            switch self {
            case .alwaysOn: "Always"
            case .agentBased: "While Agents Work"
            }
        }

        /// The same title inside a sentence.
        var phrase: String {
            switch self {
            case .alwaysOn: "always"
            case .agentBased: "while agents work"
            }
        }

        /// The mode's shape, for the row that chooses it: the cup the toolbar shows in that mode.
        /// Filled, because a row names the mode rather than reporting whether it is holding.
        var symbol: String {
            switch self {
            case .alwaysOn: "cup.and.saucer.fill"
            case .agentBased: "cup.and.heat.waves.fill"
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

    /// Three channels, each answering one question (ADR-150).
    ///
    /// **Shape is the mode**, including while caffeine is off: `onlyWhileWorking` persists, so the cup
    /// keeps the shape of the mode it will come back on in. Turning caffeine off therefore never swaps
    /// one cup for another — only its colour changes — which is what made the old glyph feel like it
    /// was jumping between unrelated icons.
    ///
    /// **Colour is on or off**: accent when caffeine is on, template grey when it is not.
    ///
    /// **Fill and motion are right now**: an agent is working, so the assertion is held
    /// (`isPulsing` beats), against a hollow cup while the mode is armed and nothing is working.
    var symbol: String {
        guard onlyWhileWorking else { return isOn ? "cup.and.saucer.fill" : "cup.and.saucer" }
        return isOn && isHolding ? "cup.and.heat.waves.fill" : "cup.and.heat.waves"
    }

    /// The toolbar beats the cup while an agent is keeping the Mac awake. Only *While Agents Work* has
    /// this state: *Always* holds for as long as it is on, and a permanent pulse is just a distraction.
    var isPulsing: Bool { isOn && onlyWhileWorking && isHolding }

    var help: String {
        switch mode {
        case nil: "Caffeine keeps the Mac awake. Click to turn it on \(lastMode.phrase); the chevron picks the mode"
        case .alwaysOn: "Caffeine is on always: the Mac will not sleep on its idle timer. The display still sleeps"
        case .agentBased: isHolding ? "Caffeine is keeping the Mac awake: \(workingPhrase)"
                                    : "Caffeine keeps the Mac awake while an agent works. None is, so the Mac can sleep now"
        }
    }

    /// What caffeine is doing right now: the header over the modes in every menu.
    var statusLine: String {
        switch mode {
        case nil: "Caffeine is off"
        case .alwaysOn: "Caffeine is keeping the Mac awake"
        // Waiting names its consequence, not its mode: what you want while looking at a lit cup and a
        // Mac that just slept (ADR-150). Short enough for one line at the popover's width, because the
        // status item draws the same string in an NSMenu section header, which truncates rather than
        // wraps; what it waits for is the checked row directly beneath it.
        case .agentBased: isHolding ? "Caffeine is keeping the Mac awake: \(workingPhrase)" : "Caffeine is waiting — the Mac can sleep"
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

/// The toolbar's cup (ADR-119, ADR-150): a click toggles caffeine; the chevron's popover picks its
/// mode (ADR-123).
struct CaffeineToolbarMenu: View {
    let caffeine: CaffeineController
    let hint: String
    /// The far end of the pulse. Set while an agent works, it drives a repeating animation; cleared,
    /// the cup settles back at full strength.
    @State private var beating = false

    var body: some View {
        ToolbarSplitButton(help: caffeine.help + hint, choicesHelp: "Choose Always or While Agents Work", smokeId: "caffeine") {
            caffeine.toggle()
        } label: {
            Image(nsImage: Self.glyph(caffeine.symbol, accent: caffeine.isOn))
                .renderingMode(caffeine.isOn ? .original : .template)
                .opacity(beating ? 0.4 : 1)
                .animation(caffeine.isPulsing ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : .default,
                           value: beating)
                // `initial` starts the beat on a window opened while an agent is already working.
                .onChange(of: caffeine.isPulsing, initial: true) { _, pulsing in beating = pulsing }
                .accessibilityLabel("Caffeine")
                .frame(width: 34, height: 28)
        } choices: {
            PopoverMenu(width: 300) {
                PopoverMenuHeader(title: caffeine.statusLine)
                ForEach(CaffeineController.Mode.allCases, id: \.self) { m in
                    // Choosing the checked mode turns caffeine off, as unticking it in a menu did.
                    // Each row wears the cup the toolbar shows in that mode, so the glyph is read
                    // once here and recognised afterwards (ADR-150).
                    PopoverMenuRow(title: m.title, checked: caffeine.mode == m) {
                        caffeine.mode = caffeine.mode == m ? nil : m
                    } icon: { Image(systemName: m.symbol) }
                }
                PopoverMenuDivider()
                PopoverMenuNote(text: "The display sleeps on its own schedule either way.")
            }
        }
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
