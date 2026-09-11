import AppKit
import SwiftUI
import ClinicCore

/// Every SF Symbol this Mac has, for the run configuration icon picker (ADR-125).
///
/// The names come from the system's own catalogue (`CoreGlyphs.bundle`), which is data rather than
/// API: there is no way to enumerate symbols through AppKit, and a run configuration's icon can be
/// any name — Claude writes `run.json`, and it reaches for symbols no curated list would hold. If a
/// future macOS moves the catalogue, the built-in set below stands in and typing a name still works.
@MainActor
enum SFSymbolCatalog {
    /// The system's catalogue, or just the suggested names when a future macOS has moved it — typing
    /// a name still works either way.
    private static let catalogue = SymbolCatalog.system() ?? SymbolCatalog.make(symbols: SymbolCatalog.suggested)
    private static var validity: [String: Bool] = [:]

    static var names: [String] { catalogue.names }
    static let categories = SymbolCatalog.categories()
    static let suggested = SymbolCatalog.suggested

    static func symbols(matching query: String, in category: String?) -> [String] {
        catalogue.symbols(matching: query, in: category)
    }

    /// The ways the same subject can be drawn — filled or not, plain, in a circle or a square. Empty
    /// when there is only one way.
    static func variants(of name: String) -> [SymbolCatalog.SymbolVariant] { catalogue.variants(of: name) }

    /// One entry per subject, rather than one per drawing.
    static func families(matching query: String, in category: String?) -> [String] {
        catalogue.families(matching: query, in: category)
    }

    static func family(of name: String) -> String { catalogue.family(of: name) }
    static func name(_ family: String, style: SymbolCatalog.SymbolStyle) -> String? { catalogue.name(family, style: style) }
    static func style(of name: String) -> SymbolCatalog.SymbolStyle { catalogue.style(of: name) }

    /// Whether this Mac can draw the name: the AppKit half, and the answer for a name a person or an
    /// agent typed, which may be from a newer macOS or no symbol at all.
    static func exists(_ name: String) -> Bool {
        if let known = validity[name] { return known }
        let ok = !name.isEmpty && NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
        validity[name] = ok
        return ok
    }

    /// The name, or the fallback when this Mac has never heard of it.
    static func resolved(_ name: String, fallback: String = "play.fill") -> String {
        exists(name) ? name : fallback
    }
}

/// Filled or outlined, plain or enclosed: a toggle when those are the only two ways to draw the
/// symbol, a menu when there are more, and nothing when there is only one (ADR-125).
struct SymbolVariantControl: View {
    @Binding var symbol: String

    var body: some View {
        let variants = SFSymbolCatalog.variants(of: symbol)
        if variants.count == 2, let plain = variants.first, let filled = variants.last, !plain.isFilled, filled.isFilled {
            Toggle("Filled", isOn: Binding(get: { symbol == filled.name },
                                           set: { symbol = $0 ? filled.name : plain.name }))
                .toggleStyle(.checkbox)
                .controlSize(.small)
        } else if variants.count > 2 {
            Picker("Style", selection: Binding(get: { symbol }, set: { symbol = $0 })) {
                ForEach(variants) { variant in
                    Label(variant.label, systemImage: variant.name).tag(variant.name)
                }
            }
            .labelsHidden()
            .fixedSize()
            .controlSize(.small)
            .help("How this symbol is drawn")
        }
    }
}

/// Browse or type any symbol on this Mac (ADR-125).
///
/// The grid shows one entry per subject, not one per drawing: `hammer` stands for `hammer.fill`,
/// `hammer.circle` and `hammer.circle.fill` too. The style below decides how they are all drawn, and
/// which drawing *Choose* returns.
struct SymbolBrowser: View {
    @Environment(\.dismiss) private var dismiss
    let initial: String
    let onChoose: (String) -> Void

    @State private var query = ""
    @State private var category: String?
    @State private var family: String
    @State private var style: SymbolCatalog.SymbolStyle
    @State private var typed: String
    @FocusState private var searching: Bool

    init(initial: String, onChoose: @escaping (String) -> Void) {
        self.initial = initial
        self.onChoose = onChoose
        _family = State(initialValue: SFSymbolCatalog.family(of: initial))
        _style = State(initialValue: SFSymbolCatalog.style(of: initial))
        _typed = State(initialValue: initial)
    }

    private var results: [String] { SFSymbolCatalog.families(matching: query, in: category) }

    /// What *Choose* returns: the chosen subject in the chosen style, or its plain form when this Mac
    /// does not draw that subject that way.
    private var chosen: String {
        SFSymbolCatalog.name(family, style: style) ?? SFSymbolCatalog.name(family, style: .plain) ?? typed
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if results.isEmpty {
                ContentUnavailableView("No symbols match", systemImage: "magnifyingglass",
                                       description: Text("Try another word, or type an exact symbol name below."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 44), spacing: 6)], spacing: 6) {
                        ForEach(results, id: \.self) { subject in cell(subject) }
                    }
                    .padding(12)
                }
            }
            Divider()
            footer
        }
        .frame(minWidth: 820, idealWidth: 880, maxWidth: .infinity, minHeight: 560, idealHeight: 660, maxHeight: .infinity)
        .onAppear { searching = true }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search \(SFSymbolCatalog.names.count) symbols", text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($searching)
                .onSubmit { choose() }
            Picker("", selection: $category) {
                Text("All Categories").tag(String?.none)
                ForEach(SFSymbolCatalog.categories) { c in
                    Label(c.label, systemImage: c.symbol).tag(String?.some(c.key))
                }
            }
            .labelsHidden()
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
    }

    /// One subject, drawn in the style on show; a subject this Mac does not draw that way keeps its
    /// plain form rather than leaving a hole in the grid.
    private func cell(_ subject: String) -> some View {
        let name = SFSymbolCatalog.name(subject, style: style) ?? subject
        let on = subject == family
        return Button {
            family = subject
            typed = name
        } label: {
            Image(systemName: SFSymbolCatalog.resolved(name))
                .font(.system(size: 17))
                .frame(width: 44, height: 40)
                .foregroundStyle(on ? Color.accentColor : Color.primary)
                .background(on ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(on ? Color.accentColor.opacity(0.5) : .clear))
        }
        .buttonStyle(.plain)
        .help(name)
        // A double click is the shortcut a grid of choices invites.
        .simultaneousGesture(TapGesture(count: 2).onEnded { family = subject; typed = name; choose() })
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Image(systemName: SFSymbolCatalog.resolved(chosen))
                .font(.system(size: 17))
                .foregroundStyle(Color.accentColor)
                .frame(width: 34, height: 34)
                .background(Color.accentColor.opacity(0.16), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                TextField("Symbol name", text: $typed)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minWidth: 160, idealWidth: 220)
                    .onSubmit { adoptTyped() }
                    .onChange(of: typed) { adoptTyped() }
                if !typed.isEmpty, !SFSymbolCatalog.exists(typed) {
                    Text("This Mac has no symbol by that name.").font(.caption).foregroundStyle(.orange)
                }
            }
            Picker("Style", selection: $style) {
                ForEach(SymbolCatalog.SymbolStyle.allCases) { option in
                    Label(option.label, systemImage: SFSymbolCatalog.resolved(SFSymbolCatalog.name(family, style: option) ?? "questionmark"))
                        .tag(option)
                }
            }
            .labelsHidden()
            .fixedSize()
            .help("How the symbols are drawn")
            Spacer(minLength: 8)
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).controlSize(.large)
            Button("Choose") { choose() }
                .keyboardShortcut(.defaultAction).controlSize(.large)
                .disabled(!SFSymbolCatalog.exists(chosen))
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    /// A name typed by hand picks its own subject and style, so the grid and the style follow it.
    private func adoptTyped() {
        guard SFSymbolCatalog.exists(typed) else { return }
        family = SFSymbolCatalog.family(of: typed)
        style = SFSymbolCatalog.style(of: typed)
    }

    private func choose() {
        let name = chosen
        guard SFSymbolCatalog.exists(name) else { return }
        onChoose(name)
        dismiss()
    }
}

extension RunConfiguration {
    /// The icon to draw: this configuration's, or the play glyph when this Mac has no symbol by that
    /// name — an agent writing `run.json` can reach for one that does not exist (ADR-125).
    @MainActor var uiSymbol: String { SFSymbolCatalog.resolved(symbol) }
}
