import Foundation
import Observation

/// Runs librespot as a supervised child process so this Mac shows up as a
/// Spotify Connect device named "SpotifyLite" — no official Spotify app needed.
/// Authentication reuses the app's OAuth token (requires the `streaming` scope
/// and a Premium account). The token goes in the environment, never in argv.
@MainActor
@Observable
final class LibrespotEngine {
    static let deviceName = "SpotifyLite"

    enum Status: Equatable {
        case stopped
        case starting
        case running(version: String)
        case failed(String)
    }

    private(set) var status: Status = .stopped
    private var process: Process?
    private var recentStderr: [String] = []

    var isRunning: Bool {
        if case .running = status { return true }
        return false
    }

    func start() async {
        guard process == nil else { return }
        status = .starting
        do {
            let installation = try LibrespotLocator.locate()
            let token = try await SpotifyClient.shared.validAccessToken()
            try launch(installation: installation, accessToken: token)
            status = .running(version: installation.version)
        } catch {
            status = .failed(error.localizedDescription)
            process = nil
        }
    }

    func stop() {
        guard let process else { return }
        // Clear first so terminationHandler treats this as an intentional stop.
        self.process = nil
        process.terminationHandler = nil
        process.terminate()
        status = .stopped
    }

    private func launch(installation: LibrespotLocator.Installation, accessToken: String) throws {
        let cacheURL = try cacheDirectory()

        let process = Process()
        process.executableURL = installation.binaryURL
        process.arguments = [
            "--name", Self.deviceName,
            "--backend", "rodio",
            "--zeroconf-backend", "dns-sd",
            "--device-type", "computer",
            "--bitrate", "320",
            "--system-cache", cacheURL.path,
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["LIBRESPOT_ACCESS_TOKEN"] = accessToken
        process.environment = environment

        process.standardOutput = FileHandle.nullDevice
        let stderr = Pipe()
        process.standardError = stderr
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let line = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in self?.recordStderr(line) }
        }

        process.terminationHandler = { [weak self] finished in
            Task { @MainActor in self?.handleTermination(code: finished.terminationStatus) }
        }

        try process.run()
        self.process = process
    }

    private func handleTermination(code: Int32) {
        guard process != nil else { return }  // stop() already handled it
        process = nil
        let detail = recentStderr.suffix(3).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        status = .failed(detail.isEmpty
            ? "librespot exited with code \(code)."
            : "librespot exited with code \(code): \(detail)")
    }

    private func recordStderr(_ chunk: String) {
        for line in chunk.split(separator: "\n") where !line.isEmpty {
            recentStderr.append(String(line))
        }
        if recentStderr.count > 20 {
            recentStderr.removeFirst(recentStderr.count - 20)
        }
    }

    /// Holds librespot's reusable credential — sensitive, so owner-only permissions.
    private func cacheDirectory() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory,
                                               in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        let dir = base.appending(path: "SpotifyLite/librespot")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        return dir
    }
}
