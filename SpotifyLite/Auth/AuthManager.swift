import AppKit
import Foundation
import Observation

struct TokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Int

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
    }
}

private struct TokenErrorPayload: Decodable {
    let error: String
}

enum SpotifyAuthConfig {
    static let redirectPort: UInt16 = 8888
    static let redirectURI = "http://127.0.0.1:8888/callback"
    static let scopes = "user-read-playback-state user-modify-playback-state user-read-currently-playing playlist-read-private playlist-read-collaborative user-library-read user-read-private streaming"
    static let clientIDDefaultsKey = "clientID"
}

/// Token exchange and refresh against accounts.spotify.com. Stateless; used by
/// AuthManager (exchange) and SpotifyClient (refresh).
enum TokenEndpoint {
    static func exchangeCode(_ code: String, verifier: String, clientID: String) async throws -> TokenSet {
        try await request(form: [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": SpotifyAuthConfig.redirectURI,
            "client_id": clientID,
            "code_verifier": verifier,
        ], isRefresh: false)
    }

    static func refresh(_ tokens: TokenSet, clientID: String) async throws -> TokenSet {
        try await request(form: [
            "grant_type": "refresh_token",
            "refresh_token": tokens.refreshToken,
            "client_id": clientID,
        ], isRefresh: true)
    }

    private static func request(form: [String: String], isRefresh: Bool) async throws -> TokenSet {
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var components = URLComponents()
        components.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = Data((components.percentEncodedQuery ?? "").utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            if isRefresh, isDefinitiveRefreshRejection(status: status, data: data) {
                throw AuthError.invalidGrant
            }
            throw AuthError.tokenRequestFailed
        }
        let token = try JSONDecoder().decode(TokenResponse.self, from: data)
        let fallbackRefresh = form["refresh_token"]
        guard let refreshToken = token.refreshToken ?? fallbackRefresh else {
            throw AuthError.tokenRequestFailed
        }
        return TokenSet(accessToken: token.accessToken,
                        refreshToken: refreshToken,
                        expiresAt: Date().addingTimeInterval(TimeInterval(token.expiresIn)))
    }

    static func isDefinitiveRefreshRejection(status: Int, data: Data) -> Bool {
        if status == 400 || status == 401 { return true }
        if let payload = try? JSONDecoder().decode(TokenErrorPayload.self, from: data),
           payload.error == "invalid_grant" {
            return true
        }
        return false
    }
}

enum AuthError: LocalizedError {
    case missingClientID
    case tokenRequestFailed
    case invalidGrant

    var errorDescription: String? {
        switch self {
        case .missingClientID:
            return "Set your Spotify Client ID before logging in."
        case .tokenRequestFailed:
            return "Spotify rechazó la solicitud de token. Inténtalo de nuevo."
        case .invalidGrant:
            return SpotifyAPIError.sessionExpiredMessage
        }
    }

    var isDefinitiveRefreshFailure: Bool {
        switch self {
        case .invalidGrant: return true
        case .missingClientID, .tokenRequestFailed: return false
        }
    }
}

@MainActor
@Observable
final class AuthManager {
    enum State {
        case signedOut
        case authorizing
        case signedIn
    }

    private(set) var state: State
    /// Signed in with a blob in Keychain is not enough: a dead refresh token
    /// stays signed-in until the user logs out, but `isSessionExpired` stops retries.
    private(set) var isSessionExpired = false
    var lastError: String?

    var clientID: String {
        didSet { UserDefaults.standard.set(clientID, forKey: SpotifyAuthConfig.clientIDDefaultsKey) }
    }

    private var server: LoopbackServer?
    private var sessionInvalidationObserver: (any NSObjectProtocol)?

    init() {
        clientID = UserDefaults.standard.string(forKey: SpotifyAuthConfig.clientIDDefaultsKey) ?? ""
        state = KeychainStore.load() != nil ? .signedIn : .signedOut
        sessionInvalidationObserver = NotificationCenter.default.addObserver(
            forName: .spotifySessionInvalidated,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.markSessionExpired()
            }
        }
    }

    func markSessionExpired() {
        guard state == .signedIn else { return }
        isSessionExpired = true
    }

    func login() async {
        let clientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientID.isEmpty else {
            lastError = AuthError.missingClientID.localizedDescription
            return
        }
        self.clientID = clientID

        let verifier: String
        let authState: String
        do {
            verifier = try PKCE.generateVerifier()
            authState = try PKCE.generateVerifier()
        } catch {
            lastError = error.localizedDescription
            return
        }

        var components = URLComponents(string: "https://accounts.spotify.com/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: SpotifyAuthConfig.redirectURI),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: PKCE.challenge(for: verifier)),
            URLQueryItem(name: "state", value: authState),
            URLQueryItem(name: "scope", value: SpotifyAuthConfig.scopes),
        ]

        state = .authorizing
        lastError = nil
        let server = LoopbackServer()
        self.server = server
        do {
            async let code = server.waitForCode(port: SpotifyAuthConfig.redirectPort,
                                               expectedState: authState)
            NSWorkspace.shared.open(components.url!)
            let tokens = try await TokenEndpoint.exchangeCode(try await code,
                                                              verifier: verifier,
                                                              clientID: clientID)
            try KeychainStore.save(tokens)
            await SpotifyClient.shared.resetSession()
            isSessionExpired = false
            state = .signedIn
        } catch {
            if Self.isLoginCancellation(error) {
                lastError = nil
            } else {
                lastError = error.localizedDescription
            }
            if state == .authorizing {
                state = .signedOut
            }
        }
        self.server = nil
    }

    /// Owns login cancellation: stops the loopback server so its continuation
    /// resumes exactly once. Does not wait for `login()` to finish.
    func cancelLogin() {
        lastError = nil
        server?.stop()
        server = nil
        if state == .authorizing { state = .signedOut }
    }

    func logout() {
        KeychainStore.delete()
        isSessionExpired = false
        state = .signedOut
        Task { await SpotifyClient.shared.resetSession() }
    }

    private static func isLoginCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let serverError = error as? LoopbackServer.ServerError, serverError == .cancelled {
            return true
        }
        return false
    }
}
