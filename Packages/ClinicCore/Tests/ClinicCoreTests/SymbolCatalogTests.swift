import Foundation
import Testing
@testable import ClinicCore

@Suite struct SymbolCatalogTests {
    private let sample = SymbolCatalog.make(
        symbols: ["hammer", "hammer.fill", "applelogo", "0.circle", "0.circle.ar", "iphone.gen3.rtl", "ladybug", "globe"],
        restricted: ["applelogo"],
        categories: ["hammer": ["objectsandtools"], "hammer.fill": ["objectsandtools"], "ladybug": ["objectsandtools"],
                     "globe": ["connectivity"], "0.circle": ["indices"]],
        terms: ["ladybug": ["Bug", "Debug"], "globe": ["Internet"]],
        order: ["globe", "hammer", "hammer.fill", "ladybug"])

    @Test func keepsUsableNamesInTheSystemsOrder() {
        // Apple's marks are dropped, localized and RTL variants too, and anything unordered sorts last.
        #expect(sample.names == ["globe", "hammer", "hammer.fill", "ladybug", "0.circle"])
    }

    @Test func searchesNamesAndTheSystemsTerms() {
        #expect(sample.symbols(matching: "hammer") == ["hammer", "hammer.fill"])
        #expect(sample.symbols(matching: "debug") == ["ladybug"])          // a search term, not the name
        #expect(sample.symbols(matching: "INTERNET") == ["globe"])         // case-insensitive
        #expect(sample.symbols(matching: "  ") == sample.names)            // blank is everything
        #expect(sample.symbols(matching: "nothing at all").isEmpty)
    }

    @Test func filtersByCategory() {
        #expect(sample.symbols(matching: "", in: "objectsandtools") == ["hammer", "hammer.fill", "ladybug"])
        #expect(sample.symbols(matching: "ham", in: "connectivity").isEmpty)
        #expect(sample.symbols(matching: "", in: "nosuchcategory").isEmpty)
    }

    /// Variants are the same subject drawn differently, and only the ones this Mac has.
    @Test func offersTheVariantsThatExist() {
        let catalogue = SymbolCatalog.make(
            symbols: ["hammer", "hammer.fill", "hammer.circle", "hammer.circle.fill", "globe", "globe.fill",
                      "testtube.2", "wifi.slash", "wifi.slash.fill", "video.badge.checkmark", "video.fill.badge.checkmark"],
            fills: ["hammer": "hammer.fill", "hammer.circle": "hammer.circle.fill", "globe": "globe.fill",
                    "wifi.slash": "wifi.slash.fill", "video.badge.checkmark": "video.fill.badge.checkmark"])
        #expect(catalogue.variants(of: "hammer").map(\.name) == ["hammer", "hammer.fill", "hammer.circle", "hammer.circle.fill"])
        #expect(catalogue.variants(of: "hammer").map(\.label) == ["Plain", "Filled", "Circle", "Circle Filled"])
        // Asking from inside the family gives the same list, whichever member you hold.
        #expect(catalogue.variants(of: "hammer.circle.fill").map(\.name) == catalogue.variants(of: "hammer").map(\.name))
        // Two ways: the toggle case.
        #expect(catalogue.variants(of: "globe").map(\.name) == ["globe", "globe.fill"])
        // One way is no choice at all.
        #expect(catalogue.variants(of: "testtube.2").isEmpty)
        // `.slash` belongs to the subject: it must not offer plain `wifi`.
        #expect(catalogue.variants(of: "wifi.slash").map(\.name) == ["wifi.slash", "wifi.slash.fill"])
        // The system's irregular fills, where ".fill" lands in the middle.
        #expect(catalogue.variants(of: "video.badge.checkmark").map(\.name) == ["video.badge.checkmark", "video.fill.badge.checkmark"])
    }

    /// The grid lists subjects, not drawings: one `hammer`, not four.
    @Test func collapsesFamiliesAndNamesTheirStyles() {
        let catalogue = SymbolCatalog.make(
            symbols: ["hammer", "hammer.fill", "hammer.circle", "hammer.circle.fill", "globe", "globe.fill", "testtube.2"],
            order: ["hammer", "hammer.fill", "hammer.circle", "hammer.circle.fill", "globe", "globe.fill", "testtube.2"],
            fills: ["hammer": "hammer.fill", "hammer.circle": "hammer.circle.fill", "globe": "globe.fill"])
        #expect(catalogue.families(matching: "") == ["hammer", "globe", "testtube.2"])
        #expect(catalogue.family(of: "hammer.circle.fill") == "hammer")
        #expect(catalogue.name("hammer", style: .circleFilled) == "hammer.circle.fill")
        #expect(catalogue.name("globe", style: .circle) == nil)          // this Mac has no globe.circle
        #expect(catalogue.style(of: "hammer.circle.fill") == .circleFilled)
        #expect(catalogue.style(of: "hammer.fill") == .filled)
        #expect(catalogue.style(of: "testtube.2") == .plain)
        // A subject whose own name ends in an enclosure is its own family, not an enclosed something.
        let shapes = SymbolCatalog.make(symbols: ["circle", "circle.fill"], fills: ["circle": "circle.fill"])
        #expect(shapes.family(of: "circle.fill") == "circle")
        #expect(shapes.families(matching: "") == ["circle"])
        // `.square` is only an enclosure when what is left is itself a symbol; otherwise stripping it
        // invents a name nothing draws, and the grid fell back to the play glyph for it.
        let onSquare = SymbolCatalog.make(symbols: ["square.and.arrow.up.on.square", "square.and.arrow.up.on.square.fill"],
                                          fills: ["square.and.arrow.up.on.square": "square.and.arrow.up.on.square.fill"])
        #expect(onSquare.family(of: "square.and.arrow.up.on.square.fill") == "square.and.arrow.up.on.square")
        #expect(onSquare.style(of: "square.and.arrow.up.on.square") == .plain)
        #expect(onSquare.name("square.and.arrow.up.on.square", style: .filled) == "square.and.arrow.up.on.square.fill")
    }

    @Test func labelsCategoriesReadably() {
        #expect(SymbolCatalog.label(for: "objectsandtools") == "Objects & Tools")
        #expect(SymbolCatalog.label(for: "devices") == "Devices")
    }

    /// The real catalogue, when this Mac still keeps it where it always has.
    @Test(.enabled(if: FileManager.default.fileExists(atPath: SymbolCatalog.systemResources + "/name_availability.plist")))
    func readsTheSystemCatalogue() throws {
        let catalogue = try #require(SymbolCatalog.system())
        #expect(catalogue.names.count > 3000)
        #expect(catalogue.names.contains("hammer"))
        #expect(!catalogue.names.contains { $0.hasSuffix(".rtl") })
        #expect(catalogue.symbols(matching: "hammer").contains("hammer"))
        // The SF Symbols app's own order starts with sharing, not with digits.
        #expect(catalogue.names.first == "square.and.arrow.up")
        // The real families: play has six ways to be drawn, a plain screen only one.
        #expect(catalogue.variants(of: "play.fill").map(\.name)
                == ["play", "play.fill", "play.circle", "play.circle.fill", "play.square", "play.square.fill"])
        #expect(catalogue.variants(of: "desktopcomputer").isEmpty)
        // Collapsing drops a couple of thousand entries, and a family shows once: hammer's four
        // drawings (plain, filled, circle, circle filled) are one subject.
        #expect(catalogue.families(matching: "").count < catalogue.names.count)
        #expect(catalogue.symbols(matching: "hammer").count > 3)
        #expect(catalogue.families(matching: "hammer") == ["hammer"])
        // Every family is a symbol in its own right, so no cell in the grid falls back to the play glyph.
        #expect(catalogue.families(matching: "").allSatisfy { catalogue.names.contains($0) })
        let categories = SymbolCatalog.categories()
        #expect(categories.contains { $0.key == "devices" })
        #expect(!categories.contains { SymbolCatalog.traitCategories.contains($0.key) })
    }
}
