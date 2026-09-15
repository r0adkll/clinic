import Foundation

/// The model aliases the CLI accepts by name, most capable first (ADR-155).
///
/// Every picker that offers a model — the footer chip, the composer, the automation editor,
/// Settings — reads this list, so a new alias shows up everywhere at once. `--model` and `/model`
/// both resolve an alias to the latest model of that family.
enum ModelAlias {
    static let all = ["fable", "opus", "sonnet", "haiku"]

    /// "fable" → "Fable"; "default" → "Default".
    static func title(_ alias: String) -> String { alias.capitalized }
}
