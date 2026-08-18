import Foundation
import Network

/// Mini HTTP server on 127.0.0.1 that waits for Spotify's redirect with the
/// authorization code, responds with a "return to the app" page, and shuts down.
final class LoopbackServer: @unchecked Sendable {
    enum ServerError: Error, Equatable {
        case portInUse
        case userDenied
        case badCallback
        case stateMismatch
        case cancelled
    }

    private var listener: NWListener?
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String, Error>?
    private var isStopped = false

    func waitForCode(port: UInt16, expectedState: String) async throws -> String {
        lock.lock()
        let alreadyStopped = isStopped
        lock.unlock()
        if alreadyStopped { throw ServerError.cancelled }

        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1",
                                                           port: NWEndpoint.Port(rawValue: port)!)
        let listener: NWListener
        do {
            listener = try NWListener(using: params)
        } catch {
            throw ServerError.portInUse
        }
        self.listener = listener

        defer { stop() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.lock.lock()
                if self.isStopped {
                    self.lock.unlock()
                    continuation.resume(throwing: ServerError.cancelled)
                    return
                }
                self.continuation = continuation
                self.lock.unlock()
                listener.stateUpdateHandler = { [weak self] state in
                    if case .failed = state { self?.finish(.failure(ServerError.portInUse)) }
                }
                listener.newConnectionHandler = { [weak self] connection in
                    connection.start(queue: .main)
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
                        guard let self, let data,
                              let request = String(data: data, encoding: .utf8) else {
                            connection.cancel()
                            return
                        }
                        self.handle(request: request, on: connection, expectedState: expectedState)
                    }
                }
                listener.start(queue: .main)
            }
        } onCancel: {
            self.stop()
        }
    }

    func stop() {
        finish(.failure(ServerError.cancelled))
        lock.lock()
        let activeListener = listener
        listener = nil
        lock.unlock()
        activeListener?.cancel()
    }

    private func handle(request: String, on connection: NWConnection, expectedState: String) {
        guard let requestLine = request.components(separatedBy: "\r\n").first,
              requestLine.hasPrefix("GET "),
              let target = requestLine.components(separatedBy: " ").dropFirst().first,
              let components = URLComponents(string: target),
              components.path == "/callback" else {
            respond(connection, status: "404 Not Found", body: "")
            return
        }

        let items = components.queryItems ?? []
        let code = items.first { $0.name == "code" }?.value
        let state = items.first { $0.name == "state" }?.value
        let error = items.first { $0.name == "error" }?.value

        if let error {
            respond(connection, status: "200 OK", body: Self.page(
                title: "Sign-in cancelled",
                message: "Spotify returned: \(error). You can close this tab and try again."))
            finish(.failure(ServerError.userDenied))
        } else if state != expectedState {
            respond(connection, status: "400 Bad Request", body: Self.page(
                title: "Security error",
                message: "The state parameter does not match. Close this tab and try again."))
            finish(.failure(ServerError.stateMismatch))
        } else if let code {
            respond(connection, status: "200 OK", body: Self.page(
                title: "You're all set",
                message: "You're signed in. Return to SpotifyLite — you can close this tab."))
            finish(.success(code))
        } else {
            respond(connection, status: "400 Bad Request", body: Self.page(
                title: "Invalid callback",
                message: "The authorization code did not arrive. Close this tab and try again."))
            finish(.failure(ServerError.badCallback))
        }
    }

    private func finish(_ result: Result<String, Error>) {
        lock.lock()
        isStopped = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        switch result {
        case .success(let code): continuation?.resume(returning: code)
        case .failure(let error): continuation?.resume(throwing: error)
        }
    }

    private func respond(_ connection: NWConnection, status: String, body: String) {
        let payload = Data(body.utf8)
        let header = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(payload.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(header.utf8) + payload,
                        completion: .contentProcessed { _ in connection.cancel() })
    }

    private static func page(title: String, message: String) -> String {
        """
        <!doctype html><html lang="en"><meta charset="utf-8">
        <title>\(title) · SpotifyLite</title>
        <body style="font-family:-apple-system,sans-serif;display:grid;place-items:center;height:100vh;margin:0;background:#121212;color:#fff">
        <div style="text-align:center;max-width:26rem;padding:1rem">
        <h1 style="font-size:1.4rem">\(title)</h1>
        <p style="color:#b3b3b3">\(message)</p>
        </div></body></html>
        """
    }
}
