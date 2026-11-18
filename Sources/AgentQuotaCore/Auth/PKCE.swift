import CryptoKit
import Foundation
import Security

/// PKCE (RFC 7636) verifier and S256 challenge, plus the OAuth `state` that guards the callback against CSRF.
public struct PKCECodes: Sendable, Equatable {
    public let codeVerifier: String
    public let codeChallenge: String
    public let state: String

    public init() {
        self.init(codeVerifier: Self.randomURLSafe(byteCount: 64), state: Self.randomURLSafe(byteCount: 32))
    }

    init(codeVerifier: String, state: String) {
        self.codeVerifier = codeVerifier
        self.state = state
        self.codeChallenge = Self.challenge(for: codeVerifier)
    }

    static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func randomURLSafe(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        // All-zero bytes would make the verifier and state predictable; never continue with them.
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
        return base64URL(Data(bytes))
    }
}
