import Foundation

/// One configuration found in an IDE's files, as the import sheet lists it (ADR-122). The copy is
/// one-time: nothing links the imported entry back to where it came from.
public struct RunImportCandidate: Sendable, Equatable, Identifiable {
    public struct Source: Sendable, Equatable, Hashable {
        public enum Format: String, Sendable { case jetBrains, vsCode }
        public var format: Format
        /// Relative to the project root, e.g. `.run/Desktop.run.xml`.
        public var path: String
        public init(format: Format, path: String) { self.format = format; self.path = path }
        public var formatLabel: String { format == .jetBrains ? "IntelliJ" : "VS Code" }

        /// The IDE project the file belongs to (`.` or a first-level subdirectory). Compounds only
        /// name configurations from their own project.
        var base: String {
            let first = path.split(separator: "/").first.map(String.init) ?? "."
            return first.hasPrefix(".") ? "." : first
        }
    }

    /// `<path>#<name>`: unique across a project's files.
    public var id: String
    public var name: String
    /// "Gradle", "Shell script", "Compound", "Android app"…
    public var kindLabel: String
    public var source: Source
    /// What lands in `run.json`; nil when it can't come across. A compound's `compound` holds its
    /// members' names until `RunImporter.importing` rewrites them to ids.
    public var configuration: RunConfiguration?
    /// Why it can't come across, or what is lost when it does.
    public var problem: String?
    public var defaultSelected: Bool
    /// A compound's importable members, as candidate ids parallel to `configuration.compound`. The
    /// sheet checks these along with the compound.
    public var memberIds: [String] = []
    /// A compound's member names as its file wrote them, until `RunImporter.resolvingCompounds` links them.
    var references: [String]?

    public init(id: String, name: String, kindLabel: String, source: Source, configuration: RunConfiguration?,
                problem: String?, defaultSelected: Bool? = nil) {
        self.id = id; self.name = name; self.kindLabel = kindLabel; self.source = source
        self.configuration = configuration; self.problem = problem
        self.defaultSelected = defaultSelected ?? (configuration != nil && problem == nil)
    }

    public var isImportable: Bool { configuration != nil }
}

/// Reads JetBrains and VS Code run configurations into candidates (ADR-122, *Import*). Files only;
/// nothing is executed.
public enum RunImporter {
    // MARK: Project

    /// Every candidate under `projectRoot`: JetBrains `.run/*.run.xml` and `.idea/runConfigurations/*.xml`
    /// at the root and in first-level subdirectories (an IDE project can live in one, like
    /// `intellij-plugin/`), then the root's `.vscode/tasks.json`.
    public static func candidates(in projectRoot: URL) -> [RunImportCandidate] {
        let fm = FileManager.default
        var jetBrains: [RunImportCandidate] = []
        for (base, projectDir) in jetBrainsBases(projectRoot) {
            for folder in [".run", ".idea/runConfigurations"] {
                let rel = base == "." ? folder : base + "/" + folder
                let dir = projectRoot.appendingPathComponent(rel)
                let files = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".xml") }.sorted()
                for file in files {
                    guard let data = try? Data(contentsOf: dir.appendingPathComponent(file)) else { continue }
                    jetBrains += self.jetBrains(xml: data, path: rel + "/" + file, projectDir: projectDir) { wrapperDir in
                        fm.fileExists(atPath: projectRoot.appendingPathComponent(wrapperDir).appendingPathComponent("gradlew").path)
                    }
                }
            }
        }
        var all = resolvingCompounds(jetBrains)
        let tasks = projectRoot.appendingPathComponent(".vscode/tasks.json")
        if let data = try? Data(contentsOf: tasks) {
            all += vsCode(tasksJSON: data, packageManager: RunDetector.packageManager(in: projectRoot))
        }
        return all
    }

    /// Whether *Import from IntelliJ / VS Code…* has anything to read. Cheap enough for a menu.
    public static func hasSources(in projectRoot: URL) -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: projectRoot.appendingPathComponent(".vscode/tasks.json").path) { return true }
        return jetBrainsBases(projectRoot).contains { base, _ in
            [".run", ".idea/runConfigurations"].contains { folder in
                let dir = projectRoot.appendingPathComponent(base == "." ? folder : base + "/" + folder)
                return ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).contains { $0.hasSuffix(".xml") }
            }
        }
    }

    /// Directories that may hold JetBrains files, each with its `$PROJECT_DIR$`. A subdirectory is its
    /// own IDE project when it has `.idea` or a Gradle settings file; otherwise its `.run` belongs to the root's.
    static func jetBrainsBases(_ root: URL) -> [(base: String, projectDir: String)] {
        let fm = FileManager.default
        var bases: [(String, String)] = [(".", ".")]
        let subdirs = ((try? fm.contentsOfDirectory(atPath: root.path)) ?? []).sorted()
        for name in subdirs where !name.hasPrefix(".") && !RunParsing.skippedDirectories.contains(name) {
            let dir = root.appendingPathComponent(name)
            let hasRun = fm.fileExists(atPath: dir.appendingPathComponent(".run").path)
                || fm.fileExists(atPath: dir.appendingPathComponent(".idea/runConfigurations").path)
            guard hasRun else { continue }
            let ownProject = [".idea", "settings.gradle.kts", "settings.gradle"].contains {
                fm.fileExists(atPath: dir.appendingPathComponent($0).path)
            }
            bases.append((name, ownProject ? name : "."))
        }
        return bases
    }

    // MARK: JetBrains

    /// Candidates in one JetBrains file. Compounds still name their members; `resolvingCompounds`
    /// links them once every file is read. `projectDir` is `$PROJECT_DIR$` relative to the project
    /// root; `gradleWrappers` lists the root-relative directories holding a `gradlew`.
    public static func jetBrains(xml: Data, path: String, projectDir: String = ".",
                                 gradleWrappers: Set<String> = ["."]) -> [RunImportCandidate] {
        jetBrains(xml: xml, path: path, projectDir: projectDir) { gradleWrappers.contains(RunParsing.normalize($0)) }
    }

    static func jetBrains(xml: Data, path: String, projectDir: String,
                          hasWrapper: (String) -> Bool) -> [RunImportCandidate] {
        let source = RunImportCandidate.Source(format: .jetBrains, path: path)
        guard let doc = try? XMLDocument(data: xml, options: []),
              let nodes = try? doc.nodes(forXPath: "//configuration") else {
            let name = (path as NSString).lastPathComponent
            return [RunImportCandidate(id: path, name: name, kindLabel: "IntelliJ", source: source,
                                       configuration: nil, problem: "The file isn’t valid XML.")]
        }
        return nodes.compactMap { $0 as? XMLElement }.compactMap { el -> RunImportCandidate? in
            // `default="true"` entries are the IDE's templates for new configurations, not runnable ones.
            guard el.attribute(forName: "default")?.stringValue != "true",
                  let name = el.attribute(forName: "name")?.stringValue, !name.isEmpty else { return nil }
            let type = el.attribute(forName: "type")?.stringValue ?? ""
            return jetBrainsCandidate(el, name: name, type: type, source: source, projectDir: RunParsing.normalize(projectDir),
                                      hasWrapper: hasWrapper)
        }
    }

    private static func jetBrainsCandidate(_ el: XMLElement, name: String, type: String, source: RunImportCandidate.Source,
                                           projectDir: String, hasWrapper: (String) -> Bool) -> RunImportCandidate {
        let id = source.path + "#" + name
        let kind = jetBrainsKind(type, factory: el.attribute(forName: "factoryName")?.stringValue)
        func refused(_ why: String) -> RunImportCandidate {
            RunImportCandidate(id: id, name: name, kindLabel: kind, source: source, configuration: nil, problem: why)
        }
        func config(command: String, directory: String, env: [String: String], icon: String) -> RunImportCandidate {
            if let macro = RunParsing.firstJetBrainsMacro(in: [command, directory] + Array(env.values)) {
                return refused("Uses \(macro), which Clinic can’t fill in.")
            }
            let c = RunConfiguration(id: RunConfiguration.makeId(from: name, avoiding: []), name: name, icon: icon,
                                     command: command, directory: directory == "." ? nil : directory,
                                     env: env.isEmpty ? nil : env, device: RunDevicePlatform.inferred(fromCommand: command))
            return RunImportCandidate(id: id, name: name, kindLabel: kind, source: source, configuration: c, problem: nil)
        }

        switch type {
        case "GradleRunConfiguration":
            let settings = el.elements(forName: "ExternalSystemSettings").first ?? el
            let tasks = listValues(settings, "taskNames")
            guard !tasks.isEmpty else { return refused("Has no Gradle tasks.") }
            let dir = mapPath(option(settings, "externalProjectPath") ?? "$PROJECT_DIR$", projectDir: projectDir)
            var args = tasks.map(quoteTaskArgument)
            if let params = option(settings, "scriptParameters")?.trimmingCharacters(in: .whitespaces), !params.isEmpty {
                args.append(params)
            }
            // `externalProjectPath` can be a module (`$PROJECT_DIR$/host`) with the wrapper above it, so
            // the command starts where the wrapper is and points Gradle at the module with `-p`.
            let wrapperDir = RunParsing.ancestors(of: dir).first(where: hasWrapper)
            let command: String
            let directory: String
            if let wrapperDir {
                let into = RunParsing.relative(from: wrapperDir, to: dir)
                command = (["./gradlew"] + (into == "." ? [] : ["-p", ClaudeLaunch.shellQuote(into)]) + args).joined(separator: " ")
                directory = wrapperDir
            } else {
                command = (["gradle"] + args).joined(separator: " ")
                directory = dir
            }
            return config(command: command, directory: directory, env: mapEntries(settings, "env"), icon: gradleIcon(tasks))

        case "ShConfigurationType":
            let workOption = option(el, "SCRIPT_WORKING_DIRECTORY").flatMap { $0.isEmpty ? nil : $0 }
            let workDir = workOption.map { mapPath($0, projectDir: projectDir) } ?? projectDir
            let fromWorkDir = RunParsing.relative(from: workDir, to: projectDir)
            func inCommand(_ s: String) -> String { s.replacingOccurrences(of: "$PROJECT_DIR$", with: fromWorkDir) }
            let scriptPath = option(el, "SCRIPT_PATH") ?? ""
            let executeFile = option(el, "EXECUTE_SCRIPT_FILE").map { $0 == "true" } ?? !scriptPath.isEmpty
            var env: [String: String] = [:]
            for e in el.elements(forName: "envs").first?.elements(forName: "env") ?? [] {
                if let k = e.attribute(forName: "name")?.stringValue { env[k] = inCommand(e.attribute(forName: "value")?.stringValue ?? "") }
            }
            let command: String
            if executeFile {
                guard !scriptPath.isEmpty else { return refused("Has no script to run.") }
                var script = RunParsing.normalize(inCommand(scriptPath))
                if !script.hasPrefix("/"), !script.hasPrefix(".") { script = "./" + script }
                let parts = [option(el, "INTERPRETER_PATH") ?? "", option(el, "INTERPRETER_OPTIONS") ?? "",
                             ClaudeLaunch.shellQuote(script), option(el, "SCRIPT_OPTIONS") ?? ""]
                command = parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
            } else {
                command = inCommand(option(el, "SCRIPT_TEXT") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !command.isEmpty else { return refused("Has no script text.") }
            }
            return config(command: command, directory: workDir, env: env, icon: "terminal")

        case "CompoundRunConfigurationType":
            let names = el.elements(forName: "toRun").compactMap { $0.attribute(forName: "name")?.stringValue }
            var c = RunImportCandidate(id: id, name: name, kindLabel: kind, source: source,
                                       configuration: RunConfiguration(id: RunConfiguration.makeId(from: name, avoiding: []),
                                                                       name: name, icon: "square.stack", compound: []),
                                       problem: nil)
            c.references = names
            return c

        case let t where t.hasPrefix("Android"):
            return refused("Names a module, not a command. Set Up with Claude can write one.")
        case "Application", "JetRunConfigurationType":
            return refused("Names a main class, not a command. Set Up with Claude can write one.")
        case "KmmRunConfiguration":
            return refused("Names an Xcode scheme, not a command. Set Up with Claude can write one.")
        default:
            return refused("Not a shell command.")
        }
    }

    /// A guess from the task names; the editor sheet can change it.
    private static func gradleIcon(_ tasks: [String]) -> String {
        if tasks.contains(where: { $0.contains("install") }) { return "iphone" }
        if tasks.contains(where: { $0.hasSuffix("runIde") }) { return "hammer" }
        if tasks.contains(where: { $0.contains("BrowserDevelopmentRun") || $0.contains("BrowserRun") }) { return "globe" }
        return "play.fill"
    }

    private static func jetBrainsKind(_ type: String, factory: String?) -> String {
        switch type {
        case "GradleRunConfiguration": "Gradle"
        case "ShConfigurationType": "Shell script"
        case "CompoundRunConfigurationType": "Compound"
        case "AndroidRunConfigurationType": "Android app"
        case "AndroidTestRunConfigurationType": "Android test"
        case "AndroidBaselineProfileRunConfigurationType": "Baseline profile"
        case "Application": "Application"
        case "JetRunConfigurationType": "Kotlin"
        case "KmmRunConfiguration": "Kotlin Multiplatform"
        case "JUnit": "JUnit"
        default: factory ?? type.replacingOccurrences(of: "RunConfigurationType", with: "")
                                  .replacingOccurrences(of: "ConfigurationType", with: "")
        }
    }

    /// A task argument as the shell should see it: values that already carry their quotes
    /// (`"com.livewire.MainKt"`) and plain words stay verbatim, anything else is quoted.
    static func quoteTaskArgument(_ value: String) -> String {
        if value.count >= 2, let first = value.first, first == value.last, first == "\"" || first == "'" { return value }
        return ClaudeLaunch.shellQuote(value)
    }

    /// `$PROJECT_DIR$/sub` as a path relative to the project root. Other macros are left in place
    /// for the refusal check.
    static func mapPath(_ value: String, projectDir: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("$PROJECT_DIR$") else { return RunParsing.normalize(trimmed) }
        return RunParsing.normalize(projectDir + "/" + trimmed.dropFirst("$PROJECT_DIR$".count))
    }

    private static func option(_ el: XMLElement, _ name: String) -> String? {
        el.elements(forName: "option").first { $0.attribute(forName: "name")?.stringValue == name }?
            .attribute(forName: "value")?.stringValue
    }

    private static func listValues(_ el: XMLElement, _ name: String) -> [String] {
        guard let opt = el.elements(forName: "option").first(where: { $0.attribute(forName: "name")?.stringValue == name }) else { return [] }
        return (opt.elements(forName: "list").first?.elements(forName: "option") ?? [])
            .compactMap { $0.attribute(forName: "value")?.stringValue }
            .filter { !$0.isEmpty }
    }

    private static func mapEntries(_ el: XMLElement, _ name: String) -> [String: String] {
        guard let opt = el.elements(forName: "option").first(where: { $0.attribute(forName: "name")?.stringValue == name }) else { return [:] }
        var out: [String: String] = [:]
        for entry in opt.elements(forName: "map").first?.elements(forName: "entry") ?? [] {
            if let k = entry.attribute(forName: "key")?.stringValue { out[k] = entry.attribute(forName: "value")?.stringValue ?? "" }
        }
        return out
    }

    // MARK: Compounds

    /// Links each compound to its members by name, within its own format and IDE project. A member
    /// that is itself a compound is flattened, because `run.json` compounds don't nest. A compound
    /// missing some members imports with the rest, says so, and starts unchecked.
    public static func resolvingCompounds(_ candidates: [RunImportCandidate]) -> [RunImportCandidate] {
        var out = candidates
        for i in out.indices {
            guard let refs = out[i].references else { continue }
            let group = candidates.filter { $0.source.format == out[i].source.format && $0.source.base == out[i].source.base }
            var ok: [RunImportCandidate] = []
            var missing: [String] = []
            var visiting: Set<String> = [out[i].id]
            func add(_ name: String) {
                guard let member = group.first(where: { $0.name == name && !visiting.contains($0.id) }) else {
                    if !missing.contains(name) { missing.append(name) }
                    return
                }
                if let nested = member.references {
                    visiting.insert(member.id)
                    nested.forEach(add)
                } else if member.isImportable {
                    if !ok.contains(where: { $0.id == member.id }) { ok.append(member) }
                } else if !missing.contains(name) {
                    missing.append(name)
                }
            }
            refs.forEach(add)
            out[i].references = nil
            out[i].memberIds = ok.map(\.id)
            out[i].configuration?.compound = ok.map(\.name)
            if ok.isEmpty {
                out[i].configuration = nil
                out[i].memberIds = []
                out[i].problem = missing.isEmpty ? "Starts nothing." : "Needs \(RunParsing.list(missing)), which can’t be imported."
                out[i].defaultSelected = false
            } else if !missing.isEmpty {
                let rest = ok.count == 1 ? "Imports as \(ok[0].name) alone." : "Imports with \(RunParsing.list(ok.map(\.name))) only."
                out[i].problem = "Needs \(RunParsing.list(missing)), which can’t be imported. " + rest
                out[i].defaultSelected = false
            }
        }
        return out
    }

    // MARK: VS Code

    /// Candidates in a `.vscode/tasks.json` (JSON with comments and trailing commas). `packageManager`
    /// runs `npm` tasks; it's the one the project's lockfile names.
    public static func vsCode(tasksJSON: Data, path: String = ".vscode/tasks.json",
                              packageManager: String = "npm") -> [RunImportCandidate] {
        let source = RunImportCandidate.Source(format: .vsCode, path: path)
        guard let object = try? JSONSerialization.jsonObject(with: RunParsing.stripJSONC(tasksJSON)) as? [String: Any],
              let tasks = object["tasks"] as? [[String: Any]] else {
            return [RunImportCandidate(id: path, name: "tasks.json", kindLabel: "VS Code", source: source,
                                       configuration: nil, problem: "The file isn’t valid JSON.")]
        }
        let parsed = tasks.enumerated().map { index, raw in
            vsCodeCandidate(raw, index: index, source: source, packageManager: packageManager)
        }
        return resolvingCompounds(parsed)
    }

    private static func vsCodeCandidate(_ raw: [String: Any], index: Int, source: RunImportCandidate.Source,
                                        packageManager: String) -> RunImportCandidate {
        var task = raw
        // Clinic only runs on macOS, so the `osx` overrides are the task as it would run here.
        if let osx = raw["osx"] as? [String: Any] { task.merge(osx) { _, mac in mac } }
        let type = task["type"] as? String
        let script = task["script"] as? String
        let name = (task["label"] as? String) ?? (task["taskName"] as? String)
            ?? script.map { "npm: \($0)" } ?? "Task \(index + 1)"
        let id = source.path + "#" + name
        let deps: [String] = {
            if let one = task["dependsOn"] as? String { return [one] }
            return (task["dependsOn"] as? [Any] ?? []).compactMap { $0 as? String }
        }()
        let command = stringValue(task["command"])
        let kind: String = switch type {
        case "shell"?, "process"?, nil: deps.isEmpty || command != nil ? "VS Code task" : "Compound"
        case "npm"?: "npm script"
        case let other?: other.prefix(1).uppercased() + other.dropFirst() + " task"
        }
        func refused(_ why: String) -> RunImportCandidate {
            RunImportCandidate(id: id, name: name, kindLabel: kind, source: source, configuration: nil, problem: why)
        }

        let hasOwnWork = command != nil || (type == "npm" && script != nil)
        if !deps.isEmpty {
            if hasOwnWork { return refused("Runs \(RunParsing.list(deps)) before its own command, which Clinic can’t chain.") }
            if deps.count > 1, (task["dependsOrder"] as? String) == "sequence" {
                return refused("Runs its tasks in order; Clinic compounds run them at once.")
            }
            var c = RunImportCandidate(id: id, name: name, kindLabel: kind, source: source,
                                       configuration: RunConfiguration(id: RunConfiguration.makeId(from: name, avoiding: []),
                                                                       name: name, icon: "square.stack", compound: []),
                                       problem: nil)
            c.references = deps
            return c
        }

        let options = task["options"] as? [String: Any] ?? [:]
        var directory = (options["cwd"] as? String).map(workspacePath) ?? "."
        let env = (options["env"] as? [String: Any] ?? [:]).compactMapValues { stringValue($0) }.mapValues(workspaceText)
        let line: String
        switch type {
        case "shell"?, "process"?, nil:
            guard let command, !command.isEmpty else { return refused("Has no command.") }
            let args = (task["args"] as? [Any] ?? []).compactMap(stringValue).map(workspaceText)
            // A shell task's command is already a shell line and VS Code quotes only arguments with
            // spaces; a process task has no shell, so every word is quoted as the shell needs.
            if type == "shell" {
                line = ([workspaceText(command)] + args.map(quoteShellTaskArgument)).joined(separator: " ")
            } else {
                line = ([workspaceText(command)] + args).map(ClaudeLaunch.shellQuote).joined(separator: " ")
            }
        case "npm"?:
            guard let script else { return refused("Has no script.") }
            line = "\(packageManager) run \(ClaudeLaunch.shellQuote(script))"
            if let p = task["path"] as? String, !p.isEmpty { directory = workspacePath(p) }
        default:
            return refused("Not a shell command.")
        }
        if let variable = RunParsing.firstVSCodeVariable(in: [line, directory] + Array(env.values)) {
            return refused("Uses \(variable), which Clinic can’t fill in.")
        }
        let c = RunConfiguration(id: RunConfiguration.makeId(from: name, avoiding: []), name: name,
                                 icon: "terminal",
                                 command: line, directory: directory == "." ? nil : directory, env: env.isEmpty ? nil : env,
                                 device: RunDevicePlatform.inferred(fromCommand: line))
        return RunImportCandidate(id: id, name: name, kindLabel: kind, source: source, configuration: c, problem: nil)
    }

    /// A command, argument or env value: a plain string, or `{ "value": …, "quoting": … }`.
    private static func stringValue(_ any: Any?) -> String? {
        if let s = any as? String { return s }
        if let d = any as? [String: Any] { return stringValue(d["value"]) }
        if let a = any as? [Any] { return a.compactMap { stringValue($0) }.joined(separator: " ") }
        if let n = any as? NSNumber { return n.stringValue }
        return nil
    }

    private static func quoteShellTaskArgument(_ arg: String) -> String {
        guard arg.isEmpty || arg.contains(where: \.isWhitespace) else { return arg }
        return quoteTaskArgument(arg)
    }

    /// `${workspaceFolder}` is the project root, which is where Clinic starts commands.
    static func workspaceText(_ s: String) -> String {
        var out = s
        for v in ["${workspaceFolder}", "${workspaceRoot}"] {
            out = out.replacingOccurrences(of: v + "/", with: "./").replacingOccurrences(of: v, with: ".")
        }
        return out
    }

    static func workspacePath(_ s: String) -> String { RunParsing.normalize(workspaceText(s)) }

    // MARK: Import

    /// `file` with the chosen candidates appended. Ids are made from names and never collide with the
    /// file's own. A compound's members become the ids they were imported as; a member that wasn't
    /// chosen links to an existing configuration of the same name, or is dropped, and a compound left
    /// with no members is skipped.
    public static func importing(_ selected: [RunImportCandidate], into file: RunConfigurationFile) -> RunConfigurationFile {
        var out = file
        var taken = Set(file.configurations.map(\.id))
        var newIds: [String: String] = [:]
        let chosen = selected.filter(\.isImportable)
        for c in chosen where newIds[c.id] == nil {
            let id = RunConfiguration.makeId(from: c.configuration?.name ?? c.name, avoiding: taken)
            taken.insert(id)
            newIds[c.id] = id
        }
        var seen: Set<String> = []
        for c in chosen where seen.insert(c.id).inserted {
            guard var config = c.configuration, let id = newIds[c.id] else { continue }
            config.id = id
            if config.isCompound {
                let names = config.compound ?? []
                let members: [String] = zip(c.memberIds, names).compactMap { memberId, name in
                    newIds[memberId] ?? file.configurations.first { $0.name == name && !$0.isCompound }?.id
                }
                guard !members.isEmpty else { continue }
                config.compound = members
            }
            out.configurations.append(config)
        }
        return out
    }
}
