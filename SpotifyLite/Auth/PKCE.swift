import Foundation
import CryptoKit

enum PKCEError: LocalizedError {
    case entropyUnavailable

    var errorDescription: String? {
        "No se pudo generar un secreto seguro para el inicio de sesión. Inténtalo de nuevo."
    }
}

enum PKCE {
    static func generateVerifier() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 64)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { throw PKCEError.entropyUnavailable }
        return Data(bytes).base64URLEncoded()
    }

    static func challenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64URLEncoded()
    }
}

extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
