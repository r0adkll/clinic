import Foundation
import Testing
@testable import ClinicCore

@Suite struct ProjectIconGeneratorTests {
    @Test func promptGoesFirstAndCarriesTheHint() {
        let args = ProjectIconGenerator.arguments(prompt: ProjectIconGenerator.prompt(hint: "a green camel"))
        #expect(args.first?.contains("The user asks for: a green camel") == true)
        #expect(args.dropFirst().first == "-p")
        let tools = args.firstIndex(of: "--allowedTools").map { args[args.index(after: $0)] }
        #expect(tools == "Read,Glob,Grep")
        #expect(args.contains("--no-session-persistence") && args.contains("--strict-mcp-config"))
        #expect(args.contains("--permission-mode") && args.contains("dontAsk"))
        // An empty hint adds nothing.
        #expect(ProjectIconGenerator.prompt(hint: "   ").contains("The user asks for") == false)
    }

    @Test func extractsSVGFromFencesAndProse() {
        let svg = "<svg viewBox=\"0 0 64 64\"><rect width=\"64\" height=\"64\" rx=\"14\"/></svg>"
        #expect(ProjectIconGenerator.extractSVG(from: svg) == svg)
        #expect(ProjectIconGenerator.extractSVG(from: "Here you go:\n```svg\n\(svg)\n```\nHope it helps!") == svg)
        #expect(ProjectIconGenerator.extractSVG(from: "no icon today") == nil)
        #expect(ProjectIconGenerator.extractSVG(from: "<svg viewBox=\"0 0 1 1\">") == nil)
    }

    @Test func rejectsSVGsThatDoMoreThanDraw() {
        let ok = "<svg viewBox=\"0 0 64 64\"><defs><linearGradient id=\"g\"/></defs><rect fill=\"url(#g)\" width=\"64\" height=\"64\"/></svg>"
        #expect(ProjectIconGenerator.rejectionReason(for: ok) == nil)
        #expect(ProjectIconGenerator.rejectionReason(for: "<svg><script>alert(1)</script></svg>") != nil)
        #expect(ProjectIconGenerator.rejectionReason(for: "<svg><foreignObject><b>hi</b></foreignObject></svg>") != nil)
        #expect(ProjectIconGenerator.rejectionReason(for: "<svg><image href=\"https://x/y.png\"/></svg>") != nil)
        #expect(ProjectIconGenerator.rejectionReason(for: "<svg><use xlink:href=\"other.svg#a\"/></svg>") != nil)
        #expect(ProjectIconGenerator.rejectionReason(for: "<svg><rect onload=\"x()\"/></svg>") != nil)
        #expect(ProjectIconGenerator.rejectionReason(for: "<!DOCTYPE svg><svg/>") != nil)
        #expect(ProjectIconGenerator.rejectionReason(for: "<svg>" + String(repeating: "a", count: 70 * 1024) + "</svg>") != nil)
    }

    @Test func svgFromOutputThrowsForRejectedAndMissing() throws {
        #expect(throws: ProjectIconGenerator.Failure.self) { try ProjectIconGenerator.svg(fromCLIOutput: "sorry") }
        #expect(throws: ProjectIconGenerator.Failure.self) { try ProjectIconGenerator.svg(fromCLIOutput: "<svg><script/></svg>") }
        let accepted = try ProjectIconGenerator.svg(fromCLIOutput: "```\n<svg><rect/></svg>\n```")
        #expect(accepted == "<svg xmlns=\"http://www.w3.org/2000/svg\"><rect/></svg>")
        // An SVG that already declares the namespace is left alone.
        let namespaced = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 64 64\"><rect/></svg>"
        #expect(try ProjectIconGenerator.svg(fromCLIOutput: namespaced) == namespaced)
    }

    @Test func savesUnderDotClinicAndRemoves() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(ProjectIconGenerator.hasGeneratedIcon(projectPath: dir.path) == false)
        let url = try ProjectIconGenerator.save("<svg/>", projectPath: dir.path)
        #expect(url.path == dir.appendingPathComponent(".clinic/icon.svg").path)
        #expect(ProjectIconGenerator.hasGeneratedIcon(projectPath: dir.path))
        #expect(try String(contentsOf: url, encoding: .utf8) == "<svg/>")
        // Only `.clinic` is added to the project.
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == [".clinic"])

        try ProjectIconGenerator.removeGeneratedIcon(projectPath: dir.path)
        #expect(ProjectIconGenerator.hasGeneratedIcon(projectPath: dir.path) == false)
        try ProjectIconGenerator.removeGeneratedIcon(projectPath: dir.path)  // idempotent
    }

    @Test func reportsFailureWhenTheCLIIsMissing() async {
        await #expect(throws: ProjectIconGenerator.Failure.self) {
            try await ProjectIconGenerator.generate(projectPath: NSTemporaryDirectory(), executable: "clinic-no-such-binary")
        }
    }

    @Test func cancellationStopsTheRun() async throws {
        let task = Task { try await ProjectIconGenerator.run(["/bin/sleep", "30"], cwd: NSTemporaryDirectory()) }
        try await Task.sleep(for: .milliseconds(150))
        task.cancel()
        let result = await task.result
        #expect(throws: ProjectIconGenerator.Failure.cancelled) { try result.get() }
    }
}
