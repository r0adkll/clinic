import Foundation
import CodeEditLanguages

/// Picks the language for a file (ADR-081). `CodeEditLanguages` answers first — it knows ~40 grammars
/// by extension — and this only fills the gaps it leaves:
///
/// - it is given the file's first and last lines, so a `#!/usr/bin/env python3` script with no
///   extension, or a file carrying a vim/emacs modeline, is recognised at all;
/// - a small table maps names and extensions it does not know onto grammars it does have. Everything
///   here is a file whose *syntax* really is the language it is mapped to; nothing is mapped for the
///   sake of having some colour (a `.plist` stays plain text, because there is no XML grammar).
@MainActor
enum FileLanguage {
    static func detect(path: String, text: String) -> CodeLanguage {
        let url = URL(fileURLWithPath: path)
        let prefix = String(text.prefix(2048))
        let suffix = text.count > 4096 ? String(text.suffix(2048)) : nil
        let detected = CodeLanguage.detectLanguageFrom(url: url, prefixBuffer: prefix, suffixBuffer: suffix)
        guard detected.id == .plainText else { return detected }
        if let byName = names[url.lastPathComponent] { return byName }
        if let byExtension = extensions[url.pathExtension.lowercased()] { return byExtension }
        return detected
    }

    private static let extensions: [String: CodeLanguage] = [
        // Shells the package does not list; all POSIX-ish enough for the bash grammar.
        "fish": .bash, "zsh": .bash, "ksh": .bash, "command": .bash, "zshrc": .bash, "zshenv": .bash,
        "bashrc": .bash, "bash_profile": .bash, "zprofile": .bash, "profile": .bash, "env": .bash,
        // Ruby by another name.
        "gemspec": .ruby, "podspec": .ruby, "rake": .ruby, "ru": .ruby,
        // JSON dialects and JSON-shaped files.
        "jsonc": .json, "json5": .json, "resolved": .json, "geojson": .json, "ipynb": .json,
        "webmanifest": .json, "arb": .json,
        "swiftinterface": .swift,
        "pyi": .python, "pyw": .python,
        // Close enough to read: the nesting is extra, the rest is CSS.
        "scss": .css, "less": .css,
    ]

    private static let names: [String: CodeLanguage] = [
        "Podfile": .ruby, "Gemfile": .ruby, "Rakefile": .ruby, "Brewfile": .ruby,
        "Fastfile": .ruby, "Appfile": .ruby, "Dangerfile": .ruby,
        "Package.resolved": .json, "Cargo.lock": .toml,
        ".zshrc": .bash, ".zshenv": .bash, ".zprofile": .bash, ".bashrc": .bash,
        ".bash_profile": .bash, ".profile": .bash, ".env": .bash, "config.fish": .bash,
    ]
}
