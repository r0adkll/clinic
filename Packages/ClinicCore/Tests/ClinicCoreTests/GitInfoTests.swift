import Foundation
import Testing
@testable import ClinicCore

@Suite struct GitInfoTests {
    @Test func branchInFreshRepo() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("clinic-git-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/env"); p.arguments = ["git", "-C", dir.path, "init", "-q", "-b", "trunk"]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try p.run(); p.waitUntilExit()
        #expect(await GitInfo.branch(at: dir.path) == "trunk")
        #expect(await GitInfo.branch(at: "/") == nil)
        #expect(await GitInfo.branch(at: "/definitely/not/here") == nil)
    }
}
