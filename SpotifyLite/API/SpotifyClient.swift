import Foundation

struct UserProfile: Decodable {
    let id: String
    let displayName: String?
    let product: String?
    let images: [SpotifyImage]?

    var avatarURL: URL? {
        guard let images, !images.isEmpty else { return nil }
        let sorted = images.sorted { ($0.width ?? 0) < ($1.width ?? 0) }
        return (sorted.first { ($0.width ?? 0) >= 48 } ?? sorted.last)
            .flatMap { URL(string: $0.url) }
    }
}

enum SpotifyAPIError: LocalizedError {
    case notSignedIn
    case http(Int, String)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .notSignedIn: return "There is no active session."
        case .http(let code, let body): return "Spotify responded \(code): \(body)"
        case .emptyResponse: return "Spotify returned no data."
        }
    }

    /// PUT /me/player/* responds 404 when no Connect device is active.
    var isNoActiveDevice: Bool {
        if case .http(404, _) = self { return true }
        return false
    }
}

/// Web API HTTP layer. Actor: serializes refresh so two requests with an
/// expired token do not renew it in parallel.
actor SpotifyClient {
    static let shared = SpotifyClient()

    private let baseURL = URL(string: "https://api.spotify.com/v1")!
    private var refreshTask: Task<TokenSet, Error>?
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    /// Fresh access token for handing to the librespot child process.
    func validAccessToken() async throws -> String {
        guard var tokens = KeychainStore.load() else { throw SpotifyAPIError.notSignedIn }
        if tokens.isExpired {
            tokens = try await refreshTokens(tokens)
        }
        return tokens.accessToken
    }

    func get<T: Decodable>(_ path: String, query: [String: String] = [:]) async throws -> T {
        guard let value: T = try await getOptional(path, query: query) else {
            throw SpotifyAPIError.emptyResponse
        }
        return value
    }

    /// For endpoints that respond 204 with no body (GET /me/player when nothing is playing).
    func getOptional<T: Decodable>(_ path: String, query: [String: String] = [:]) async throws -> T? {
        let data = try await send("GET", path: path, query: query, body: nil, allowRetry: true)
        guard !data.isEmpty else { return nil }
        return try decoder.decode(T.self, from: data)
    }

    /// PUT/POST player endpoints, which respond 200/202/204 with no useful body.
    func command(_ method: String, _ path: String,
                 query: [String: String] = [:], body: [String: Any]? = nil) async throws {
        _ = try await send(method, path: path, query: query, body: body, allowRetry: true)
    }

    private func send(_ method: String, path: String, query: [String: String],
                      body: [String: Any]?, allowRetry: Bool) async throws -> Data {
        try Task.checkCancellation()
        guard var tokens = KeychainStore.load() else { throw SpotifyAPIError.notSignedIn }
        if tokens.isExpired {
            tokens = try await refreshTokens(tokens)
        }

        var components = URLComponents(url: baseURL.appending(path: path),
                                       resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        try Task.checkCancellation()
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        switch http.statusCode {
        case 200...299:
            return data
        case 401 where allowRetry:
            _ = try await refreshTokens(tokens)
            return try await send(method, path: path, query: query, body: body, allowRetry: false)
        case 429:
            let retryAfter = Double(http.value(forHTTPHeaderField: "Retry-After") ?? "1") ?? 1
            try await Task.sleep(for: .seconds(retryAfter))
            return try await send(method, path: path, query: query, body: body, allowRetry: allowRetry)
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
