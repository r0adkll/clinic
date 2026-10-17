import CryptoKit
import Foundation

/// Signed tokens for an emulator that takes JWTs rather than its console token: every emulator started
/// without `-grpc-use-token`, Android Studio's among them. The emulator trusts any public key placed in its
/// `grpc.jwks` directory, so Clinic puts one there and signs short-lived ES256 tokens with the private half,
/// as Android Studio does. The issuer is Studio's, `android-studio`: the SDK's allowlist
/// (`emulator/lib/emulator_access.json`) grants that issuer every service the Device pane calls.
enum EmulatorJWT {
    /// One key for the life of the process, shared by every connection to every emulator.
    private static let key = P256.Signing.PrivateKey()
    private static let keyId = "clinic-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString.prefix(8))"
    private static let audience = [
        "android.emulation.control.EmulatorController",
        "android.emulation.control.UiController",
        "android.emulation.control.SnapshotService",
    ]

    /// Puts Clinic's public key in the emulator's key directory, unless it is already there, and waits until
    /// the emulator lists it as loaded, so the first call is not refused while it catches up.
    static func register(with emulator: RunningEmulator, timeout: Duration = .seconds(5)) async throws {
        guard emulator.token == nil, let directory = emulator.jwksDirectory else { return }
        let file = directory.appendingPathComponent("\(keyId).jwk")
        if !FileManager.default.fileExists(atPath: file.path) {
            try publicJWKSet().write(to: file, options: .atomic)
        }
        guard let active = emulator.activeJWKFile else { return }
        let clock = ContinuousClock(), deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if let data = try? Data(contentsOf: active), String(decoding: data, as: UTF8.self).contains(keyId) { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw EmulatorError("\(emulator.name) did not load Clinic's key from \(directory.path).")
    }

    /// A token good for ten minutes. A stream outlives it, since only the start of a call is checked.
    static func token(now: Date = Date()) -> String {
        let iat = Int(now.timeIntervalSince1970)
        // No `typ`: the emulator's validator (Tink) refuses a token that sets one it was not told to expect.
        let header: [String: Any] = ["alg": "ES256", "kid": keyId]
        let claims: [String: Any] = ["iss": "android-studio", "aud": audience, "iat": iat - 5, "exp": iat + 600]
        let signingInput = base64URL(json(header)) + "." + base64URL(json(claims))
        // CryptoKit's raw signature is r‖s, the form JWS wants for ES256.
        let signature = try! key.signature(for: Data(signingInput.utf8)).rawRepresentation
        return signingInput + "." + base64URL(signature)
    }

    /// The public key as the emulator reads it: a JWK set, as Tink writes one.
    static func publicJWKSet() -> Data {
        let point = key.publicKey.rawRepresentation // x‖y, 32 bytes each
        return json(["keys": [[
            "kty": "EC", "crv": "P-256", "alg": "ES256", "use": "sig", "key_ops": ["verify"], "kid": keyId,
            "x": base64URL(point.prefix(32)), "y": base64URL(point.suffix(32)),
        ]]])
    }

    private static func json(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
