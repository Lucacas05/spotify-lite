import Foundation
import Network

/// Mini servidor HTTP en 127.0.0.1 que espera el redirect de Spotify con el
/// authorization code, responde una página de "vuelve a la app" y se apaga.
final class LoopbackServer: @unchecked Sendable {
    enum ServerError: Error {
        case portInUse
        case userDenied
        case badCallback
        case stateMismatch
    }

    private var listener: NWListener?
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String, Error>?

    func waitForCode(port: UInt16, expectedState: String) async throws -> String {
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
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
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
    }

    func stop() {
        listener?.cancel()
        listener = nil
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
                title: "Inicio de sesión cancelado",
                message: "Spotify devolvió: \(error). Puedes cerrar esta pestaña e intentarlo de nuevo."))
            finish(.failure(ServerError.userDenied))
        } else if state != expectedState {
            respond(connection, status: "400 Bad Request", body: Self.page(
                title: "Error de seguridad",
                message: "El parámetro state no coincide. Cierra esta pestaña e intenta de nuevo."))
            finish(.failure(ServerError.stateMismatch))
        } else if let code {
            respond(connection, status: "200 OK", body: Self.page(
                title: "Listo",
                message: "Ya iniciaste sesión. Vuelve a SpotifyLite — puedes cerrar esta pestaña."))
            finish(.success(code))
        } else {
            respond(connection, status: "400 Bad Request", body: Self.page(
                title: "Callback inválido",
                message: "No llegó el código de autorización. Cierra esta pestaña e intenta de nuevo."))
            finish(.failure(ServerError.badCallback))
        }
    }

    private func finish(_ result: Result<String, Error>) {
        lock.lock()
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
        <!doctype html><html lang="es"><meta charset="utf-8">
        <title>\(title) · SpotifyLite</title>
        <body style="font-family:-apple-system,sans-serif;display:grid;place-items:center;height:100vh;margin:0;background:#121212;color:#fff">
        <div style="text-align:center;max-width:26rem;padding:1rem">
        <h1 style="font-size:1.4rem">\(title)</h1>
        <p style="color:#b3b3b3">\(message)</p>
        </div></body></html>
        """
    }
}
