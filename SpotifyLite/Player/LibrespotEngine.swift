import Foundation
import Observation
import os

/// Runs librespot as a supervised child process so this Mac shows up as a
/// Spotify Connect device named "SpotifyLite" — no official Spotify app needed.
///
/// Authentication: librespot's own OAuth flow, NOT the app's token. Tokens
/// issued to a custom client ID pass the classic session login but are then
/// denied by login5 with INVALID_CREDENTIALS when spirc registers the Connect
/// device, so playback never works with them. `--enable-oauth` uses librespot's
/// own client ID (one browser approval), caches reusable credentials in the
/// system cache, and later launches log in silently from that cache.
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
    private let logger = Logger(subsystem: "com.lucas.spotifylite", category: "librespot")

    var isRunning: Bool {
        if case .running = status { return true }
        return false
    }

    func start() async {
        guard process == nil else { return }
        status = .starting
        do {
            let installation = try LibrespotLocator.locate()
            try launch(installation: installation)
            logger.info("launched \(installation.version, privacy: .public) from \(installation.binaryURL.path, privacy: .public)")
            status = .running(version: installation.version)
        } catch {
            logger.error("start failed: \(error.localizedDescription, privacy: .public)")
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

    /// True once librespot has cached reusable credentials from a previous login.
    var needsAuthorization: Bool {
        guard let dir = try? cacheDirectory() else { return true }
        return !FileManager.default.fileExists(atPath: dir.appending(path: "credentials.json").path)
    }

    private func launch(installation: LibrespotLocator.Installation) throws {
        let cacheURL = try cacheDirectory()

        let process = Process()
        process.executableURL = installation.binaryURL
        var arguments = [
            "--name", Self.deviceName,
            "--backend", "rodio",
            "--zeroconf-backend", "dns-sd",
            "--device-type", "computer",
            "--bitrate", "320",
            "--system-cache", cacheURL.path,
        ]
        if needsAuthorization {
            // One-time: librespot opens the default browser so the user can
            // approve access; the resulting credentials land in the cache.
            arguments.append("--enable-oauth")
        }
        process.arguments = arguments

        process.standardOutput = FileHandle.nullDevice
        let stderr = Pipe()
        process.standardError = stderr
        let logFileHandle = try? stderrLogHandle()
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let line = String(data: data, encoding: .utf8) else { return }
            logFileHandle?.write(data)
            Task { @MainActor in self?.recordStderr(line) }
        }

        process.terminationHandler = { [weak self] finished in
            Task { @MainActor in self?.handleTermination(code: finished.terminationStatus) }
        }

        try process.run()
        self.process = process
    }

    private func handleTermination(code: Int32) {
        logger.error("terminated with code \(code)")
        guard process != nil else { return }  // stop() already handled it
        process = nil
        let detail = recentStderr.suffix(3).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if detail.contains("INVALID_CREDENTIALS") || detail.contains("Login request was denied") {
            // Stored credentials went bad; drop them so the next start
            // re-runs the browser authorization instead of failing forever.
            if let dir = try? cacheDirectory() {
                try? FileManager.default.removeItem(at: dir.appending(path: "credentials.json"))
            }
            status = .failed("Spotify rejected the saved credentials. They were reset — try playing again to re-authorize.")
            return
        }
        status = .failed(detail.isEmpty
            ? "librespot exited with code \(code)."
            : "librespot exited with code \(code): \(detail)")
    }

    private func recordStderr(_ chunk: String) {
        for line in chunk.split(separator: "\n") where !line.isEmpty {
            logger.info("\(line, privacy: .public)")
            recentStderr.append(String(line))
        }
        if recentStderr.count > 20 {
            recentStderr.removeFirst(recentStderr.count - 20)
        }
    }

    /// Full librespot stderr, for diagnosing failures that the in-app banner truncates.
    private func stderrLogHandle() throws -> FileHandle {
        let url = try cacheDirectory().appending(path: "stderr.log")
        // Fresh log per launch so it only ever holds the current run.
        FileManager.default.createFile(atPath: url.path, contents: nil)
        return try FileHandle(forWritingTo: url)
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
