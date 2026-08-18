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

enum SpotifyHTTPRetryPolicy {
    static let maxRateLimitRetries = 2

    /// GET/PUT may retry. Non-idempotent POSTs (Add to Queue, next, previous)
    /// must not be replayed.
    static func shouldRetryRateLimit(method: String, retryCount: Int) -> Bool {
        guard retryCount < maxRateLimitRetries else { return false }
        return method.uppercased() != "POST"
    }

    static func retryAfterSeconds(from header: String?) -> TimeInterval {
        max(Double(header ?? "") ?? 1, 0)
    }
}

enum SpotifyAPIError: LocalizedError {
    case notSignedIn
    case http(Int, String)
    case emptyResponse
    case sessionExpired

    static let sessionExpiredMessage = "Tu sesión expiró. Vuelve a iniciar sesión."
    static let rateLimitedMessage = "Spotify está limitando las peticiones. Espera un momento e inténtalo de nuevo."

    var errorDescription: String? {
        switch self {
        case .notSignedIn: return "There is no active session."
        case .http(let code, let body):
            if code == 429 { return Self.rateLimitedMessage }
            return "Spotify responded \(code): \(body)"
        case .emptyResponse: return "Spotify returned no data."
        case .sessionExpired: return Self.sessionExpiredMessage
        }
    }

    /// PUT /me/player/* responds 404 when no Connect device is active.
    var isNoActiveDevice: Bool {
        if case .http(404, _) = self { return true }
        return false
    }

    var isSessionExpired: Bool {
        if case .sessionExpired = self { return true }
        return false
    }
}

extension Notification.Name {
    static let spotifySessionInvalidated = Notification.Name("com.lucas.spotifylite.sessionInvalidated")
}

/// Web API HTTP layer. Actor: serializes refresh so two requests with an
/// expired token do not renew it in parallel.
actor SpotifyClient {
    static let shared = SpotifyClient()

    private let baseURL = URL(string: "https://api.spotify.com/v1")!
    private var refreshTask: Task<TokenSet, Error>?
    private var sessionInvalidated = false
    private var sessionEpoch = 0
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    /// Fresh access token. Intentionally unused by librespot: issue #16 keeps
    /// librespot's own OAuth (`--enable-oauth`) and does not auto-wire this path.
    func validAccessToken() async throws -> String {
        if sessionInvalidated { throw SpotifyAPIError.sessionExpired }
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
        let data = try await send("GET", path: path, query: query, body: nil,
                                  allowAuthRetry: true, rateLimitAttempt: 0)
        guard !data.isEmpty else { return nil }
        return try decoder.decode(T.self, from: data)
    }

    /// PUT/POST player endpoints, which respond 200/202/204 with no useful body.
    func command(_ method: String, _ path: String,
                 query: [String: String] = [:], body: [String: Any]? = nil) async throws {
        _ = try await send(method, path: path, query: query, body: body,
                           allowAuthRetry: true, rateLimitAttempt: 0)
    }

    func resetSession() {
        sessionEpoch += 1
        sessionInvalidated = false
        refreshTask?.cancel()
        refreshTask = nil
    }

    private func send(_ method: String, path: String, query: [String: String],
                      body: [String: Any]?, allowAuthRetry: Bool,
                      rateLimitAttempt: Int) async throws -> Data {
        if sessionInvalidated {
            throw SpotifyAPIError.sessionExpired
        }
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

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        switch http.statusCode {
        case 200...299:
            return data
        case 401 where allowAuthRetry:
            _ = try await refreshTokens(tokens)
            return try await send(method, path: path, query: query, body: body,
                                  allowAuthRetry: false, rateLimitAttempt: rateLimitAttempt)
        case 401:
            invalidateSession()
            throw SpotifyAPIError.sessionExpired
        case 429:
            if SpotifyHTTPRetryPolicy.shouldRetryRateLimit(method: method, retryCount: rateLimitAttempt) {
                let delay = SpotifyHTTPRetryPolicy.retryAfterSeconds(
                    from: http.value(forHTTPHeaderField: "Retry-After"))
                try await Task.sleep(for: .seconds(delay))
                return try await send(method, path: path, query: query, body: body,
                                      allowAuthRetry: allowAuthRetry,
                                      rateLimitAttempt: rateLimitAttempt + 1)
            }
            throw SpotifyAPIError.http(429, String(data: data, encoding: .utf8) ?? "")
        default:
            throw SpotifyAPIError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
    }

    private func refreshTokens(_ current: TokenSet) async throws -> TokenSet {
        if sessionInvalidated { throw SpotifyAPIError.sessionExpired }
        if let refreshTask {
            return try await completeRefresh(refreshTask, epoch: sessionEpoch)
        }
        let clientID = UserDefaults.standard.string(forKey: SpotifyAuthConfig.clientIDDefaultsKey) ?? ""
        let epoch = sessionEpoch
        let task = Task<TokenSet, Error> {
            try await TokenEndpoint.refresh(current, clientID: clientID)
        }
        refreshTask = task
        defer { refreshTask = nil }
        return try await completeRefresh(task, epoch: epoch)
    }

    private func completeRefresh(_ task: Task<TokenSet, Error>, epoch: Int) async throws -> TokenSet {
        do {
            let fresh = try await task.value
            guard epoch == sessionEpoch, !sessionInvalidated else {
                throw sessionInvalidated ? SpotifyAPIError.sessionExpired : CancellationError()
            }
            guard KeychainStore.load() != nil else { throw CancellationError() }
            try KeychainStore.save(fresh)
            return fresh
        } catch let error as SpotifyAPIError {
            throw error
        } catch is CancellationError {
            if sessionInvalidated { throw SpotifyAPIError.sessionExpired }
            throw CancellationError()
        } catch let error as AuthError where error.isDefinitiveRefreshFailure {
            invalidateSession()
            throw SpotifyAPIError.sessionExpired
        } catch {
            throw error
        }
    }

    private func invalidateSession() {
        guard !sessionInvalidated else { return }
        sessionInvalidated = true
        sessionEpoch += 1
        refreshTask?.cancel()
        refreshTask = nil
        NotificationCenter.default.post(name: .spotifySessionInvalidated, object: nil)
    }
}
