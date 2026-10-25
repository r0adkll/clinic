import Foundation
import Testing
@testable import ClinicCore

@Suite struct DiagnosticsArchiveTests {
    private func temporaryArchive(limit: Int = 30) -> DiagnosticsArchive {
        DiagnosticsArchive(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("diagnostics-\(UUID().uuidString)", isDirectory: true), limit: limit)
    }

    @Test func aFileNameSortsByTimeAndHasNoColons() {
        let name = DiagnosticsArchive.fileName(kind: "exception", at: Date(timeIntervalSince1970: 1_792_243_210.5))
        #expect(name == "exception-2026-10-17T13-20-10.500Z.json")
    }

    @Test func filesComeBackNewestFirstWhateverTheirKind() throws {
        let archive = temporaryArchive()
        defer { try? FileManager.default.removeItem(at: archive.directory) }
        try archive.write(Data("{}".utf8), kind: "metrickit", at: Date(timeIntervalSince1970: 100))
        try archive.write(Data("{}".utf8), kind: "exception", at: Date(timeIntervalSince1970: 200))
        try archive.write(Data("{}".utf8), kind: "metrickit", at: Date(timeIntervalSince1970: 300))
        let kinds = archive.files().map { $0.lastPathComponent.components(separatedBy: "-")[0] }
        #expect(kinds == ["metrickit", "exception", "metrickit"])
    }

    @Test func writingPastTheLimitDropsTheOldest() throws {
        let archive = temporaryArchive(limit: 2)
        defer { try? FileManager.default.removeItem(at: archive.directory) }
        for t in [100.0, 200, 300] { try archive.write(Data("{}".utf8), kind: "exception", at: Date(timeIntervalSince1970: t)) }
        let names = archive.files().map(\.lastPathComponent)
        #expect(names == [DiagnosticsArchive.fileName(kind: "exception", at: Date(timeIntervalSince1970: 300)),
                          DiagnosticsArchive.fileName(kind: "exception", at: Date(timeIntervalSince1970: 200))])
    }

    @Test func aReportRoundTripsWithItsWorkspace() throws {
        let area = WorkspaceDump.Area(panes: ["claude*", "files"], visible: true, frame: "0,0 900x1050")
        let report = ExceptionReport(
            name: "NSGenericException", reason: "more Update Constraints in Window passes than there are views",
            callStack: ["0 CoreFoundation __exceptionPreprocess"], date: Date(timeIntervalSince1970: 1_792_243_210),
            appVersion: "0.5.0 (1)", osVersion: "26.0",
            workspace: WorkspaceDump(
                windows: [.init(id: "w", frame: "0,39 1800x1130", fullScreen: true, isKey: true, selectedTab: "t",
                                showing: nil, toolbar: ["run", "device:android"])],
                tabs: [.init(id: "t", window: "w", session: "s", title: "Device pane", project: "/p", state: "working",
                             replay: false, focusedArea: "main", main: area, panel: area)]))
        #expect(try DiagnosticsArchive.decoder.decode(ExceptionReport.self, from: report.encoded()) == report)
    }
}
