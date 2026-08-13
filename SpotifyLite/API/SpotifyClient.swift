import Foundation

struct UserProfile: Decodable {
    let id: String
    let displayName: String?
    let product: String?

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case product
    }
}

enum SpotifyAPIError: LocalizedError {
    case notSignedIn
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .notSignedIn: return "No hay sesión activa."
        case .http(let code, let body): return "Spotify respondió \(code): \(body)"
        }
    }
}

/// Capa HTTP de la Web API. Actor: serializa el refresh para que dos requests
/// con token vencido no lo renueven en paralelo.
actor SpotifyClient {
    static let shared = SpotifyClient()

    private let baseURL = URL(string: "https://api.spotify.com/v1")!
    private var refreshTask: Task<TokenSet, Error>?

    func request<T: Decodable>(_ path: String) async throws -> T {
        let data = try await send(path: path, allowRetry: true)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func send(path: String, allowRetry: Bool) async throws -> Data {
        guard var tokens = KeychainStore.load() else { throw SpotifyAPIError.notSignedIn }
        if tokens.isExpired {
            tokens = try await refreshTokens(tokens)
        }

        var request = URLRequest(url: baseURL.appending(path: path))
        request.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        switch http.statusCode {
        case 200...299:
            return data
        case 401 where allowRetry:
            _ = try await refreshTokens(tokens)
            return try await send(path: path, allowRetry: false)
        case 429:
            let retryAfter = Double(http.value(forHTTPHeaderField: "Retry-After") ?? "1") ?? 1
            try await Task.sleep(for: .seconds(retryAfter))
            return try await send(path: path, allowRetry: allowRetry)
        default:
            throw SpotifyAPIError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
    }

    private func refreshTokens(_ current: TokenSet) async throws -> TokenSet {
        if let refreshTask {
            return try await refreshTask.value
        }
        let clientID = UserDefaults.standard.string(forKey: SpotifyAuthConfig.clientIDDefaultsKey) ?? ""
        let task = Task<TokenSet, Error> {
            let fresh = try await TokenEndpoint.refresh(current, clientID: clientID)
            try KeychainStore.save(fresh)
            return fresh
        }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }
}
