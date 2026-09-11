import Foundation

/// Built-in detection (ADR-122): configurations read from build files. Files only, and only the ones
/// named here plus one level of Gradle modules, so it's cheap enough to run when the Run menu opens.
/// No build tool is started; Xcode schemes are the one exception, behind `detectXcode`.
public enum RunDetector {
    /// Everything but Xcode, in the order the Run menu lists it: Gradle apps, package scripts, Make
    /// targets, Cargo binaries, SwiftPM executables. Ids are unique across the result.
    public static func detect(in root: URL) -> [RunConfiguration] {
        let fm = FileManager.default
        func read(_ name: String) -> String? { try? String(contentsOf: root.appendingPathComponent(name), encoding: .utf8) }

        var found: [RunConfiguration] = gradle(in: root)
        if let data = try? Data(contentsOf: root.appendingPathComponent("package.json")) {
            found += packageScripts(packageJSON: data, packageManager: packageManager(in: root))
        }
        // `make` reads GNUmakefile, makefile and Makefile in that order, and so does this.
        if let makefile = ["GNUmakefile", "makefile", "Makefile"].lazy.compactMap(read).first {
            found += makeTargets(makefile: makefile)
        }
        found += cargo(in: root)
        if fm.fileExists(atPath: root.appendingPathComponent("Package.swift").path), let manifest = read("Package.swift") {
            found += swiftExecutables(packageSwift: manifest)
        }
        // An install task needs a device to install onto (ADR-124).
        return uniqued(found, avoiding: []).map { c in
            var c = c
            c.device = c.device ?? RunDevicePlatform.inferred(fromCommand: c.command)
            return c
        }
    }

    /// Re-ids `configs` so none collides with `taken` or with each other.
    static func uniqued(_ configs: [RunConfiguration], avoiding taken: Set<String>) -> [RunConfiguration] {
        var taken = taken
        return configs.map { c in
            var c = c
            c.id = RunConfiguration.makeId(from: c.id, avoiding: taken)
            taken.insert(c.id)
            return c
        }
    }

    private static func draft(_ name: String, _ command: String, icon: String, directory: String? = nil) -> RunConfiguration {
        RunConfiguration(id: RunConfiguration.makeId(from: name, avoiding: []), name: name, icon: icon,
                         command: command, directory: directory)
    }

    // MARK: Make

    /// Explicit targets at column 0 (`name:` or `name: deps`), as `make <target>`. Skips special
    /// targets (`.PHONY`), pattern rules, variables (`X := y`, `X ?= y`), target-specific variables and
    /// file-like targets (`out/app.o`).
    public static func makeTargets(makefile: String) -> [RunConfiguration] {
        var targets: [String] = []
        var inDefine = false
        var continued = false
        for raw in makefile.components(separatedBy: .newlines) {
            let line = raw.replacingOccurrences(of: "\r", with: "")
            defer { continued = line.hasSuffix("\\") }
            if continued { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("define ") || trimmed == "define" { inDefine = true; continue }
            if inDefine { if trimmed.hasPrefix("endef") { inDefine = false }; continue }
            guard let first = line.first, !first.isWhitespace, first != "#", first != "." else { continue }
            let head = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? line
            guard let colon = head.firstIndex(of: ":") else { continue }
            let names = head[..<colon]
            let after = head[head.index(after: colon)...].drop { $0 == ":" }
            // `X := y`, `X ::= y`, and `target: VAR = value` all assign; a rule's prerequisites never do.
            if after.hasPrefix("=") || names.contains("=") { continue }
            if (after.split(separator: ";", maxSplits: 1).first ?? "").contains("=") { continue }
            for name in names.split(whereSeparator: \.isWhitespace).map(String.init)
            where name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) && !targets.contains(name) {
                targets.append(name)
            }
        }
        return targets.map { draft($0, "make \($0)", icon: "terminal") }
    }

    // MARK: package.json

    /// The package manager a project's lockfile names; npm when there is none.
    public static func packageManager(in root: URL) -> String {
        let fm = FileManager.default
        return packageManager(lockfiles: Set(["pnpm-lock.yaml", "yarn.lock", "bun.lockb", "bun.lock"].filter {
            fm.fileExists(atPath: root.appendingPathComponent($0).path)
        }))
    }

    public static func packageManager(lockfiles: Set<String>) -> String {
        if lockfiles.contains("pnpm-lock.yaml") { return "pnpm" }
        if lockfiles.contains("yarn.lock") { return "yarn" }
        if lockfiles.contains("bun.lockb") || lockfiles.contains("bun.lock") { return "bun" }
        return "npm"
    }

    /// `scripts`, in the file's order, as `<pm> run <script>`. `pre`/`post` hooks of another script are
    /// left out: the package manager runs them with it.
    public static func packageScripts(packageJSON: Data, packageManager: String) -> [RunConfiguration] {
        guard let object = try? JSONSerialization.jsonObject(with: packageJSON) as? [String: Any],
              let scripts = object["scripts"] as? [String: Any] else { return [] }
        // JSONSerialization loses key order; the text keeps it.
        let text = String(decoding: packageJSON, as: UTF8.self)
        let start = text.range(of: "\"scripts\"")?.upperBound ?? text.startIndex
        func position(_ key: String) -> String.Index {
            text.range(of: "\"\(key)\"", range: start..<text.endIndex)?.lowerBound ?? text.endIndex
        }
        let names = scripts.keys.sorted { (position($0), $0) < (position($1), $1) }
        let hooks = Set(names.flatMap { ["pre" + $0, "post" + $0] })
        return names.filter { !hooks.contains($0) }.map {
            draft($0, "\(packageManager) run \(ClaudeLaunch.shellQuote($0))", icon: "terminal")
        }
    }

    // MARK: Cargo

    struct CargoManifest: Equatable {
        var packageName: String?
        var defaultRun: String?
        var bins: [String] = []
        var binPaths: [String] = []
        var workspaceMembers: [String] = []
    }

    /// Line-based: the handful of keys detection needs, not TOML.
    static func cargoManifest(_ text: String) -> CargoManifest {
        var m = CargoManifest()
        var section = ""
        var collectingMembers: String?
        for raw in text.components(separatedBy: .newlines) {
            let line = RunParsing.stripHashComment(raw).trimmingCharacters(in: .whitespaces)
            if var members = collectingMembers {
                members += " " + line
                if line.contains("]") {
                    m.workspaceMembers = RunParsing.quotedStrings(members); collectingMembers = nil
                } else { collectingMembers = members }
                continue
            }
            if line.hasPrefix("[") {
                section = line.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
                continue
            }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            switch (section, key) {
            case ("package", "name"): m.packageName = RunParsing.quotedStrings(value).first
            case ("package", "default-run"): m.defaultRun = RunParsing.quotedStrings(value).first
            case ("bin", "name"): if let n = RunParsing.quotedStrings(value).first { m.bins.append(n) }
            case ("bin", "path"): if let p = RunParsing.quotedStrings(value).first { m.binPaths.append(RunParsing.normalize(p)) }
            case ("workspace", "members"):
                if value.contains("]") { m.workspaceMembers = RunParsing.quotedStrings(value) } else { collectingMembers = value }
            default: break
            }
        }
        return m
    }

    /// The root package's binaries, then each workspace member's, as `cargo run -p …`. A package with
    /// several binaries and no `default-run` gets one entry per binary, since plain `-p` refuses to guess.
    public static func cargo(in root: URL) -> [RunConfiguration] {
        let fm = FileManager.default
        func manifest(_ dir: URL) -> CargoManifest? {
            (try? String(contentsOf: dir.appendingPathComponent("Cargo.toml"), encoding: .utf8)).map(cargoManifest)
        }
        func binaries(_ m: CargoManifest, in dir: URL) -> [RunConfiguration] {
            guard let pkg = m.packageName else { return [] }
            var bins = m.bins
            // `src/main.rs` is a binary named after the package, unless a `[[bin]]` already claims it.
            if fm.fileExists(atPath: dir.appendingPathComponent("src/main.rs").path), !bins.contains(pkg),
               !m.binPaths.contains("src/main.rs") { bins.append(pkg) }
            let binDir = dir.appendingPathComponent("src/bin")
            for entry in ((try? fm.contentsOfDirectory(atPath: binDir.path)) ?? []).sorted() {
                let name = entry.hasSuffix(".rs") ? String(entry.dropLast(3))
                    : fm.fileExists(atPath: binDir.appendingPathComponent(entry).appendingPathComponent("main.rs").path) ? entry : nil
                if let name, !bins.contains(name) { bins.append(name) }
            }
            let run = "cargo run -p \(ClaudeLaunch.shellQuote(pkg))"
            if bins.count == 1 || (m.defaultRun != nil && !bins.isEmpty) { return [draft(pkg, run, icon: "play.fill")] }
            return bins.map { draft($0, run + " --bin \(ClaudeLaunch.shellQuote($0))", icon: "play.fill") }
        }
        guard let top = manifest(root) else { return [] }
        var out = binaries(top, in: root)
        var memberDirs: [String] = []
        for member in top.workspaceMembers {
            // `crates/*` is the only glob shape worth handling; deeper patterns are left to Claude.
            if member.hasSuffix("/*") || member == "*" {
                let parent = member == "*" ? "." : String(member.dropLast(2))
                let names = ((try? fm.contentsOfDirectory(atPath: root.appendingPathComponent(parent).path)) ?? []).sorted()
                memberDirs += names.filter { !$0.hasPrefix(".") }.map { parent == "." ? $0 : parent + "/" + $0 }
            } else if !member.contains("*") {
                memberDirs.append(member)
            }
        }
        for dir in memberDirs where RunParsing.normalize(dir) != "." {
            let url = root.appendingPathComponent(dir)
            if let m = manifest(url) { out += binaries(m, in: url) }
        }
        return out
    }

    // MARK: SwiftPM

    /// `.executableTarget(name: "X"` as `swift run X`.
    public static func swiftExecutables(packageSwift: String) -> [RunConfiguration] {
        let text = RunParsing.stripComments(packageSwift)
        var names: [String] = []
        for groups in RunParsing.captures(#"\.executableTarget\s*\(\s*name\s*:\s*"([^"]+)""#, in: text) where !names.contains(groups[0]) {
            names.append(groups[0])
        }
        return names.map { draft($0, "swift run \(ClaudeLaunch.shellQuote($0))", icon: "play.fill") }
    }

    // MARK: Gradle

    /// Module paths from `settings.gradle(.kts)`: every `include(":a:b", ":c")` and `include ':a', ':b'`.
    public static func gradleIncludes(settings: String) -> [String] {
        let text = RunParsing.stripComments(settings)
        var modules: [String] = []
        let calls = RunParsing.captures(#"\binclude\s*\(([^)]*)\)"#, in: text)
            + RunParsing.captures(#"(?m)\binclude[ \t]+((?:["'][^"'\n]+["'][ \t]*,?[ \t]*\n?[ \t]*)+)"#, in: text)
        for groups in calls {
            for name in RunParsing.quotedStrings(groups[0]) {
                let path = name.hasPrefix(":") ? name : ":" + name
                if !modules.contains(path) { modules.append(path) }
            }
        }
        return modules
    }

    /// One runnable thing a Gradle module offers.
    struct GradleApp: Equatable {
        var label: String
        var task: String
        var icon: String
    }

    /// What a module's build file applies, by plugin id, version-catalog alias or convention-plugin id
    /// (`app.campfire.android.application`), and by the DSL blocks the plugins add.
    static func gradleApps(buildFile: String) -> [GradleApp] {
        let text = RunParsing.stripComments(buildFile)
        let plugins = pluginText(text)
        let squashed = plugins.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "\n" }
        var apps: [GradleApp] = []
        func add(_ label: String, _ task: String, _ icon: String) {
            if !apps.contains(where: { $0.task == task }) { apps.append(GradleApp(label: label, task: task, icon: icon)) }
        }

        // `applicationId = …` (or Groovy's `applicationId "…"`) is only set in an app module; reading
        // `.applicationId` off a variant, as baseline-profile modules do, doesn't count.
        let setsApplicationId = text.range(of: #"(?m)^\s*applicationId\s*(=|["'])"#, options: .regularExpression) != nil
        if squashed.contains("androidapplication") || setsApplicationId {
            let flavors = androidFlavors(text)
            // Several flavor dimensions multiply into variants this can't name; better nothing than a wrong task.
            if flavorDimensionCount(text) <= 1 {
                if flavors.isEmpty { add("Android", "installDebug", "iphone") }
                for f in flavors { add("Android (\(f))", "install\(f.prefix(1).uppercased() + f.dropFirst())Debug", "iphone") }
            }
        }

        var rest = text
        // `compose.desktop { application { … } }`, or the same nested as `compose { desktop { … } }`.
        let nested = RunParsing.block(after: #"\bcompose\s*\{"#, in: text).flatMap { compose in
            text[compose].range(of: #"\bdesktop\s*\{"#, options: .regularExpression) == nil ? nil : compose
        }
        if let desktop = RunParsing.block(after: #"\bcompose\s*\.\s*desktop\s*\{"#, in: text) ?? nested {
            if text[desktop].range(of: #"\bapplication\b"#, options: .regularExpression) != nil { add("Desktop", "run", "desktopcomputer") }
            rest.removeSubrange(desktop)
        }
        // CuP (Compose ur Pres) decks declare their targets through the plugin's own DSL.
        let cup = plugins.range(of: #"net\.kodein\.cup|libs\.plugins\.cup\b"#, options: .regularExpression) != nil
        if cup, text.contains("targetDesktop(") { add("Desktop", "run", "desktopcomputer") }
        if squashed.contains("hotreload") || (cup && text.contains("targetDesktop(")) {
            add("Desktop (hot reload)", "hotRunJvm", "desktopcomputer")
        }

        let applicationPlugin = plugins.range(of: #"(?m)(^|[\s{;])(`?application`?)\s*($|[\s;}])"#, options: .regularExpression) != nil
            || plugins.range(of: #"(\bid\s*\(?\s*|plugin\s*[:=]\s*)["']application["']"#, options: .regularExpression) != nil
        if applicationPlugin || rest.range(of: #"\bapplication\s*\{[^}]*mainClass"#, options: .regularExpression) != nil {
            add("Run", "run", "play.fill")
        }

        let intellij = plugins.range(of: #"["']org\.jetbrains\.intellij(\.platform)?["']"#, options: .regularExpression) != nil
            || RunParsing.captures(#"libs\.plugins\.([\w.]+)"#, in: plugins).contains {
                let alias = $0[0].lowercased()
                return alias.contains("intellij") && !alias.contains("module") && !alias.contains("settings")
            }
        if intellij { add("Run IDE", "runIde", "hammer") }

        let wasm = text.range(of: #"\bwasmJs\s*[({]"#, options: .regularExpression) != nil && text.contains("browser")
        if wasm || (cup && text.contains("targetWeb(")) { add("Web", "wasmJsBrowserDevelopmentRun", "globe") }
        return apps
    }

    /// The `plugins { }` block(s) without `apply false` lines, plus legacy `apply plugin:` lines.
    static func pluginText(_ text: String) -> String {
        var parts: [String] = []
        var search = text.startIndex..<text.endIndex
        while let open = text.range(of: #"(?<![\w.])plugins\s*\{"#, options: .regularExpression, range: search),
              let body = RunParsing.block(after: #"(?<![\w.])plugins\s*\{"#, in: text, from: open.lowerBound) {
            parts.append(String(text[body]))
            search = body.upperBound..<text.endIndex
        }
        parts += text.components(separatedBy: .newlines).filter { $0.contains("apply plugin") || $0.contains("apply(plugin") }
        return parts.joined(separator: "\n").components(separatedBy: .newlines)
            .filter { $0.range(of: #"apply\s*\(?\s*false"#, options: .regularExpression) == nil }
            .joined(separator: "\n")
    }

    /// Flavor names in `productFlavors { create("alpha") … }` or the Groovy `productFlavors { alpha { … } }`.
    static func androidFlavors(_ text: String) -> [String] {
        guard let body = RunParsing.block(after: #"\bproductFlavors\s*\{"#, in: text) else { return [] }
        let top = RunParsing.topLevel(String(text[body]))
        var names: [String] = []
        for g in RunParsing.captures(#"\b(?:create|register|maybeCreate)\s*\(\s*["']([^"']+)["']"#, in: top) where !names.contains(g[0]) {
            names.append(g[0])
        }
        let keywords: Set = ["all", "configureEach", "named", "getByName", "matching", "whenObjectAdded", "create", "register", "maybeCreate"]
        for g in RunParsing.captures(#"(?m)^\s*([A-Za-z_]\w*)\s*\{\}"#, in: top) where !keywords.contains(g[0]) && !names.contains(g[0]) {
            names.append(g[0])
        }
        return names
    }

    static func flavorDimensionCount(_ text: String) -> Int {
        text.components(separatedBy: .newlines).filter { $0.contains("flavorDimensions") }
            .map { RunParsing.quotedStrings($0).count }.reduce(0, +)
    }

    /// Modules from the settings file, each by what its build file applies, run through the root's
    /// wrapper when there is one. A single-module build runs its tasks unprefixed; in a multi-module
    /// build the root's own tasks are `:task`, because a bare name runs in every module that has it.
    public static func gradle(settings: String?, buildFiles: [String: String], hasWrapper: Bool) -> [RunConfiguration] {
        let gradle = hasWrapper ? "./gradlew" : "gradle"
        let modules = settings.map(gradleIncludes) ?? []
        var entries: [(module: String, app: GradleApp)] = []
        for module in [""] + modules {
            guard let file = buildFiles[module] else { continue }
            entries += gradleApps(buildFile: file).map { (module, $0) }
        }
        // Names read as the platform alone ("Android (alpha)", "Desktop") unless two modules share
        // one, and then every entry says its module ("catalog · Desktop"). "Run" says nothing on its
        // own, so it always names its module.
        let labels = entries.map(\.app.label)
        let qualify = Set(labels).count != labels.count
        return entries.map { module, app in
            let task = module.isEmpty ? (modules.isEmpty ? app.task : ":" + app.task) : module + ":" + app.task
            let qualifier = moduleQualifier(module)
            let name = (qualify || app.label == "Run") && !qualifier.isEmpty ? "\(qualifier) · \(app.label)" : app.label
            return draft(name, "\(gradle) \(task)", icon: app.icon)
        }
    }

    /// The module's most telling segment: `:app:android` → `app`, `:spikes:jewel-compare` → `jewel-compare`.
    static func moduleQualifier(_ module: String) -> String {
        let platforms: Set = ["android", "desktop", "jvm", "web", "wasm", "wasmjs", "js", "ios", "browser", "main"]
        let segments = module.split(separator: ":").map(String.init)
        return segments.last(where: { !platforms.contains($0.lowercased()) }) ?? segments.last ?? ""
    }

    static func gradle(in root: URL) -> [RunConfiguration] {
        let fm = FileManager.default
        func read(_ dir: URL, _ names: [String]) -> String? {
            names.lazy.compactMap { try? String(contentsOf: dir.appendingPathComponent($0), encoding: .utf8) }.first
        }
        let settings = read(root, ["settings.gradle.kts", "settings.gradle"])
        var buildFiles: [String: String] = [:]
        if let rootBuild = read(root, ["build.gradle.kts", "build.gradle"]) { buildFiles[""] = rootBuild }
        guard settings != nil || !buildFiles.isEmpty else { return [] }
        for module in settings.map(gradleIncludes) ?? [] {
            let dir = root.appendingPathComponent(module.split(separator: ":").joined(separator: "/"))
            if let file = read(dir, ["build.gradle.kts", "build.gradle"]) { buildFiles[module] = file }
        }
        return gradle(settings: settings, buildFiles: buildFiles,
                      hasWrapper: fm.fileExists(atPath: root.appendingPathComponent("gradlew").path))
    }

    // MARK: Xcode

    /// Xcode containers at the top level and one directory down. A directory with a workspace offers
    /// only the workspace, which already contains its projects.
    public static func xcodeProjects(in root: URL) -> [URL] {
        let fm = FileManager.default
        func containers(in dir: URL) -> [URL] {
            let names = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
            let workspaces = names.filter { $0.hasSuffix(".xcworkspace") }
            return (workspaces.isEmpty ? names.filter { $0.hasSuffix(".xcodeproj") } : workspaces).map { dir.appendingPathComponent($0) }
        }
        var out = containers(in: root)
        for name in ((try? fm.contentsOfDirectory(atPath: root.path)) ?? []).sorted()
        where !name.hasPrefix(".") && !name.hasSuffix(".xcodeproj") && !name.hasSuffix(".xcworkspace")
            && !RunParsing.skippedDirectories.contains(name) {
            var isDir: ObjCBool = false
            let dir = root.appendingPathComponent(name)
            if fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue { out += containers(in: dir) }
        }
        return out
    }

    /// macOS app schemes from `xcodebuild -list -json` output, as a build into `.build/clinic-run`
    /// followed by `open` of the product. A project's schemes are kept only when they build a macOS
    /// application target; a workspace whose projects can't be read keeps them all.
    public static func xcodeConfigurations(listJSON: Data, container: URL, root: URL,
                                           avoiding taken: Set<String> = []) -> [RunConfiguration] {
        guard let object = try? JSONSerialization.jsonObject(with: listJSON) as? [String: Any],
              let info = (object["project"] ?? object["workspace"]) as? [String: Any],
              let schemes = info["schemes"] as? [String] else { return [] }
        let isWorkspace = container.pathExtension == "xcworkspace"
        let projects = isWorkspace ? workspaceProjects(container) : [container]
        var apps: [String: String] = [:]  // target name → product name
        var readAny = false
        var unparsedMacApp = false
        for project in projects {
            guard let data = try? Data(contentsOf: project.appendingPathComponent("project.pbxproj")) else { continue }
            readAny = true
            if let targets = macAppTargets(pbxproj: data) {
                apps.merge(targets) { first, _ in first }
            } else {
                unparsedMacApp = unparsedMacApp || hasMacAppText(data)
            }
        }
        // A workspace none of whose projects could be read keeps every scheme; so does a project that
        // only passes the plain-text check, since its targets can't be told apart.
        let keepAll = (isWorkspace && !readAny) || (apps.isEmpty && unparsedMacApp)
        if apps.isEmpty && !keepAll { return [] }

        let rel = RunParsing.relativePath(of: container, in: root)
        let flag = isWorkspace ? "-workspace" : "-project"
        var out: [RunConfiguration] = []
        for scheme in schemes {
            let product: String?
            if let fromScheme = schemeProduct(scheme, containers: [container] + projects), keepAll || apps[fromScheme.target] != nil {
                product = fromScheme.product
            } else if let p = apps[scheme] {
                product = p
            } else if keepAll {
                product = nil
            } else { continue }
            let products = ".build/clinic-run/Build/Products/Debug"
            let open = product.map { "open \(ClaudeLaunch.shellQuote("\(products)/\($0).app"))" }
                ?? "open \"$(find \(products) -maxdepth 1 -name '*.app' -print -quit)\""
            let build = ["xcodebuild", flag, ClaudeLaunch.shellQuote(rel), "-scheme", ClaudeLaunch.shellQuote(scheme),
                         "-configuration", "Debug", "-destination", "'platform=macOS'", "-derivedDataPath", ".build/clinic-run", "build"]
            out.append(RunConfiguration(id: "xcode-" + RunConfiguration.makeId(from: scheme, avoiding: []), name: scheme,
                                        icon: "desktopcomputer", command: build.joined(separator: " ") + " && " + open))
        }
        return uniqued(out, avoiding: taken)
    }

    /// Application targets whose SDK is macOS (or `auto` with macOS supported), mapped to their product
    /// names. Nil when the file doesn't parse as a property list.
    static func macAppTargets(pbxproj: Data) -> [String: String]? {
        guard let plist = try? PropertyListSerialization.propertyList(from: pbxproj, format: nil) as? [String: Any],
              let objects = plist["objects"] as? [String: [String: Any]] else { return nil }
        func settings(_ listId: Any?) -> [String: Any] {
            guard let id = listId as? String, let ids = objects[id]?["buildConfigurations"] as? [String] else { return [:] }
            let configs = ids.compactMap { objects[$0] }
            let chosen = configs.first { $0["name"] as? String == "Debug" } ?? configs.first
            return chosen?["buildSettings"] as? [String: Any] ?? [:]
        }
        let projectSettings = (plist["rootObject"] as? String).flatMap { objects[$0] }.map { settings($0["buildConfigurationList"]) } ?? [:]
        var out: [String: String] = [:]
        for object in objects.values where object["isa"] as? String == "PBXNativeTarget"
            && object["productType"] as? String == "com.apple.product-type.application" {
            guard let name = object["name"] as? String else { continue }
            let own = settings(object["buildConfigurationList"])
            func value(_ key: String) -> String? { (own[key] ?? projectSettings[key]) as? String }
            let sdk = value("SDKROOT")
            let platforms = value("SUPPORTED_PLATFORMS") ?? ""
            guard sdk == "macosx" || ((sdk == nil || sdk == "auto") && platforms.contains("macosx")) else { continue }
            let product = value("PRODUCT_NAME").flatMap { $0.isEmpty || $0.contains("$") ? nil : $0 } ?? name
            out[name] = product
        }
        return out
    }

    /// The fallback for a project file that doesn't parse: some target builds for macOS, and some target is an app.
    static func hasMacAppText(_ pbxproj: Data) -> Bool {
        let text = String(decoding: pbxproj, as: UTF8.self)
        return text.contains("SDKROOT = macosx") && text.contains("com.apple.product-type.application")
    }

    /// The target and product a shared scheme launches, from its `BuildableProductRunnable`.
    static func schemeProduct(_ scheme: String, containers: [URL]) -> (target: String, product: String)? {
        for container in containers {
            let url = container.appendingPathComponent("xcshareddata/xcschemes/\(scheme).xcscheme")
            guard let text = try? String(contentsOf: url, encoding: .utf8),
                  let runnable = text.range(of: "<BuildableProductRunnable") else { continue }
            let tail = String(text[runnable.lowerBound...])
            guard let product = RunParsing.captures(#"BuildableName\s*=\s*"([^"]+)\.app""#, in: tail).first?[0],
                  let target = RunParsing.captures(#"BlueprintName\s*=\s*"([^"]+)""#, in: tail).first?[0] else { continue }
            return (target, product)
        }
        return nil
    }

    /// The projects a workspace lists, relative to the workspace's own directory.
    static func workspaceProjects(_ workspace: URL) -> [URL] {
        let data = workspace.appendingPathComponent("contents.xcworkspacedata")
        guard let doc = try? XMLDocument(contentsOf: data, options: []),
              let nodes = try? doc.nodes(forXPath: "//FileRef/@location") else { return [] }
        let dir = workspace.deletingLastPathComponent()
        return nodes.compactMap(\.stringValue).compactMap { location in
            guard let colon = location.firstIndex(of: ":") else { return nil }
            let kind = location[..<colon], path = String(location[location.index(after: colon)...])
            guard path.hasSuffix(".xcodeproj") else { return nil }
            return kind == "absolute" ? URL(fileURLWithPath: path) : dir.appendingPathComponent(path)
        }
    }

    /// Every container's macOS app schemes, from `xcodebuild -list -json` with a bound on each call:
    /// a broken project can leave `xcodebuild` hanging, and a late answer is ignored. Ids start
    /// `xcode-`, so they never collide with `detect(in:)`'s.
    public static func detectXcode(in root: URL, timeout: Duration = .seconds(15)) async -> [RunConfiguration] {
        var out: [RunConfiguration] = []
        for container in xcodeProjects(in: root) {
            // A project with no macOS app would only be listed to be dropped; skip the subprocess.
            if container.pathExtension == "xcodeproj",
               let data = try? Data(contentsOf: container.appendingPathComponent("project.pbxproj")),
               macAppTargets(pbxproj: data).map({ $0.isEmpty }) ?? !hasMacAppText(data) { continue }
            let flag = container.pathExtension == "xcworkspace" ? "-workspace" : "-project"
            guard let list = await boundedRun("xcodebuild", ["-list", "-json", flag, container.path], in: root, timeout: timeout) else { continue }
            out += xcodeConfigurations(listJSON: list, container: container, root: root, avoiding: Set(out.map(\.id)))
        }
        return out
    }

    /// A tool's stdout when it exits 0 within `timeout`, else nil. `ToolProcess` can't be cancelled,
    /// so the race only stops waiting: a hung process is left to finish on its own.
    static func boundedRun(_ tool: String, _ arguments: [String], in dir: URL, timeout: Duration) async -> Data? {
        let once = OnceBox()
        return await withCheckedContinuation { (cont: CheckedContinuation<Data?, Never>) in
            once.set(cont)
            Task.detached {
                let result = await ToolProcess.run(executable: tool, arguments: arguments,
                                                   environment: ProcessEnvironment.withToolPaths(), currentDirectory: dir)
                once.resume(result.status == 0 ? result.stdout : nil)
            }
            Task.detached {
                try? await Task.sleep(for: timeout)
                once.resume(nil)
            }
        }
    }
}

/// Resumes a continuation exactly once, from whichever side of a race gets there first.
private final class OnceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<Data?, Never>?

    func set(_ c: CheckedContinuation<Data?, Never>) { lock.lock(); cont = c; lock.unlock() }

    func resume(_ value: Data?) {
        lock.lock()
        let c = cont
        cont = nil
        lock.unlock()
        c?.resume(returning: value)
    }
}

/// Text and path helpers the importer and the detector share.
enum RunParsing {
    /// Directories never searched for build or IDE files.
    static let skippedDirectories: Set<String> = ["build", "node_modules", "Pods", "DerivedData", "Carthage", "vendor", "target", "dist", "out"]

    /// Capture groups (1…) of every match; a group that didn't take part is "".
    static func captures(_ pattern: String, in text: String) -> [[String]] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { m in
            (1..<max(m.numberOfRanges, 2)).map { i in
                i < m.numberOfRanges && m.range(at: i).location != NSNotFound ? ns.substring(with: m.range(at: i)) : ""
            }
        }
    }

    /// Every `"…"` or `'…'` literal in `text`, without its quotes.
    static func quotedStrings(_ text: String) -> [String] {
        captures(#""([^"]*)"|'([^']*)'"#, in: text).map { $0[0].isEmpty ? $0[1] : $0[0] }
    }

    /// `// …` and `/* … */` removed, leaving string literals (`"…"`, `'…'`) alone.
    static func stripComments(_ text: String) -> String {
        String(decoding: stripComments(Array(text.utf8), singleQuotes: true), as: UTF8.self)
    }

    /// TOML's `# …`, outside strings.
    static func stripHashComment(_ line: String) -> String {
        var quote: Character?
        for i in line.indices {
            let ch = line[i]
            if let q = quote { if ch == q { quote = nil } } else if ch == "\"" || ch == "'" { quote = ch } else if ch == "#" {
                return String(line[..<i])
            }
        }
        return line
    }

    /// JSON with comments and trailing commas (VS Code's `tasks.json`) made plain JSON.
    static func stripJSONC(_ data: Data) -> Data {
        let bytes = stripComments(Array(data), singleQuotes: false)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var inString = false, escaped = false
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            if inString {
                out.append(b)
                if escaped { escaped = false } else if b == 0x5C { escaped = true } else if b == 0x22 { inString = false }
            } else if b == 0x22 {
                inString = true; out.append(b)
            } else if b == 0x2C {
                var j = i + 1
                while j < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[j]) { j += 1 }
                if j < bytes.count, bytes[j] == 0x7D || bytes[j] == 0x5D {} else { out.append(b) }
            } else {
                out.append(b)
            }
            i += 1
        }
        return Data(out)
    }

    private static func stripComments(_ bytes: [UInt8], singleQuotes: Bool) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var quote: UInt8?
        var escaped = false
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            if let q = quote {
                out.append(b)
                if escaped { escaped = false } else if b == 0x5C { escaped = true } else if b == q || b == 0x0A && q == 0x27 { quote = nil }
                i += 1
            } else if b == 0x22 || (singleQuotes && b == 0x27) {
                quote = b; out.append(b); i += 1
            } else if b == 0x2F, i + 1 < bytes.count, bytes[i + 1] == 0x2F {
                while i < bytes.count, bytes[i] != 0x0A { i += 1 }
            } else if b == 0x2F, i + 1 < bytes.count, bytes[i + 1] == 0x2A {
                i += 2
                while i < bytes.count, !(bytes[i] == 0x2A && i + 1 < bytes.count && bytes[i + 1] == 0x2F) {
                    if bytes[i] == 0x0A { out.append(0x0A) }
                    i += 1
                }
                i += 2
            } else {
                out.append(b); i += 1
            }
        }
        return out
    }

    /// The body (between the braces) of the block whose opening matches `pattern`, which must end in `{`.
    static func block(after pattern: String, in text: String, from start: String.Index? = nil) -> Range<String.Index>? {
        guard let open = text.range(of: pattern, options: .regularExpression, range: (start ?? text.startIndex)..<text.endIndex) else { return nil }
        var depth = 1
        var i = open.upperBound
        while i < text.endIndex {
            switch text[i] {
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 { return open.upperBound..<i }
            default: break
            }
            i = text.index(after: i)
        }
        return open.upperBound..<text.endIndex
    }

    /// `text` with every nested block emptied to `{}`, so a pattern sees only the top level.
    static func topLevel(_ text: String) -> String {
        var out = ""
        var depth = 0
        for ch in text {
            if ch == "{" { if depth == 0 { out.append("{") }; depth += 1 }
            else if ch == "}" { depth = max(0, depth - 1); if depth == 0 { out.append("}") } }
            else if depth == 0 { out.append(ch) }
        }
        return out
    }

    /// Collapses `.`, `..` and empty segments; `.` for the root itself.
    static func normalize(_ path: String) -> String {
        let absolute = path.hasPrefix("/")
        var parts: [Substring] = []
        for seg in path.split(separator: "/", omittingEmptySubsequences: true) {
            if seg == "." { continue }
            if seg == "..", let last = parts.last, last != ".." { parts.removeLast(); continue }
            if seg == "..", absolute { continue }
            parts.append(seg)
        }
        let joined = parts.joined(separator: "/")
        if absolute { return "/" + joined }
        return joined.isEmpty ? "." : joined
    }

    /// `path` and each directory above it up to the root (`.`), for relative paths inside the root.
    static func ancestors(of path: String) -> [String] {
        let p = normalize(path)
        guard !p.hasPrefix("/"), !p.hasPrefix("..") else { return [] }
        guard p != "." else { return ["."] }
        var parts = p.split(separator: "/").map(String.init)
        var out: [String] = []
        while !parts.isEmpty { out.append(parts.joined(separator: "/")); parts.removeLast() }
        return out + ["."]
    }

    /// How to get from directory `from` to `to`, both relative to the same root. `to` unchanged when
    /// either lies outside it.
    static func relative(from: String, to: String) -> String {
        let a = normalize(from), b = normalize(to)
        guard !a.hasPrefix("/"), !b.hasPrefix("/"), !a.hasPrefix(".."), !b.hasPrefix("..") else { return b }
        let aa = a == "." ? [] : a.split(separator: "/"), bb = b == "." ? [] : b.split(separator: "/")
        var common = 0
        while common < min(aa.count, bb.count), aa[common] == bb[common] { common += 1 }
        let parts = Array(repeating: "..", count: aa.count - common) + bb[common...].map(String.init)
        return parts.isEmpty ? "." : parts.joined(separator: "/")
    }

    static func relativePath(of url: URL, in root: URL) -> String {
        let r = root.standardizedFileURL.path, p = url.standardizedFileURL.path
        return p.hasPrefix(r + "/") ? String(p.dropFirst(r.count + 1)) : p
    }

    /// A JetBrains path macro (`$MODULE_DIR$`) still in any of `values`.
    static func firstJetBrainsMacro(in values: [String]) -> String? {
        values.lazy.compactMap { captures(#"(\$[A-Za-z_][A-Za-z0-9_]*\$)"#, in: $0).first?[0] }.first
    }

    /// A VS Code variable (`${file}`, `${env:HOME}`) still in any of `values`. Upper-case `${HOME}` is
    /// the shell's own syntax, which VS Code leaves alone, so it stays.
    static func firstVSCodeVariable(in values: [String]) -> String? {
        values.lazy.compactMap { captures(#"(\$\{(?:[a-z][^}]*|[^}]*:[^}]*)\})"#, in: $0).first?[0] }.first
    }

    /// "a", "a and b", "a, b and c".
    static func list(_ items: [String]) -> String {
        guard items.count > 1 else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
    }
}
