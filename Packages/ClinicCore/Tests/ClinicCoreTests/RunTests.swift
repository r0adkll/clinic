import Foundation
import Testing
@testable import ClinicCore

/// A scratch project directory, removed by `remove()`.
private struct TempTree {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("run-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func write(_ path: String, _ contents: String = "") throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }

    func mkdir(_ path: String) throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

// MARK: - Model

@Suite struct RunConfigurationFileTests {
    static let sample = """
    {
      "version": 1,
      "default": "desktop",
      "x-owner": { "team": "apps", "tags": [1, true, null, "a"] },
      "configurations": [
        { "id": "desktop", "name": "Desktop", "icon": "desktopcomputer",
          "command": "./gradlew :app:desktop:run", "color": "red" },
        { "id": "android", "name": "Android", "command": "./gradlew installDebug",
          "env": { "ANDROID_SERIAL": "emulator-5554" }, "rerunAfterTurn": true, "directory": "app" },
        { "id": "dev", "name": "Server + Web", "compound": ["desktop", "android"] }
      ]
    }
    """

    @Test func roundTripKeepsUnknownKeys() throws {
        let file = try RunConfigurationFile.decode(Data(Self.sample.utf8))
        #expect(file.defaultId == "desktop")
        #expect(file.extra["x-owner"] == .object(["team": .string("apps"), "tags": .array([.number(1), .bool(true), .null, .string("a")])]))
        #expect(file.configurations[0].extra["color"] == .string("red"))
        #expect(file.configurations[1].env == ["ANDROID_SERIAL": "emulator-5554"])
        #expect(file.configurations[1].reruns)
        #expect(file.configurations[2].isCompound)

        let again = try RunConfigurationFile.decode(try file.encoded())
        #expect(again == file)
        let text = String(decoding: try file.encoded(), as: UTF8.self)
        #expect(text.contains("\"default\" : \"desktop\""))
        #expect(text.contains("\"color\" : \"red\""))
        // Whole numbers stay integers rather than coming back as `1.0`.
        #expect(text.contains("1,") && !text.contains("1.0"))
    }

    @Test func encodedIsStableSortedAndUnescaped() throws {
        let file = try RunConfigurationFile.decode(Data(Self.sample.utf8))
        let a = try file.encoded(), b = try file.encoded()
        #expect(a == b)
        let text = String(decoding: a, as: UTF8.self)
        #expect(text.hasSuffix("}\n"))
        #expect(text.contains("./gradlew"))
        #expect(!text.contains("\\/"))
        let order = ["\"configurations\"", "\"default\"", "\"version\"", "\"x-owner\""].map { text.range(of: $0)!.lowerBound }
        #expect(order == order.sorted())
        // `rerunAfterTurn: false` and an empty env are left out rather than written.
        var plain = RunConfiguration(id: "a", name: "A", command: "true", env: [:], rerunAfterTurn: false)
        plain.extra = [:]
        let one = String(decoding: try RunConfigurationFile(configurations: [plain]).encoded(), as: UTF8.self)
        #expect(!one.contains("rerunAfterTurn") && !one.contains("env"))
    }

    @Test func decodeErrorsAreReadable() {
        #expect(throws: RunConfigurationError.self) { try RunConfigurationFile.decode(Data("{".utf8)) }
        do {
            _ = try RunConfigurationFile.decode(Data(#"{"configurations": [{"id": 1, "name": "x"}]}"#.utf8))
            Issue.record("expected a throw")
        } catch let error as RunConfigurationError {
            #expect(error.description.hasPrefix("run.json could not be read: "))
            #expect(error.description.contains("configurations[0].id"))
        } catch {
            Issue.record("unexpected \(error)")
        }
        // A missing name falls back to the id; a missing configurations list is empty.
        let file = try? RunConfigurationFile.decode(Data(#"{"configurations": [{"id": "x", "command": "ls"}]}"#.utf8))
        #expect(file?.configurations.first?.name == "x")
        #expect((try? RunConfigurationFile.decode(Data("{}".utf8)))?.configurations == [])
    }

    @Test func membersExpandCompoundsAndSkipUnknownAndNested() {
        let a = RunConfiguration(id: "a", name: "A", command: "a")
        let b = RunConfiguration(id: "b", name: "B", command: "b")
        let inner = RunConfiguration(id: "inner", name: "Inner", compound: ["a"])
        let outer = RunConfiguration(id: "outer", name: "Outer", compound: ["b", "missing", "inner", "a"])
        let file = RunConfigurationFile(configurations: [a, b, inner, outer])
        #expect(file.members(of: outer).map(\.id) == ["b", "a"])
        #expect(file.members(of: a) == [a])
        #expect(RunConfiguration(id: "e", name: "E", compound: []).isRunnable == false)
        #expect(RunConfiguration(id: "e", name: "E", command: "  ").isRunnable == false)
        #expect(outer.symbol == "play.fill")
    }

    @Test func makeIdSlugsAndAvoidsCollisions() {
        #expect(RunConfiguration.makeId(from: "Android (alpha)", avoiding: []) == "android-alpha")
        #expect(RunConfiguration.makeId(from: "host [jvm, hot] 🔥", avoiding: []) == "host-jvm-hot")
        #expect(RunConfiguration.makeId(from: "Desktop", avoiding: ["desktop", "desktop-2"]) == "desktop-3")
        #expect(RunConfiguration.makeId(from: "!!!", avoiding: []) == "run")
    }
}

@Suite struct RunCheckoutTests {
    let project = "/Users/me/proj"

    @Test func rootForCwd() {
        #expect(RunCheckout.root(forCwd: project, projectPath: project) == project)
        #expect(RunCheckout.root(forCwd: project + "/src/app", projectPath: project) == project)
        #expect(RunCheckout.root(forCwd: project + "/.claude/worktrees/feat", projectPath: project) == project + "/.claude/worktrees/feat")
        #expect(RunCheckout.root(forCwd: project + "/.claude/worktrees/feat/src", projectPath: project) == project + "/.claude/worktrees/feat")
        #expect(RunCheckout.root(forCwd: project + "/.claude/worktrees/", projectPath: project) == project)
        #expect(RunCheckout.root(forCwd: "/Users/me/other/.claude/worktrees/x", projectPath: project) == project)
    }

    @Test func worktreeName() {
        #expect(RunCheckout.worktreeName(checkout: project + "/.claude/worktrees/feat", projectPath: project) == "feat")
        #expect(RunCheckout.worktreeName(checkout: project, projectPath: project) == nil)
    }

    @Test func fileURLPrefersTheCheckoutsOwn() {
        let worktree = project + "/.claude/worktrees/feat"
        let own = worktree + "/.clinic/run.json"
        let rootFile = project + "/.clinic/run.json"
        #expect(RunCheckout.fileURL(checkout: worktree, projectPath: project, exists: { $0 == own }).path == own)
        #expect(RunCheckout.fileURL(checkout: worktree, projectPath: project, exists: { _ in false }).path == rootFile)
        #expect(RunCheckout.fileURL(checkout: project, projectPath: project, exists: { _ in true }).path == rootFile)
    }

    @Test func workingDirectory() {
        func dir(_ d: String?) -> String { RunCheckout.workingDirectory(for: RunConfiguration(id: "x", name: "x", command: "ls", directory: d), checkout: project) }
        #expect(dir(nil) == project)
        #expect(dir(".") == project)
        #expect(dir("  ") == project)
        #expect(dir("app/web") == project + "/app/web")
        #expect(dir("../sibling") == "/Users/me/sibling")
        #expect(dir("/abs/path") == "/abs/path")
        #expect(dir("~/x") == FileManager.default.homeDirectoryForCurrentUser.path + "/x")
    }
}

@Suite struct RunLaunchTests {
    @Test func surfaceCommandQuotesTheWholeLine() throws {
        let command = #"echo 'it''s' && echo $(printf ok) "$HOME""#
        let status = FileManager.default.temporaryDirectory.appendingPathComponent("run-\(UUID().uuidString).status").path
        defer { try? FileManager.default.removeItem(atPath: status) }
        let line = RunLaunch.surfaceCommand(shell: "/bin/zsh", command: command, statusFile: status)
        #expect(line.hasPrefix("/bin/sh -c '"))
        #expect(!line.contains("-c echo"))

        // Through `/bin/sh -c`, as libghostty runs it, the "shell" (echo here) receives exactly the command.
        let echo = Process()
        echo.executableURL = URL(fileURLWithPath: "/bin/sh")
        echo.arguments = ["-c", RunLaunch.surfaceCommand(shell: "/bin/echo", command: command, statusFile: status)]
        let echoOut = Pipe()
        echo.standardOutput = echoOut
        try echo.run()
        echo.waitUntilExit()
        let printed = String(decoding: echoOut.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(printed == "-l -i -c \(command)\n")
        #expect(RunLaunch.recordedExitCode(at: status) == 0)
    }

    /// The code comes from the wrapper's file, and the wrapper exits with it too.
    @Test func wrapperRecordsTheCommandsExitCode() throws {
        let status = FileManager.default.temporaryDirectory.appendingPathComponent("run-\(UUID().uuidString).status").path
        defer { try? FileManager.default.removeItem(atPath: status) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", RunLaunch.surfaceCommand(shell: "/bin/sh", command: "echo failing; exit 7", statusFile: status)]
        p.standardOutput = Pipe()
        try p.run()
        p.waitUntilExit()
        #expect(p.terminationStatus == 7)
        #expect(RunLaunch.recordedExitCode(at: status) == 7)
        #expect(RunLaunch.recordedExitCode(at: status + ".missing") == nil)
    }

    @Test func environmentLayersConfigEnvOverMarkers() {
        let env = RunLaunch.environment(for: RunConfiguration(id: "desk", name: "D", command: "x", env: ["A": "1", "CLINIC_RUN": "mine"]))
        #expect(env["CLINIC"] == "1")
        #expect(env["A"] == "1")
        #expect(env["CLINIC_RUN"] == "mine")
        #expect(RunLaunch.environment(for: RunConfiguration(id: "desk", name: "D", command: "x"))["CLINIC_RUN"] == "desk")
    }
}

@Suite struct RunStatusTests {
    @Test func finished() {
        #expect(RunStatus.finished(exitCode: 0, stoppedByUser: false, duration: 3) == .succeeded(duration: 3))
        #expect(RunStatus.finished(exitCode: 1, stoppedByUser: false, duration: 3) == .failed(exitCode: 1, duration: 3))
        #expect(RunStatus.finished(exitCode: nil, stoppedByUser: false, duration: 3) == .failed(exitCode: nil, duration: 3))
        #expect(RunStatus.finished(exitCode: 130, stoppedByUser: true, duration: 3) == .stopped(duration: 3))
        #expect(RunStatus.finished(exitCode: 0, stoppedByUser: true, duration: 3) == .stopped(duration: 3))
        #expect(RunStatus.running(since: .now).isRunning)
        #expect(RunStatus.failed(exitCode: 2, duration: 1).isFailure)
        #expect(!RunStatus.stopped(duration: 1).isFailure)
    }

    @Test func clockAndDuration() {
        #expect(RunStatus.clock(0) == "0:00")
        #expect(RunStatus.clock(42) == "0:42")
        #expect(RunStatus.clock(725) == "12:05")
        #expect(RunStatus.clock(3729) == "1:02:09")
        #expect(RunStatus.clock(-5) == "0:00")
        #expect(RunStatus.duration(38) == "38 s")
        #expect(RunStatus.duration(120) == "2 min")
        #expect(RunStatus.duration(124) == "2 min 4 s")
        #expect(RunStatus.duration(3600) == "1 h")
        #expect(RunStatus.duration(3780) == "1 h 3 min")
    }
}

@Suite struct RunTrustAndPromptTests {
    @Test func fingerprintCoversCommandDirectoryAndEnv() {
        let base = RunConfiguration(id: "a", name: "A", command: "make run", env: ["A": "1", "B": "2"])
        var renamed = base; renamed.name = "Renamed"; renamed.id = "b"; renamed.icon = "globe"
        #expect(RunTrust.fingerprint(base) == RunTrust.fingerprint(renamed))
        var other = base; other.command = "make run2"
        #expect(RunTrust.fingerprint(base) != RunTrust.fingerprint(other))
        var moved = base; moved.directory = "web"
        #expect(RunTrust.fingerprint(base) != RunTrust.fingerprint(moved))
        var dotted = base; dotted.directory = "."
        #expect(RunTrust.fingerprint(base) == RunTrust.fingerprint(dotted))
        var envChanged = base; envChanged.env = ["A": "1", "B": "3"]
        #expect(RunTrust.fingerprint(base) != RunTrust.fingerprint(envChanged))
        var reordered = RunConfiguration(id: "a", name: "A", command: "make run", env: [:])
        reordered.env?["B"] = "2"; reordered.env?["A"] = "1"
        #expect(RunTrust.fingerprint(base) == RunTrust.fingerprint(reordered))
        #expect(RunTrust.fingerprint(base).count == 64)

        let compound = RunConfiguration(id: "c", name: "C", compound: ["a", "o"])
        var o = other; o.id = "o"
        let file = RunConfigurationFile(configurations: [base, o, compound])
        #expect(RunTrust.fingerprints(for: compound, in: file) == [RunTrust.fingerprint(base), RunTrust.fingerprint(o)])
    }

    @Test func tailDropsTrailingBlankLinesAndKeepsTheLastN() {
        #expect(RunPrompts.tail("a\nb\nc\n\n   \n", lines: 2) == "b\nc")
        #expect(RunPrompts.tail("a\r\nb\r\n", lines: 5) == "a\nb")
        #expect(RunPrompts.tail("a\nb", lines: 0) == "")
        #expect(RunPrompts.tail("\n\n", lines: 3) == "")
    }

    @Test func fixPromptCarriesCommandCodeAndOutput() {
        let prompt = RunPrompts.fix(name: "Desktop", command: "./gradlew :app:desktop:run", exitCode: 1, output: "one\ntwo\nBUILD FAILED\n\n")
        #expect(prompt.contains("“Desktop” failed with exit code 1"))
        #expect(prompt.contains("`./gradlew :app:desktop:run`"))
        #expect(prompt.contains("The last 3 lines"))
        #expect(prompt.contains("BUILD FAILED\n```"))
        #expect(prompt.hasSuffix("Find the cause and fix it."))
        #expect(RunPrompts.fix(name: "x", command: "y", exitCode: nil, output: "").contains("an unknown exit code"))
        #expect(RunPrompts.setUp.contains(".clinic/run.json"))
    }
}

// MARK: - Import

private func xml(_ configuration: String) -> Data {
    Data("<component name=\"ProjectRunConfigurationManager\">\n\(configuration)\n</component>".utf8)
}

private let gradleHot = xml("""
  <configuration default="false" name="host [jvm, hot] 🔥" type="GradleRunConfiguration" factoryName="Gradle">
    <ExternalSystemSettings>
      <option name="executionName" />
      <option name="externalProjectPath" value="$PROJECT_DIR$/host" />
      <option name="externalSystemIdString" value="GRADLE" />
      <option name="scriptParameters" value="" />
      <option name="taskDescriptions"><list /></option>
      <option name="taskNames">
        <list>
          <option value="hotRunJvm" />
          <option value="--mainClass" />
          <option value="&quot;com.livewire.MainKt&quot;" />
        </list>
      </option>
      <option name="vmOptions" />
    </ExternalSystemSettings>
    <method v="2" />
  </configuration>
""")

private let shDemo = xml("""
  <configuration default="false" name="demo [jvm]" type="ShConfigurationType">
    <option name="SCRIPT_TEXT" value="./gradlew :demo:desktop:run" />
    <option name="INDEPENDENT_SCRIPT_PATH" value="true" />
    <option name="SCRIPT_PATH" value="" />
    <option name="SCRIPT_OPTIONS" value="" />
    <option name="SCRIPT_WORKING_DIRECTORY" value="$PROJECT_DIR$" />
    <option name="INTERPRETER_PATH" value="/bin/bash" />
    <option name="EXECUTE_SCRIPT_FILE" value="false" />
    <envs />
    <method v="2" />
  </configuration>
""")

private let androidDemo = xml("""
  <configuration default="false" name="demo" type="AndroidRunConfigurationType" factoryName="Android App">
    <module name="livewire.demo.android" />
    <option name="DEPLOY" value="true" />
    <method v="2" />
  </configuration>
""")

private let androidPlusHost = xml("""
  <configuration default="false" name="Android + Host" type="CompoundRunConfigurationType">
    <toRun name="demo" type="AndroidRunConfigurationType" />
    <toRun name="host [jvm, hot] 🔥" type="GradleRunConfiguration" />
    <method v="2" />
  </configuration>
""")

private let desktopPlusHost = xml("""
  <configuration default="false" name="Desktop + Host" type="CompoundRunConfigurationType">
    <toRun name="host [jvm, hot] 🔥" type="GradleRunConfiguration" />
    <toRun name="demo [jvm]" type="ShConfigurationType" />
    <method v="2" />
  </configuration>
""")

@Suite struct JetBrainsImportTests {
    private func one(_ data: Data, wrappers: Set<String> = ["."], projectDir: String = ".") throws -> RunImportCandidate {
        let all = RunImporter.jetBrains(xml: data, path: ".run/x.run.xml", projectDir: projectDir, gradleWrappers: wrappers)
        try #require(all.count == 1)
        return all[0]
    }

    @Test func gradleModuleRunsThroughTheRootWrapper() throws {
        let c = try one(gradleHot)
        #expect(c.kindLabel == "Gradle")
        #expect(c.source == .init(format: .jetBrains, path: ".run/x.run.xml"))
        #expect(c.id == ".run/x.run.xml#host [jvm, hot] 🔥")
        #expect(c.configuration?.command == #"./gradlew -p host hotRunJvm --mainClass "com.livewire.MainKt""#)
        #expect(c.configuration?.directory == nil)
        #expect(c.problem == nil && c.defaultSelected)
    }

    @Test func gradleWithoutAWrapperOrWithItsOwn() throws {
        let bare = try one(gradleHot, wrappers: [])
        #expect(bare.configuration?.command == #"gradle hotRunJvm --mainClass "com.livewire.MainKt""#)
        #expect(bare.configuration?.directory == "host")
        let own = try one(gradleHot, wrappers: ["host"])
        #expect(own.configuration?.command == #"./gradlew hotRunJvm --mainClass "com.livewire.MainKt""#)
        #expect(own.configuration?.directory == "host")
    }

    @Test func gradleRootTasksParametersEnvAndQuoting() throws {
        let c = try one(xml("""
          <configuration name="Run IDE" type="GradleRunConfiguration" factoryName="Gradle">
            <ExternalSystemSettings>
              <option name="env"><map><entry key="JAVA_OPTS" value="-Xmx2g" /></map></option>
              <option name="externalProjectPath" value="$PROJECT_DIR$" />
              <option name="scriptParameters" value="--info -Pflag=1" />
              <option name="taskNames"><list><option value=":plugin:runIde" /><option value="my task" /></list></option>
            </ExternalSystemSettings>
          </configuration>
        """))
        #expect(c.configuration?.command == "./gradlew :plugin:runIde 'my task' --info -Pflag=1")
        #expect(c.configuration?.env == ["JAVA_OPTS": "-Xmx2g"])
        #expect(c.configuration?.symbol == "hammer")
        // A project in a subdirectory (its own IDE project) keeps its own directory.
        let sub = try one(xml("""
          <configuration name="Run IDE" type="GradleRunConfiguration">
            <ExternalSystemSettings>
              <option name="externalProjectPath" value="$PROJECT_DIR$" />
              <option name="taskNames"><list><option value="runIde" /></list></option>
            </ExternalSystemSettings>
          </configuration>
        """), wrappers: ["intellij-plugin"], projectDir: "intellij-plugin")
        #expect(sub.configuration?.command == "./gradlew runIde")
        #expect(sub.configuration?.directory == "intellij-plugin")
    }

    @Test func gradleWithoutTasksIsRefused() throws {
        let c = try one(xml(#"<configuration name="Empty" type="GradleRunConfiguration"><ExternalSystemSettings /></configuration>"#))
        #expect(c.configuration == nil)
        #expect(c.problem == "Has no Gradle tasks.")
    }

    @Test func shellScriptText() throws {
        let c = try one(shDemo)
        #expect(c.kindLabel == "Shell script")
        #expect(c.configuration?.command == "./gradlew :demo:desktop:run")
        #expect(c.configuration?.directory == nil)
        #expect(c.configuration?.symbol == "terminal")
    }

    @Test func shellScriptFileInAWorkingDirectory() throws {
        let c = try one(xml("""
          <configuration name="Serve" type="ShConfigurationType">
            <option name="SCRIPT_PATH" value="$PROJECT_DIR$/scripts/dev.sh" />
            <option name="SCRIPT_OPTIONS" value="--port 8080" />
            <option name="SCRIPT_WORKING_DIRECTORY" value="$PROJECT_DIR$/web" />
            <option name="INTERPRETER_PATH" value="/bin/bash" />
            <option name="EXECUTE_SCRIPT_FILE" value="true" />
            <envs><env name="PORT" value="8080" /></envs>
          </configuration>
        """))
        #expect(c.configuration?.command == "/bin/bash ../scripts/dev.sh --port 8080")
        #expect(c.configuration?.directory == "web")
        #expect(c.configuration?.env == ["PORT": "8080"])
    }

    @Test func projectDirInScriptTextBecomesTheRoot() throws {
        let c = try one(xml("""
          <configuration name="Readme" type="ShConfigurationType">
            <option name="SCRIPT_TEXT" value="cat $PROJECT_DIR$/README.md" />
            <option name="SCRIPT_WORKING_DIRECTORY" value="$PROJECT_DIR$" />
            <option name="EXECUTE_SCRIPT_FILE" value="false" />
          </configuration>
        """))
        #expect(c.configuration?.command == "cat ./README.md")
    }

    @Test func otherMacrosAreRefusedByName() throws {
        let c = try one(xml("""
          <configuration name="Module" type="ShConfigurationType">
            <option name="SCRIPT_TEXT" value="$MODULE_DIR$/run.sh" />
            <option name="EXECUTE_SCRIPT_FILE" value="false" />
          </configuration>
        """))
        #expect(c.configuration == nil)
        #expect(c.problem == "Uses $MODULE_DIR$, which Clinic can’t fill in.")
        #expect(!c.defaultSelected)
    }

    @Test func typesThatNameSomethingElseAreListedWithTheirReason() throws {
        let android = try one(androidDemo)
        #expect(android.kindLabel == "Android app")
        #expect(android.problem == "Names a module, not a command. Set Up with Claude can write one.")
        #expect(android.configuration == nil && !android.defaultSelected)

        let app = try one(xml(#"<configuration name="desktop" type="Application" factoryName="Application"><option name="MAIN_CLASS_NAME" value="app.MainKt" /></configuration>"#))
        #expect(app.kindLabel == "Application")
        #expect(app.problem?.hasPrefix("Names a main class") == true)

        let kmm = try one(xml(#"<configuration name="iosApp" type="KmmRunConfiguration" factoryName="iOS Application" XCODE_PROJECT="$PROJECT_DIR$/app/ios/iosApp.xcodeproj" XCODE_SCHEME="iosApp" />"#))
        #expect(kmm.kindLabel == "Kotlin Multiplatform")
        #expect(kmm.problem?.hasPrefix("Names an Xcode scheme") == true)

        let junit = try one(xml(#"<configuration name="Tests" type="JUnit" factoryName="JUnit" />"#))
        #expect(junit.kindLabel == "JUnit")
        #expect(junit.problem == "Not a shell command.")
    }

    @Test func templatesAreSkippedAndBadXMLSaysSo() {
        let templates = RunImporter.jetBrains(xml: xml(#"<configuration default="true" type="ShConfigurationType" name="t" />"#), path: ".run/t.run.xml")
        #expect(templates.isEmpty)
        let bad = RunImporter.jetBrains(xml: Data("<component><configuration".utf8), path: ".run/bad.run.xml")
        #expect(bad.count == 1)
        #expect(bad[0].problem == "The file isn’t valid XML.")
        #expect(bad[0].name == "bad.run.xml")
    }

    private func livewire() -> [RunImportCandidate] {
        let files: [(String, Data)] = [("Android + Host.run.xml", androidPlusHost), ("demo [jvm].run.xml", shDemo),
                                       ("demo.run.xml", androidDemo), ("Desktop + Host.run.xml", desktopPlusHost),
                                       ("host [jvm, hot] 🔥.run.xml", gradleHot)]
        return RunImporter.resolvingCompounds(files.flatMap { RunImporter.jetBrains(xml: $1, path: ".run/" + $0) })
    }

    @Test func compoundsLinkMembersAcrossFiles() throws {
        let all = livewire()
        let desktop = try #require(all.first { $0.name == "Desktop + Host" })
        #expect(desktop.kindLabel == "Compound")
        #expect(desktop.problem == nil && desktop.defaultSelected)
        #expect(desktop.configuration?.compound == ["host [jvm, hot] 🔥", "demo [jvm]"])
        #expect(desktop.memberIds == [".run/host [jvm, hot] 🔥.run.xml#host [jvm, hot] 🔥", ".run/demo [jvm].run.xml#demo [jvm]"])
    }

    @Test func compoundMissingAMemberImportsWithTheRest() throws {
        let android = try #require(livewire().first { $0.name == "Android + Host" })
        #expect(android.problem == "Needs demo, which can’t be imported. Imports as host [jvm, hot] 🔥 alone.")
        #expect(!android.defaultSelected)
        #expect(android.configuration?.compound == ["host [jvm, hot] 🔥"])
        #expect(android.memberIds.count == 1)
    }

    @Test func compoundWithNothingImportableAndNestedCompounds() throws {
        let gone = RunImporter.resolvingCompounds(
            RunImporter.jetBrains(xml: androidPlusHost, path: ".run/a.run.xml") + RunImporter.jetBrains(xml: androidDemo, path: ".run/d.run.xml"))
        let compound = try #require(gone.first { $0.name == "Android + Host" })
        #expect(compound.configuration == nil)
        #expect(compound.problem == "Needs demo and host [jvm, hot] 🔥, which can’t be imported.")

        let outer = xml("""
          <configuration name="Everything" type="CompoundRunConfigurationType">
            <toRun name="Desktop + Host" type="CompoundRunConfigurationType" />
            <toRun name="demo [jvm]" type="ShConfigurationType" />
          </configuration>
        """)
        let files: [(String, Data)] = [("demo [jvm].run.xml", shDemo), ("host.run.xml", gradleHot),
                                       ("Desktop + Host.run.xml", desktopPlusHost), ("Everything.run.xml", outer)]
        let all = RunImporter.resolvingCompounds(files.flatMap { RunImporter.jetBrains(xml: $1, path: ".run/" + $0) })
        let everything = try #require(all.first { $0.name == "Everything" })
        #expect(everything.configuration?.compound == ["host [jvm, hot] 🔥", "demo [jvm]"])
        #expect(everything.problem == nil)
    }

    @Test func importingMakesIdsAndRewritesCompoundMembers() throws {
        let all = livewire()
        var existing = RunConfiguration(id: "host-jvm-hot", name: "Something else", command: "true")
        existing.extra = ["keep": .bool(true)]
        let file = RunConfigurationFile(defaultId: "host-jvm-hot", configurations: [existing])
        let chosen = all.filter { $0.defaultSelected }
        #expect(chosen.map(\.name) == ["demo [jvm]", "Desktop + Host", "host [jvm, hot] 🔥"])

        let out = RunImporter.importing(chosen, into: file)
        #expect(out.defaultId == "host-jvm-hot")
        #expect(out.configurations.map(\.id) == ["host-jvm-hot", "demo-jvm", "desktop-host", "host-jvm-hot-2"])
        #expect(out.configurations[0] == existing)
        #expect(out.configuration("desktop-host")?.compound == ["host-jvm-hot-2", "demo-jvm"])
        #expect(out.members(of: out.configuration("desktop-host")!).map(\.id) == ["host-jvm-hot-2", "demo-jvm"])
        // Refused candidates are never written, even when passed in.
        #expect(RunImporter.importing(all.filter { !$0.isImportable }, into: file) == file)
    }

    @Test func importingACompoundWithoutItsMembers() throws {
        let all = livewire()
        let compound = try #require(all.first { $0.name == "Desktop + Host" })
        // Nothing to link to: the compound is skipped.
        #expect(RunImporter.importing([compound], into: RunConfigurationFile()).configurations.isEmpty)
        // A configuration of the same name already in the file stands in for an unchosen member.
        let host = RunConfiguration(id: "host", name: "host [jvm, hot] 🔥", command: "./gradlew hotRunJvm")
        let out = RunImporter.importing([compound], into: RunConfigurationFile(configurations: [host]))
        #expect(out.configuration("desktop-host")?.compound == ["host"])
    }
}

@Suite struct VSCodeImportTests {
    private func tasks(_ body: String, packageManager: String = "npm") -> [RunImportCandidate] {
        RunImporter.vsCode(tasksJSON: Data(body.utf8), packageManager: packageManager)
    }

    @Test func jsoncCommentsAndTrailingCommas() throws {
        let all = tasks("""
        // Top comment
        {
          "version": "2.0.0", /* inline */
          "tasks": [
            {
              "label": "open", // trailing
              "type": "shell",
              "command": "open http://localhost:3000/*not-a-comment*/", /* multi
              line */
              "args": ["--a,]", ],
            },
          ],
        }
        """)
        let c = try #require(all.first)
        #expect(c.configuration?.command == "open http://localhost:3000/*not-a-comment*/ --a,]")
        #expect(c.kindLabel == "VS Code task")
        #expect(c.source == .init(format: .vsCode, path: ".vscode/tasks.json"))
        #expect(c.id == ".vscode/tasks.json#open")
        #expect(String(decoding: RunParsing.stripJSONC(Data(#"{"a": "x\"//y", }"#.utf8)), as: UTF8.self) == #"{"a": "x\"//y" }"#)
    }

    @Test func shellAndProcessQuoting() {
        let all = tasks("""
        { "version": "2.0.0", "tasks": [
          { "label": "greet", "type": "shell", "command": "echo $HOME &&", "args": ["hello world", "--x=$PWD"] },
          { "label": "proc", "type": "process", "command": "/usr/bin/env", "args": ["FOO=1", "my app", "it's"] },
          { "label": "quoted", "type": "shell", "command": "run", "args": [{ "value": "a b", "quoting": "strong" }] }
        ] }
        """)
        #expect(all[0].configuration?.command == "echo $HOME && 'hello world' --x=$PWD")
        #expect(all[1].configuration?.command == #"/usr/bin/env FOO=1 'my app' 'it'\''s'"#)
        #expect(all[2].configuration?.command == "run 'a b'")
    }

    @Test func workspaceFolderAndOtherVariables() {
        let all = tasks("""
        { "version": "2.0.0", "tasks": [
          { "label": "dev", "type": "shell", "command": "${workspaceFolder}/scripts/dev.sh",
            "options": { "cwd": "${workspaceFolder}/web", "env": { "ROOT": "${workspaceFolder}", "HOME_DIR": "${HOME}" } } },
          { "label": "root", "type": "shell", "command": "ls", "options": { "cwd": "${workspaceFolder}" } },
          { "label": "file", "type": "shell", "command": "cat ${file}" },
          { "label": "env", "type": "shell", "command": "echo ${env:HOME}" }
        ] }
        """)
        #expect(all[0].configuration?.command == "./scripts/dev.sh")
        #expect(all[0].configuration?.directory == "web")
        #expect(all[0].configuration?.env == ["ROOT": ".", "HOME_DIR": "${HOME}"])
        #expect(all[1].configuration?.directory == nil)
        #expect(all[2].configuration == nil)
        #expect(all[2].problem == "Uses ${file}, which Clinic can’t fill in.")
        #expect(all[3].problem == "Uses ${env:HOME}, which Clinic can’t fill in.")
    }

    @Test func parallelDependsOnIsACompoundAndSequenceIsRefused() throws {
        let all = tasks("""
        { "version": "2.0.0", "tasks": [
          { "label": "dev", "dependsOn": ["dev: server", "dev: web"], "dependsOrder": "parallel", "problemMatcher": [] },
          { "label": "both", "dependsOn": ["dev: server", "dev: web"] },
          { "label": "ordered", "dependsOn": ["dev: server", "dev: web"], "dependsOrder": "sequence" },
          { "label": "chained", "type": "shell", "command": "echo done", "dependsOn": "dev: web" },
          { "label": "dev: server", "type": "shell", "command": "./scripts/dev-server.sh", "isBackground": true },
          { "label": "dev: web", "type": "shell", "command": "./scripts/dev-web.sh", "isBackground": true },
        ] }
        """)
        let dev = try #require(all.first { $0.name == "dev" })
        #expect(dev.kindLabel == "Compound")
        #expect(dev.configuration?.compound == ["dev: server", "dev: web"])
        #expect(dev.memberIds == [".vscode/tasks.json#dev: server", ".vscode/tasks.json#dev: web"])
        #expect(dev.defaultSelected)
        #expect(all.first { $0.name == "both" }?.configuration?.isCompound == true)
        let ordered = try #require(all.first { $0.name == "ordered" })
        #expect(ordered.configuration == nil)
        #expect(ordered.problem == "Runs its tasks in order; Clinic compounds run them at once.")
        #expect(all.first { $0.name == "chained" }?.configuration == nil)

        let file = RunImporter.importing(all.filter(\.defaultSelected), into: RunConfigurationFile())
        #expect(file.configuration("dev")?.compound == ["dev-server", "dev-web"])
    }

    @Test func npmOsxOverridesAndOtherTypes() {
        let all = tasks("""
        { "version": "2.0.0", "tasks": [
          { "type": "npm", "script": "dev", "path": "web" },
          { "label": "mac", "type": "shell", "command": "xdg-open .", "osx": { "command": "open ." } },
          { "label": "build", "type": "gradle", "task": "build" },
          { "label": "nothing", "type": "shell" }
        ] }
        """, packageManager: "pnpm")
        #expect(all[0].name == "npm: dev")
        #expect(all[0].kindLabel == "npm script")
        #expect(all[0].configuration?.command == "pnpm run dev")
        #expect(all[0].configuration?.directory == "web")
        #expect(all[1].configuration?.command == "open .")
        #expect(all[2].configuration == nil)
        #expect(all[2].problem == "Not a shell command.")
        #expect(all[2].kindLabel == "Gradle task")
        #expect(all[3].problem == "Has no command.")
    }

    @Test func unreadableFileSaysSo() {
        let all = tasks("{ nope")
        #expect(all.count == 1)
        #expect(all[0].problem == "The file isn’t valid JSON.")
    }

    @Test func candidatesReadEveryLocation() throws {
        let tree = try TempTree()
        defer { tree.remove() }
        try tree.write("gradlew")
        try tree.write(".run/host [jvm, hot] 🔥.run.xml", String(decoding: gradleHot, as: UTF8.self))
        try tree.write(".idea/runConfigurations/demo.xml", String(decoding: androidDemo, as: UTF8.self))
        try tree.write(".run/Android + Host.run.xml", String(decoding: androidPlusHost, as: UTF8.self))
        try tree.write("intellij-plugin/settings.gradle.kts")
        try tree.write("intellij-plugin/gradlew")
        try tree.write("intellij-plugin/.run/Run IDE.run.xml", String(decoding: xml("""
          <configuration name="Run IDE" type="GradleRunConfiguration">
            <ExternalSystemSettings>
              <option name="externalProjectPath" value="$PROJECT_DIR$" />
              <option name="taskNames"><list><option value="runIde" /></list></option>
            </ExternalSystemSettings>
          </configuration>
        """), as: UTF8.self))
        try tree.write("yarn.lock")
        try tree.write(".vscode/tasks.json", #"{ "version": "2.0.0", "tasks": [ { "type": "npm", "script": "web" }, ] }"#)

        #expect(RunImporter.hasSources(in: tree.root))
        let all = RunImporter.candidates(in: tree.root)
        #expect(all.map(\.name) == ["Android + Host", "host [jvm, hot] 🔥", "demo", "Run IDE", "npm: web"])
        #expect(all[0].problem == "Needs demo, which can’t be imported. Imports as host [jvm, hot] 🔥 alone.")
        #expect(all[1].configuration?.command == #"./gradlew -p host hotRunJvm --mainClass "com.livewire.MainKt""#)
        #expect(all[3].configuration?.command == "./gradlew runIde")
        #expect(all[3].configuration?.directory == "intellij-plugin")
        #expect(all[3].source.path == "intellij-plugin/.run/Run IDE.run.xml")
        #expect(all[4].configuration?.command == "yarn run web")

        let empty = try TempTree()
        defer { empty.remove() }
        #expect(!RunImporter.hasSources(in: empty.root))
        #expect(RunImporter.candidates(in: empty.root).isEmpty)
    }
}

// MARK: - Detection

@Suite struct RunDetectorScriptTests {
    @Test func makeTargets() {
        let makefile = """
        .PHONY: setup build test
        CC := clang
        PREFIX ?= /usr/local
        FLAGS = -a:b
        export PATH := $(PATH):/x

        setup:
        \tbrew install xcodegen

        build: project # regenerate first
        \txcodebuild build | tail -20
        test lint: build
        \tswift test
        %.o: %.c
        \t$(CC) -c $<
        out/app.o: app.c
        debug: CFLAGS += -g
        $(BIN): main.o
        define RECIPE
        inner: thing
        endef
        long-name_2: a \\
          b: c
        _private:
        build:
        """
        let targets = RunDetector.makeTargets(makefile: makefile)
        #expect(targets.map(\.name) == ["setup", "build", "test", "lint", "long-name_2", "_private"])
        #expect(targets[1].command == "make build")
        #expect(targets[1].id == "build")
        #expect(targets[1].symbol == "terminal")
    }

    @Test func packageScriptsKeepTheirOrderAndSkipHooks() {
        let json = #"{ "name": "x", "scripts": { "dev": "vite", "prebuild": "rm -rf dist", "build": "vite build", "test:unit": "vitest", "postinstall": "patch" } }"#
        let scripts = RunDetector.packageScripts(packageJSON: Data(json.utf8), packageManager: "bun")
        #expect(scripts.map(\.name) == ["dev", "build", "test:unit", "postinstall"])
        #expect(scripts.map(\.command) == ["bun run dev", "bun run build", "bun run test:unit", "bun run postinstall"])
        #expect(RunDetector.packageScripts(packageJSON: Data("{}".utf8), packageManager: "npm").isEmpty)
        #expect(RunDetector.packageScripts(packageJSON: Data(#"{"scripts": {"a b": "x"}}"#.utf8), packageManager: "npm").first?.command == "npm run 'a b'")
    }

    @Test func packageManagerFollowsTheLockfile() throws {
        for (lock, pm) in [("pnpm-lock.yaml", "pnpm"), ("yarn.lock", "yarn"), ("bun.lockb", "bun"), ("bun.lock", "bun"), ("package-lock.json", "npm")] {
            let tree = try TempTree()
            defer { tree.remove() }
            try tree.write("package.json", #"{"scripts": {"dev": "vite"}}"#)
            try tree.write(lock)
            #expect(RunDetector.packageManager(in: tree.root) == pm)
            #expect(RunDetector.detect(in: tree.root).map(\.command) == ["\(pm) run dev"])
        }
    }

    @Test func swiftExecutables() {
        let manifest = """
        let package = Package(name: "Tools", targets: [
            .executableTarget(name: "clinic-hook", dependencies: []),
            // .executableTarget(name: "commented-out"),
            .executableTarget(
                name: "Wake"
            ),
            .target(name: "Core"),
        ])
        """
        let found = RunDetector.swiftExecutables(packageSwift: manifest)
        #expect(found.map(\.command) == ["swift run clinic-hook", "swift run Wake"])
        #expect(found.map(\.symbol) == ["play.fill", "play.fill"])
    }

    @Test func cargoPackageAndWorkspace() throws {
        let tree = try TempTree()
        defer { tree.remove() }
        try tree.write("Cargo.toml", """
        [workspace]
        resolver = "2"
        members = [
          "crates/*", # every crate
          "xtask",
        ]

        [workspace.package]
        name = "not-a-package"
        """)
        try tree.write("crates/cli/Cargo.toml", "[package]\nname = \"my-cli\"\n\n[[bin]]\nname = \"mine\"\npath = \"src/main.rs\"\n")
        try tree.write("crates/cli/src/main.rs")
        try tree.write("crates/lib/Cargo.toml", "[package]\nname = \"my-lib\"\n")
        try tree.write("crates/lib/src/lib.rs")
        try tree.write("crates/multi/Cargo.toml", "[package]\nname = \"multi\"\n")
        try tree.write("crates/multi/src/main.rs")
        try tree.write("crates/multi/src/bin/extra.rs")
        try tree.write("xtask/Cargo.toml", "[package]\nname = \"xtask\" # tasks\ndefault-run = \"xtask\"\n[[bin]]\nname = \"other\"\n")
        try tree.write("xtask/src/main.rs")

        let found = RunDetector.cargo(in: tree.root)
        #expect(found.map(\.command) == ["cargo run -p my-cli", "cargo run -p multi --bin multi", "cargo run -p multi --bin extra",
                                         "cargo run -p xtask"])
        #expect(found.map(\.name) == ["my-cli", "multi", "extra", "xtask"])

        let single = try TempTree()
        defer { single.remove() }
        try single.write("Cargo.toml", "[package]\nname = \"perfetto-cli\"\n[dependencies]\nname = \"nope\"\n")
        #expect(RunDetector.cargo(in: single.root).isEmpty)
        try single.write("src/main.rs")
        #expect(RunDetector.cargo(in: single.root).map(\.command) == ["cargo run -p perfetto-cli"])
    }
}

@Suite struct GradleDetectorTests {
    @Test func settingsIncludeForms() {
        let kts = """
        pluginManagement { includeBuild("build-logic") }
        // include(":commented")
        include(
          ":app:android",
          ":app:desktop",
        )
        include(":core")
        include(":a", ":b")
        """
        #expect(RunDetector.gradleIncludes(settings: kts) == [":app:android", ":app:desktop", ":core", ":a", ":b"])
        let groovy = """
        include ':app', ':lib'
        include 'feature:one'
        includeGroup 'x'
        """
        #expect(RunDetector.gradleIncludes(settings: groovy) == [":app", ":lib", ":feature:one"])
    }

    @Test func androidFlavorsAndPluginForms() {
        let kts = """
        plugins {
          id("app.campfire.android.application")
          alias(libs.plugins.ksp)
        }
        android {
          defaultConfig { applicationId = "app.campfire.android" }
          flavorDimensions += "default"
          productFlavors {
            create("standard")
            create("alpha") {
              applicationIdSuffix = ".alpha"
            }
            register("beta") { }
          }
        }
        """
        #expect(RunDetector.gradleApps(buildFile: kts).map(\.task) == ["installStandardDebug", "installAlphaDebug", "installBetaDebug"])
        let groovy = """
        apply plugin: 'com.android.application'
        android {
          productFlavors {
            free { dimension "tier" }
            paid { dimension "tier" }
          }
        }
        """
        #expect(RunDetector.gradleApps(buildFile: groovy).map(\.label) == ["Android (free)", "Android (paid)"])
        #expect(RunDetector.gradleApps(buildFile: "plugins { alias(libs.plugins.android.application) }").map(\.task) == ["installDebug"])
        #expect(RunDetector.gradleApps(buildFile: "plugins { alias(libs.plugins.androidApplication) }").map(\.icon) == ["iphone"])
        #expect(RunDetector.gradleApps(buildFile: "android {\n  defaultConfig {\n    applicationId \"x\"\n  }\n}").map(\.task) == ["installDebug"])
        // Libraries, tests reading `.applicationId`, `apply false` and several dimensions are not apps.
        #expect(RunDetector.gradleApps(buildFile: "plugins { id(\"com.android.library\") }").isEmpty)
        #expect(RunDetector.gradleApps(buildFile: "plugins { id(\"com.android.test\") }\nval x = apk.applicationId!!").isEmpty)
        #expect(RunDetector.gradleApps(buildFile: "plugins {\n  alias(libs.plugins.android.application) apply false\n}").isEmpty)
        let twoDimensions = """
        plugins { id("com.android.application") }
        android {
          flavorDimensions("tier", "store")
          productFlavors { create("free") { dimension = "tier" }; create("play") { dimension = "store" } }
        }
        """
        #expect(RunDetector.gradleApps(buildFile: twoDimensions).isEmpty)
    }

    @Test func desktopHotReloadApplicationIntellijAndWeb() {
        let desktop = """
        plugins { alias(libs.plugins.kotlin.jvm) }
        dependencies { implementation(compose.desktop.currentOs) }
        compose.desktop {
          application {
            mainClass = "app.MainKt"
            nativeDistributions { packageName = "app" }
          }
        }
        """
        #expect(RunDetector.gradleApps(buildFile: desktop) == [.init(label: "Desktop", task: "run", icon: "desktopcomputer")])
        // `compose.desktop.currentOs` alone is a dependency, not an app.
        #expect(RunDetector.gradleApps(buildFile: "dependencies { implementation(compose.desktop.currentOs) }").isEmpty)
        #expect(RunDetector.gradleApps(buildFile: "compose {\n desktop {\n  application { mainClass = \"M\" }\n }\n}").map(\.task) == ["run"])

        for hot in ["id(\"org.jetbrains.compose.hot-reload\")", "alias(libs.plugins.compose.hot.reload)", "alias(libs.plugins.composeHotReload)"] {
            #expect(RunDetector.gradleApps(buildFile: "plugins {\n  \(hot)\n}").map(\.task) == ["hotRunJvm"])
        }

        for app in ["plugins {\n  kotlin(\"jvm\")\n  application\n}", "plugins { id(\"application\") }", "apply plugin: 'application'",
                    "plugins { id 'application' }", "application {\n  mainClass.set(\"x.MainKt\")\n}"] {
            #expect(RunDetector.gradleApps(buildFile: app).map(\.label) == ["Run"], "\(app)")
        }
        #expect(RunDetector.gradleApps(buildFile: "plugins { id(\"app.campfire.android.application\") }").map(\.label) != ["Run"])

        for ide in ["plugins { id(\"org.jetbrains.intellij.platform\") version \"2.0\" }", "plugins { id 'org.jetbrains.intellij' version '1.17' }",
                    "plugins { alias(libs.plugins.intellij.platform) }"] {
            #expect(RunDetector.gradleApps(buildFile: ide) == [.init(label: "Run IDE", task: "runIde", icon: "hammer")], "\(ide)")
        }
        #expect(RunDetector.gradleApps(buildFile: "plugins { id(\"org.jetbrains.intellij.platform.module\") }").isEmpty)

        let web = "kotlin {\n  wasmJs {\n    browser()\n    binaries.executable()\n  }\n  sourceSets { wasmJsMain.dependencies { } }\n}"
        #expect(RunDetector.gradleApps(buildFile: web) == [.init(label: "Web", task: "wasmJsBrowserDevelopmentRun", icon: "globe")])
        #expect(RunDetector.gradleApps(buildFile: "kotlin { wasmJs { nodejs() } }").isEmpty)

        let deck = "plugins {\n  alias(libs.plugins.cup)\n}\ncup {\n  targetDesktop()\n  targetWeb()\n}"
        #expect(RunDetector.gradleApps(buildFile: deck).map(\.task) == ["run", "hotRunJvm", "wasmJsBrowserDevelopmentRun"])
    }

    @Test func modulesNamesAndWrapper() {
        let settings = "include(\":catalog:android\", \":catalog:desktop\", \":spikes:jewel-compare\", \":lib\", \":tools:cli\")"
        let files = [
            "": "plugins {\n  alias(libs.plugins.android.application) apply false\n}",
            ":catalog:android": "plugins { alias(libs.plugins.android.application) }",
            ":catalog:desktop": "compose.desktop { application { mainClass = \"M\" } }",
            ":spikes:jewel-compare": "compose.desktop { application { mainClass = \"J\" } }",
            ":lib": "plugins { id(\"com.android.library\") }",
            ":tools:cli": "plugins { application }",
        ]
        let found = RunDetector.gradle(settings: settings, buildFiles: files, hasWrapper: true)
        #expect(found.map(\.name) == ["catalog · Android", "catalog · Desktop", "jewel-compare · Desktop", "cli · Run"])
        #expect(found.map(\.command) == ["./gradlew :catalog:android:installDebug", "./gradlew :catalog:desktop:run",
                                         "./gradlew :spikes:jewel-compare:run", "./gradlew :tools:cli:run"])

        // Distinct platforms read without their module.
        let campfire = RunDetector.gradle(settings: "include(\":app:android\", \":app:desktop\")", buildFiles: [
            ":app:android": "plugins { id(\"com.android.application\") }\nandroid { productFlavors { create(\"alpha\"); create(\"beta\") } }",
            ":app:desktop": "compose.desktop { application { } }",
        ], hasWrapper: false)
        #expect(campfire.map(\.name) == ["Android (alpha)", "Android (beta)", "Desktop"])
        #expect(campfire.map(\.command) == ["gradle :app:android:installAlphaDebug", "gradle :app:android:installBetaDebug", "gradle :app:desktop:run"])
        #expect(campfire.map(\.id) == ["android-alpha", "android-beta", "desktop"])

        // A single-module build runs bare tasks; a root app in a multi-module build runs `:task`.
        let single = RunDetector.gradle(settings: "rootProject.name = \"deck\"", buildFiles: ["": "plugins { application }"], hasWrapper: true)
        #expect(single.map(\.command) == ["./gradlew run"])
        #expect(single.map(\.name) == ["Run"])
        let rooted = RunDetector.gradle(settings: "include(\":lib\")", buildFiles: ["": "plugins { application }"], hasWrapper: true)
        #expect(rooted.map(\.command) == ["./gradlew :run"])
    }

    @Test func detectReadsATree() throws {
        let tree = try TempTree()
        defer { tree.remove() }
        try tree.write("gradlew")
        try tree.write("settings.gradle.kts", "include(\n  \":app:android\",\n  \":app:desktop\",\n)\ninclude(\":missing\")")
        try tree.write("build.gradle.kts", "plugins {\n  alias(libs.plugins.android.application) apply false\n}")
        try tree.write("app/android/build.gradle.kts", "plugins { id(\"com.android.application\") }")
        try tree.write("app/desktop/build.gradle", "plugins { id 'org.jetbrains.compose.hot-reload' }\ncompose.desktop { application { } }")
        try tree.write("Makefile", "desktop:\n\t./gradlew run\n")
        try tree.write("package.json", #"{"scripts": {"android": "x"}}"#)
        try tree.write("Package.swift", ".executableTarget(name: \"Desktop\")")

        let found = RunDetector.detect(in: tree.root)
        #expect(found.map(\.command) == ["./gradlew :app:android:installDebug", "./gradlew :app:desktop:run", "./gradlew :app:desktop:hotRunJvm",
                                         "npm run android", "make desktop", "swift run Desktop"])
        #expect(found.map(\.id) == ["android", "desktop", "desktop-hot-reload", "android-2", "desktop-2", "desktop-3"])
        #expect(Set(found.map(\.id)).count == found.count)

        let empty = try TempTree()
        defer { empty.remove() }
        #expect(RunDetector.detect(in: empty.root).isEmpty)
    }
}

@Suite struct XcodeDetectorTests {
    /// A project with a macOS app, an iOS app, a multiplatform app and a command-line tool.
    static let pbxproj = """
    // !$*UTF8*$!
    {
    \tarchiveVersion = 1;
    \tobjectVersion = 77;
    \tobjects = {
    \t\tP1 = { isa = PBXProject; buildConfigurationList = PL; targets = (T1, T2, T3, T4); };
    \t\tPL = { isa = XCConfigurationList; buildConfigurations = (PD, PR); };
    \t\tPD = { isa = XCBuildConfiguration; buildSettings = { SDKROOT = macosx; }; name = Debug; };
    \t\tPR = { isa = XCBuildConfiguration; buildSettings = { SDKROOT = iphoneos; }; name = Release; };
    \t\tT1 = { isa = PBXNativeTarget; buildConfigurationList = L1; name = MacApp; productType = "com.apple.product-type.application"; };
    \t\tL1 = { isa = XCConfigurationList; buildConfigurations = (C1); };
    \t\tC1 = { isa = XCBuildConfiguration; buildSettings = { PRODUCT_NAME = "Mac App"; }; name = Debug; };
    \t\tT2 = { isa = PBXNativeTarget; buildConfigurationList = L2; name = PhoneApp; productType = "com.apple.product-type.application"; };
    \t\tL2 = { isa = XCConfigurationList; buildConfigurations = (C2); };
    \t\tC2 = { isa = XCBuildConfiguration; buildSettings = { SDKROOT = iphoneos; }; name = Debug; };
    \t\tT3 = { isa = PBXNativeTarget; buildConfigurationList = L3; name = Everywhere; productType = "com.apple.product-type.application"; };
    \t\tL3 = { isa = XCConfigurationList; buildConfigurations = (C3); };
    \t\tC3 = { isa = XCBuildConfiguration; buildSettings = { SDKROOT = auto; SUPPORTED_PLATFORMS = "iphoneos iphonesimulator macosx"; PRODUCT_NAME = "$(TARGET_NAME)"; }; name = Debug; };
    \t\tT4 = { isa = PBXNativeTarget; buildConfigurationList = L4; name = helper; productType = "com.apple.product-type.tool"; };
    \t\tL4 = { isa = XCConfigurationList; buildConfigurations = (C4); };
    \t\tC4 = { isa = XCBuildConfiguration; buildSettings = { }; name = Debug; };
    \t};
    \trootObject = P1;
    }
    """

    static let list = Data(#"{"project": {"name": "App", "configurations": ["Debug"], "schemes": ["MacApp", "PhoneApp", "Everywhere", "helper", "SomePackage"], "targets": ["MacApp", "PhoneApp", "Everywhere", "helper"]}}"#.utf8)

    @Test func pbxprojTargets() {
        #expect(RunDetector.macAppTargets(pbxproj: Data(Self.pbxproj.utf8)) == ["MacApp": "Mac App", "Everywhere": "Everywhere"])
        #expect(RunDetector.macAppTargets(pbxproj: Data("not a plist {".utf8)) == nil)
    }

    @Test func listJSONBecomesMacAppRuns() throws {
        let tree = try TempTree()
        defer { tree.remove() }
        try tree.write("App.xcodeproj/project.pbxproj", Self.pbxproj)
        let container = tree.root.appendingPathComponent("App.xcodeproj")

        let found = RunDetector.xcodeConfigurations(listJSON: Self.list, container: container, root: tree.root)
        #expect(found.map(\.name) == ["MacApp", "Everywhere"])
        #expect(found.map(\.id) == ["xcode-macapp", "xcode-everywhere"])
        #expect(found[0].command == "xcodebuild -project App.xcodeproj -scheme MacApp -configuration Debug -destination 'platform=macOS' "
            + "-derivedDataPath .build/clinic-run build && open '.build/clinic-run/Build/Products/Debug/Mac App.app'")
        #expect(found[1].command?.hasSuffix("&& open .build/clinic-run/Build/Products/Debug/Everywhere.app") == true)
        #expect(found[0].symbol == "desktopcomputer")
        #expect(RunDetector.xcodeConfigurations(listJSON: Self.list, container: container, root: tree.root, avoiding: ["xcode-macapp"])
            .map(\.id) == ["xcode-macapp-2", "xcode-everywhere"])
        #expect(RunDetector.xcodeConfigurations(listJSON: Data("nope".utf8), container: container, root: tree.root).isEmpty)
    }

    @Test func iosOnlyProjectsAndSharedSchemes() throws {
        let tree = try TempTree()
        defer { tree.remove() }
        let ios = Self.pbxproj.replacingOccurrences(of: "SDKROOT = macosx", with: "SDKROOT = iphoneos")
            .replacingOccurrences(of: "macosx\"", with: "\"")
        try tree.write("ios/Phone.xcodeproj/project.pbxproj", ios)
        #expect(RunDetector.xcodeConfigurations(listJSON: Self.list, container: tree.root.appendingPathComponent("ios/Phone.xcodeproj"), root: tree.root).isEmpty)

        // A shared scheme with its own name still maps to the target it launches.
        try tree.write("App.xcodeproj/project.pbxproj", Self.pbxproj)
        try tree.write("App.xcodeproj/xcshareddata/xcschemes/Mac App (Dev).xcscheme", """
        <Scheme><LaunchAction><BuildableProductRunnable runnableDebuggingMode = "0">
          <BuildableReference BuildableIdentifier = "primary" BuildableName = "Mac App.app" BlueprintName = "MacApp" ReferencedContainer = "container:App.xcodeproj">
          </BuildableReference></BuildableProductRunnable></LaunchAction></Scheme>
        """)
        let list = Data(#"{"project": {"name": "App", "schemes": ["Mac App (Dev)"]}}"#.utf8)
        let found = RunDetector.xcodeConfigurations(listJSON: list, container: tree.root.appendingPathComponent("App.xcodeproj"), root: tree.root)
        #expect(found.map(\.name) == ["Mac App (Dev)"])
        #expect(found.first?.command?.contains("-scheme 'Mac App (Dev)'") == true)
    }

    @Test func workspaces() throws {
        let tree = try TempTree()
        defer { tree.remove() }
        try tree.write("mac/App.xcworkspace/contents.xcworkspacedata",
                       #"<?xml version="1.0"?><Workspace version="1.0"><FileRef location="group:App.xcodeproj"></FileRef><FileRef location="group:Pods/Pods.xcodeproj"></FileRef></Workspace>"#)
        try tree.write("mac/App.xcodeproj/project.pbxproj", Self.pbxproj)
        let workspace = tree.root.appendingPathComponent("mac/App.xcworkspace")
        let list = Data(#"{"workspace": {"name": "App", "schemes": ["MacApp", "Pods-App"]}}"#.utf8)
        let found = RunDetector.xcodeConfigurations(listJSON: list, container: workspace, root: tree.root)
        #expect(found.map(\.name) == ["MacApp"])
        #expect(found.first?.command?.hasPrefix("xcodebuild -workspace mac/App.xcworkspace -scheme MacApp ") == true)

        // With no readable project, a workspace keeps every scheme and finds the product at run time.
        try tree.write("other/Other.xcworkspace/contents.xcworkspacedata", #"<Workspace version="1.0"></Workspace>"#)
        let all = RunDetector.xcodeConfigurations(listJSON: list, container: tree.root.appendingPathComponent("other/Other.xcworkspace"), root: tree.root)
        #expect(all.map(\.name) == ["MacApp", "Pods-App"])
        #expect(all.first?.command?.hasSuffix(#"open "$(find .build/clinic-run/Build/Products/Debug -maxdepth 1 -name '*.app' -print -quit)""#) == true)
    }

    @Test func containersAreFoundTwoLevelsDeep() throws {
        let tree = try TempTree()
        defer { tree.remove() }
        try tree.mkdir("Root.xcodeproj/project.xcworkspace")
        try tree.mkdir("mac/App.xcworkspace")
        try tree.mkdir("mac/App.xcodeproj")
        try tree.mkdir("tools/Tool.xcodeproj")
        try tree.mkdir("app/ios/Deep.xcodeproj")
        try tree.mkdir("node_modules/Nope.xcodeproj")
        try tree.mkdir(".hidden/Nope.xcodeproj")
        let found = RunDetector.xcodeProjects(in: tree.root).map { RunParsing.relativePath(of: $0, in: tree.root) }
        #expect(found == ["Root.xcodeproj", "mac/App.xcworkspace", "tools/Tool.xcodeproj"])
    }

    @Test func detectXcodeSkipsProjectsWithoutAMacApp() async throws {
        let tree = try TempTree()
        defer { tree.remove() }
        try tree.write("Phone.xcodeproj/project.pbxproj", Self.pbxproj.replacingOccurrences(of: "com.apple.product-type.application", with: "com.apple.product-type.tool"))
        #expect(await RunDetector.detectXcode(in: tree.root).isEmpty)
    }

    @Test func boundedRunGivesUpOnAHungTool() async throws {
        let tree = try TempTree()
        defer { tree.remove() }
        let ok = await RunDetector.boundedRun("echo", ["hi"], in: tree.root, timeout: .seconds(10))
        #expect(ok.map { String(decoding: $0, as: UTF8.self) } == "hi\n")
        #expect(await RunDetector.boundedRun("false", [], in: tree.root, timeout: .seconds(10)) == nil)
        let start = Date()
        #expect(await RunDetector.boundedRun("sleep", ["5"], in: tree.root, timeout: .milliseconds(200)) == nil)
        #expect(Date().timeIntervalSince(start) < 3)
    }
}

@Suite struct RunParsingTests {
    @Test func paths() {
        #expect(RunParsing.normalize("./a//b/../c/") == "a/c")
        #expect(RunParsing.normalize(".") == ".")
        #expect(RunParsing.normalize("../x") == "../x")
        #expect(RunParsing.normalize("/a/./b/..") == "/a")
        #expect(RunParsing.ancestors(of: "a/b") == ["a/b", "a", "."])
        #expect(RunParsing.ancestors(of: "/abs").isEmpty)
        #expect(RunParsing.relative(from: "host", to: ".") == "..")
        #expect(RunParsing.relative(from: ".", to: "host/sub") == "host/sub")
        #expect(RunParsing.relative(from: "a/b", to: "a/c") == "../c")
        #expect(RunParsing.relative(from: "a", to: "a") == ".")
    }

    @Test func commentsAndLists() {
        #expect(RunParsing.stripComments("a // b\n\"c // d\" /* e\n f */ g 'h//'") == "a \n\"c // d\" \n g 'h//'")
        #expect(RunParsing.stripHashComment(#"name = "a#b" # note"#) == #"name = "a#b" "#)
        #expect(RunParsing.list(["a"]) == "a")
        #expect(RunParsing.list(["a", "b"]) == "a and b")
        #expect(RunParsing.list(["a", "b", "c"]) == "a, b and c")
    }
}
