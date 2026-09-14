import SwiftUI
import AppKit
import os

/// Clinic's own appearance and accent, overriding the Mac's for this app alone (ADR-152).
///
/// Both default to *System*, which is what every window did before this existed. The theme is the
/// app's `NSAppearance`, so every window, sheet and AppKit control follows at once. The accent is two
/// mechanisms, because macOS offers no single one: SwiftUI's colour is ``SwiftUI/Color/accent`` plus
/// the root modifier ``clinicAppearance()``; AppKit-drawn controls read `controlAccentColor`, which
/// is the app's own `AppleAccentColor` default once AppKit is told to look again (`applyAccentDefault`).
@MainActor @Observable
final class Appearance {
    static let shared = Appearance()
    private static let log = Logger(subsystem: "com.r0adkll.clinic", category: "appearance")

    enum Theme: String, CaseIterable, Identifiable {
        case system, light, dark
        var id: String { rawValue }

        var title: String {
            switch self {
            case .system: "System"
            case .light: "Light"
            case .dark: "Dark"
            }
        }

        /// nil hands the choice back to the system.
        var nsAppearance: NSAppearance? {
            switch self {
            case .system: nil
            case .light: NSAppearance(named: .aqua)
            case .dark: NSAppearance(named: .darkAqua)
            }
        }
    }

    /// The eight accents System Settings offers, in its order.
    enum NamedAccent: String, CaseIterable, Identifiable {
        case blue, purple, pink, red, orange, yellow, green, graphite
        var id: String { rawValue }

        var title: String { rawValue.capitalized }

        var nsColor: NSColor {
            switch self {
            case .blue: .systemBlue
            case .purple: .systemPurple
            case .pink: .systemPink
            case .red: .systemRed
            case .orange: .systemOrange
            case .yellow: .systemYellow
            case .green: .systemGreen
            case .graphite: .systemGray
            }
        }

        /// The value AppKit reads from `AppleAccentColor`, which is how System Settings stores the
        /// same choice globally. Graphite is the odd one out at −1.
        var appleAccentColor: Int {
            switch self {
            case .graphite: -1
            case .red: 0
            case .orange: 1
            case .yellow: 2
            case .green: 3
            case .blue: 4
            case .purple: 5
            case .pink: 6
            }
        }
    }

    enum Accent: Hashable {
        case system
        case named(NamedAccent)
        /// `#RRGGBB`, upper case.
        case custom(hex: String)

        /// One string for UserDefaults: `system`, a named accent's name, or a hex colour.
        var rawValue: String {
            switch self {
            case .system: "system"
            case .named(let n): n.rawValue
            case .custom(let hex): hex
            }
        }

        init(rawValue: String) {
            if let named = NamedAccent(rawValue: rawValue) { self = .named(named) }
            else if let hex = Accent.normalizedHex(rawValue) { self = .custom(hex: hex) }
            else { self = .system }
        }

        init(custom color: NSColor) {
            self = .custom(hex: Accent.hex(of: color))
        }

        /// nil for `.system`: SwiftUI's own `Color.accentColor` is then left alone.
        var color: Color? { nsColor.map(Color.init(nsColor:)) }

        var nsColor: NSColor? {
            switch self {
            case .system: nil
            case .named(let n): n.nsColor
            case .custom(let hex): NSColor(hex: hex)
            }
        }

        /// The named accent AppKit is told about (see ``Appearance``). A custom colour maps to the
        /// nearest of the eight, so a switch or a selection fill is at least in the same family as
        /// the colour the rest of the window wears.
        var nearestNamed: NamedAccent? {
            switch self {
            case .system: return nil
            case .named(let n): return n
            case .custom(let hex):
                guard let c = NSColor(hex: hex).usingColorSpace(.sRGB) else { return nil }
                if c.saturationComponent < 0.2 { return .graphite }
                return NamedAccent.allCases.filter { $0 != .graphite }.min { a, b in
                    Accent.hueDistance(c, a.nsColor) < Accent.hueDistance(c, b.nsColor)
                }
            }
        }

        static func normalizedHex(_ raw: String) -> String? {
            var s = raw.trimmingCharacters(in: .whitespaces).uppercased()
            if s.hasPrefix("#") { s.removeFirst() }
            guard s.count == 6, s.allSatisfy(\.isHexDigit) else { return nil }
            return "#" + s
        }

        static func hex(of color: NSColor) -> String {
            let c = color.usingColorSpace(.sRGB) ?? color
            return String(format: "#%02X%02X%02X",
                          Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))
        }

        private static func hueDistance(_ a: NSColor, _ b: NSColor) -> CGFloat {
            guard let b = b.usingColorSpace(.sRGB) else { return .infinity }
            let d = abs(a.hueComponent - b.hueComponent)
            return min(d, 1 - d)
        }
    }

    var theme: Theme {
        didSet {
            guard theme != oldValue else { return }
            UserDefaults.standard.set(theme.rawValue, forKey: Prefs.theme)
            applyTheme()
        }
    }

    var accent: Accent {
        didSet {
            guard accent != oldValue else { return }
            UserDefaults.standard.set(accent.rawValue, forKey: Prefs.accent)
            applyAccentDefault()
        }
    }

    /// The colour SwiftUI roots are tinted with; nil leaves the system's in place.
    var accentColor: Color? { accent.color }

    /// For AppKit drawing: the chosen accent, or the Mac's when following the system.
    var nsAccentColor: NSColor { accent.nsColor ?? systemAccentColor }

    /// The accent System Settings has, read from the global domain rather than `controlAccentColor`:
    /// once this app has written its own `AppleAccentColor`, `controlAccentColor` answers with that.
    /// Multicolour, which stores nothing, is blue.
    var systemAccentColor: NSColor {
        let global = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)
        guard let raw = global?["AppleAccentColor"] as? Int else { return NamedAccent.blue.nsColor }
        return NamedAccent.allCases.first { $0.appleAccentColor == raw }?.nsColor ?? NamedAccent.blue.nsColor
    }

    private var appearanceObservation: NSKeyValueObservation?

    private init() {
        let defaults = UserDefaults.standard
        theme = defaults.string(forKey: Prefs.theme).flatMap(Theme.init(rawValue:)) ?? .system
        accent = Accent(rawValue: defaults.string(forKey: Prefs.accent) ?? "system")
    }

    /// Applies the saved theme and keeps `onEffectiveAppearanceChange` told, for the terminal.
    func start(onEffectiveAppearanceChange: @escaping @MainActor (_ dark: Bool) -> Void) {
        applyTheme()
        applyAccentDefault()
        // KVO fires on the thread that changed the value, and the app's appearance only changes on
        // the main one — from `applyTheme` here or from AppKit answering System Settings.
        appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.initial, .new]) { _, _ in
            MainActor.assumeIsolated {
                let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                onEffectiveAppearanceChange(dark)
            }
        }
    }

    private func applyTheme() {
        NSApp.appearance = theme.nsAppearance
    }

    /// AppKit reads `AppleAccentColor` from the app's own domain before the global one, which is the
    /// only way a per-app accent reaches `controlAccentColor` — and so switches, checkboxes and list
    /// selection fills. It reads it at launch and again on `AppleAquaColorVariantChanged`, the
    /// distributed notification System Settings sends when the Mac's accent changes; posting it here
    /// is what makes those controls follow without a relaunch. Neither of the other two notifications
    /// System Settings sends alongside it (`AppleColorPreferencesChangedNotification`,
    /// `AppleInterfaceThemeChangedNotification`) has that effect. Every app hears it and re-reads an
    /// accent that, for them, has not changed.
    private func applyAccentDefault() {
        let defaults = UserDefaults.standard
        if let named = accent.nearestNamed {
            defaults.set(named.appleAccentColor, forKey: "AppleAccentColor")
        } else {
            defaults.removeObject(forKey: "AppleAccentColor")
        }
        defaults.synchronize()
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("AppleAquaColorVariantChanged"), object: nil, userInfo: nil, deliverImmediately: true)
    }
}

extension Color {
    /// Clinic's accent (ADR-152): what the app draws with wherever it used to draw with `accentColor`.
    /// Reading it in a view body tracks `Appearance.shared`, so a change redraws the view. It falls
    /// back to `accentColor` when following the system, which is then the Mac's own.
    @MainActor static var accent: Color { Appearance.shared.accentColor ?? .accentColor }
}

/// Tints a SwiftUI root with Clinic's accent (ADR-152). Goes on every hosting root — the scenes and each
/// `NSHostingView` — because the environment does not cross from one root to another.
///
/// `.tint` is what a control reads for its own colour (a segmented picker's selection, a prominent
/// button). `Color.accentColor` does *not* follow it, nor the deprecated `.accentColor(_:)` in a real
/// window — checked on macOS 26 — which is why Clinic's views read ``SwiftUI/Color/accent`` instead.
private struct ClinicAppearanceRoot<Content: View>: View {
    let content: Content
    private var appearance: Appearance { Appearance.shared }

    var body: some View {
        content.tint(appearance.accentColor)
    }
}

extension View {
    /// Clinic's accent for this SwiftUI root and everything under it.
    func clinicAppearance() -> some View {
        ClinicAppearanceRoot(content: self)
    }
}
