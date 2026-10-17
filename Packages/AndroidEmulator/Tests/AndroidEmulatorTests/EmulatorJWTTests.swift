import CryptoKit
import Foundation
import Testing
@testable import AndroidEmulator

@Suite struct EmulatorJWTTests {
    @Test func readsTheKeyDirectoryOfAnEmulatorThatTakesSignedTokens() throws {
        let ini = """
        avd.id=Pixel_10_Pro_Fold
        grpc.jwks=/tmp/avd/running/71908/jwks/b5fc
        grpc.jwk_active=/tmp/avd/running/71908/jwks/b5fc/active.jwk
        grpc.port=8554
        """
        let emulator = try #require(RunningEmulator(ini: ini, pid: 71908))
        #expect(emulator.token == nil)
        #expect(emulator.jwksDirectory?.path == "/tmp/avd/running/71908/jwks/b5fc")
        #expect(emulator.activeJWKFile?.lastPathComponent == "active.jwk")
    }

    @Test func signsATokenThePublishedKeyVerifies() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let parts = EmulatorJWT.token(now: now).split(separator: ".").map(String.init)
        #expect(parts.count == 3)

        let set = try JSONSerialization.jsonObject(with: EmulatorJWT.publicJWKSet()) as! [String: [[String: Any]]]
        let jwk = try #require(set["keys"]?.first).compactMapValues { $0 as? String }
        #expect(jwk["kty"] == "EC" && jwk["crv"] == "P-256" && jwk["alg"] == "ES256")
        let key = try P256.Signing.PublicKey(rawRepresentation: decode(jwk["x"]!) + decode(jwk["y"]!))
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: decode(parts[2]))
        #expect(key.isValidSignature(signature, for: Data((parts[0] + "." + parts[1]).utf8)))

        let header = try JSONSerialization.jsonObject(with: decode(parts[0])) as! [String: String]
        #expect(header["kid"] == jwk["kid"])
        let claims = try JSONSerialization.jsonObject(with: decode(parts[1])) as! [String: Any]
        #expect(claims["iss"] as? String == "android-studio")
        #expect((claims["aud"] as? [String])?.isEmpty == false)
        #expect((claims["iat"] as! Int) < 1_800_000_000 && (claims["exp"] as! Int) > 1_800_000_000)
    }

    @Test func registersItsKeyAndWaitsForTheEmulatorToLoadIt() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let active = directory.appendingPathComponent("active.jwk")
        try Data(#"{"keys": []}"#.utf8).write(to: active)
        let ini = "avd.id=x\ngrpc.port=1\ngrpc.jwks=\(directory.path)\ngrpc.jwk_active=\(active.path)"
        let emulator = try #require(RunningEmulator(ini: ini, pid: 1))

        // Stand in for the emulator: merge the first key that appears into the active file.
        let emulatorSide = Task {
            while !Task.isCancelled {
                let keys = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0 != "active.jwk" }
                if let name = keys.first {
                    let key = try Data(contentsOf: directory.appendingPathComponent(name))
                    try (Data(#"{"keys": ["#.utf8) + key + Data("]}".utf8)).write(to: active)
                    return
                }
                try await Task.sleep(for: .milliseconds(50))
            }
        }
        try await EmulatorJWT.register(with: emulator)
        try await emulatorSide.value
    }

    private func decode(_ text: String) -> Data {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)!
    }
}
