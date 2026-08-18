import Darwin
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

    /// Restart-on-crash budget: 1 s, 2 s, 4 s, then give up until the user retries.
    static let restartDelaysSeconds: [Int] = [1, 2, 4]
    /// A crash after this much uptime starts a fresh retry budget.
    static let healthyUptimeSeconds: TimeInterval = 60

    private(set) var status: Status = .stopped
    /// True when the last start failed because the binary is missing —
    /// the UI shows the install sheet instead of an error banner.
    private(set) var isNotInstalled = false
    /// Called when the engine gives up (crash-restart budget exhausted or a
    /// failure that needs the user), so the owner can surface a banner.
    var onUnrecoverableFailure: ((String) -> Void)?

    private var process: Process?
    /// Write end of the wrapper stdin pipe. Closing it (or dying) kills librespot.
    private var lifetimeStdin: FileHandle?
    private var recentStderr: [String] = []
    private var restartAttempts = 0
    private var restartTask: Task<Void, Never>?
    private var launchDate: Date?
    private let logger = Logger(subsystem: "com.lucas.spotifylite", category: "librespot")

    var isRunning: Bool {
        if case .running = status { return true }
        return false
    }

    func start() async {
        guard process == nil else { return }
        cancelPendingRestart()
        restartAttempts = 0
        isNotInstalled = false
        await reapStaleInstances()
        status = .starting
        do {
            let installation = try LibrespotLocator.locate()
            try launch(installation: installation)
            logger.info("launched \(installation.version, privacy: .public) from \(installation.binaryURL.path, privacy: .public)")
            status = .running(version: installation.version)
        } catch {
            logger.error("start failed: \(error.localizedDescription, privacy: .public)")
            if case LibrespotLocator.LocatorError.notInstalled = error {
                isNotInstalled = true
            }
            status = .failed(error.localizedDescription)
            closeLifetimePipe()
            process = nil
        }
    }

    func stop() {
        cancelPendingRestart()
        guard let process else {
            status = .stopped
            return
        }
        // Clear first so terminationHandler treats this as an intentional stop.
        self.process = nil
        process.terminationHandler = nil
        closeLifetimePipe()
        process.terminate()
        status = .stopped
    }

    /// True once librespot has cached reusable credentials from a previous login.
    var needsAuthorization: Bool {
        guard let dir = try? cacheDirectory() else { return true }
        return !FileManager.default.fileExists(atPath: dir.appending(path: "credentials.json").path)
    }

    /// SIGTERM leftover SpotifyLite librespot processes (orphans from crash /
    /// Xcode stop). Does not touch `credentials.json`.
    private func reapStaleInstances() async {
        let cachePath: String
        do {
            cachePath = try cacheDirectory().path
        } catch {
            return
        }
        let pids = LibrespotProcessLifetime.stalePIDs(
            deviceName: Self.deviceName, cachePath: cachePath)
        guard !pids.isEmpty else { return }
        logger.info("reaping \(pids.count, privacy: .public) stale librespot process(es)")
        LibrespotProcessLifetime.terminate(pids: pids)
        try? await Task.sleep(for: .milliseconds(300))
        let remaining = LibrespotProcessLifetime.stillRunning(pids)
        if !remaining.isEmpty {
            LibrespotProcessLifetime.terminate(pids: remaining, signal: SIGKILL)
        }
    }

    private func closeLifetimePipe() {
        try? lifetimeStdin?.close()
        lifetimeStdin = nil
    }

    private func launch(installation: LibrespotLocator.Installation) throws {
        let cacheURL = try cacheDirectory()

        var librespotArguments = [
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
            librespotArguments.append("--enable-oauth")
        }

        let lifetimePipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: LibrespotProcessLifetime.bashPath)
        process.arguments = LibrespotProcessLifetime.wrapperArguments(
            binaryPath: installation.binaryURL.path,
            librespotArguments: librespotArguments
        )
        process.standardInput = lifetimePipe
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
        self.lifetimeStdin = lifetimePipe.fileHandleForWriting
        self.launchDate = Date()
    }

    private func handleTermination(code: Int32) {
        logger.error("terminated with code \(code)")
        guard process != nil else { return }  // stop() already handled it
        process = nil
        closeLifetimePipe()
        let detail = recentStderr.suffix(3).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if detail.contains("INVALID_CREDENTIALS") || detail.contains("Login request was denied") {
            // Stored credentials went bad; drop them so the next start
            // re-runs the browser authorization instead of failing forever.
            // Restarting automatically would pop the OAuth browser unasked.
            if let dir = try? cacheDirectory() {
                try? FileManager.default.removeItem(at: dir.appending(path: "credentials.json"))
            }
            let message = "Spotify rejected the saved credentials. They were reset — try playing again to re-authorize."
            status = .failed(message)
            onUnrecoverableFailure?(message)
            return
        }

        // Unexpected death: restart with backoff before giving up.
        if let launchDate, Date().timeIntervalSince(launchDate) > Self.healthyUptimeSeconds {
            restartAttempts = 0
        }
        if restartAttempts < Self.restartDelaysSeconds.count {
            restartAttempts += 1
            let delay = Self.restartDelaysSeconds[restartAttempts - 1]
            logger.info("restarting in \(delay)s (attempt \(self.restartAttempts)/\(Self.restartDelaysSeconds.count))")
            status = .starting
            restartTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                await self?.relaunchAfterCrash()
            }
            return
        }

        let message = detail.isEmpty
            ? "Local playback stopped (librespot exited with code \(code))."
            : "Local playback stopped: \(detail)"
        status = .failed(message)
        onUnrecoverableFailure?(message)
    }

    private func relaunchAfterCrash() async {
        // stop() or a user start() may have raced the backoff sleep.
        guard process == nil, status == .starting else { return }
        do {
            let installation = try LibrespotLocator.locate()
            try launch(installation: installation)
            logger.info("relaunched after crash (attempt \(self.restartAttempts))")
            status = .running(version: installation.version)
        } catch {
            logger.error("relaunch failed: \(error.localizedDescription, privacy: .public)")
            status = .failed(error.localizedDescription)
            onUnrecoverableFailure?(error.localizedDescription)
        }
    }

    private func cancelPendingRestart() {
        restartTask?.cancel()
        restartTask = nil
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
