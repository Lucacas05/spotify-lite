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
        ], fallbackRefreshToken: nil)
    }

    static func refresh(_ tokens: TokenSet, clientID: String) async throws -> TokenSet {
        try await request(form: [
            "grant_type": "refresh_token",
            "refresh_token": tokens.refreshToken,
            "client_id": clientID,
        ], fallbackRefreshToken: tokens.refreshToken)
    }

    private static func request(form: [String: String], fallbackRefreshToken: String?) async throws -> TokenSet {
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var components = URLComponents()
        components.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = Data((components.percentEncodedQuery ?? "").utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw AuthError.tokenRequestFailed(body)
        }
        let token = try JSONDecoder().decode(TokenResponse.self, from: data)
        guard let refreshToken = token.refreshToken ?? fallbackRefreshToken else {
            throw AuthError.tokenRequestFailed("missing refresh_token")
        }
        return TokenSet(accessToken: token.accessToken,
                        refreshToken: refreshToken,
                        expiresAt: Date().addingTimeInterval(TimeInterval(token.expiresIn)))
    }
}

enum AuthError: LocalizedError {
    case missingClientID
    case tokenRequestFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingClientID:
            return "Set your Spotify Client ID before logging in."
        case .tokenRequestFailed(let body):
            return "Spotify rejected the token request: \(body)"
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
    var lastError: String?

    var clientID: String {
        didSet { UserDefaults.standard.set(clientID, forKey: SpotifyAuthConfig.clientIDDefaultsKey) }
    }

    private var server: LoopbackServer?

    init() {
        clientID = UserDefaults.standard.string(forKey: SpotifyAuthConfig.clientIDDefaultsKey) ?? ""
        state = KeychainStore.load() != nil ? .signedIn : .signedOut
    }

    func login() async {
        let clientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientID.isEmpty else {
            lastError = AuthError.missingClientID.localizedDescription
            return
        }
        self.clientID = clientID

        let verifier = PKCE.generateVerifier()
        let authState = PKCE.generateVerifier()

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
            state = .signedIn
        } catch {
            lastError = error.localizedDescription
            state = .signedOut
        }
        self.server = nil
    }

    func cancelLogin() {
        server?.stop()
        server = nil
        if state == .authorizing { state = .signedOut }
    }

    func logout() {
        KeychainStore.delete()
        state = .signedOut
    }
}
