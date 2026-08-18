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
        /// Terminal for this local session. The app keeps working in remote
        /// control; the owner surfaces a banner with Retry. Never a dead-end
        /// with no fallback.
        case failed(String)
    }

    private(set) var status: Status = .stopped
    /// True when the last start failed because the binary is missing —
    /// the UI shows the install sheet instead of an error banner.
    private(set) var isNotInstalled = false
    /// Called when the engine gives up (crash-restart budget exhausted or a
    /// failure that needs the user), so the owner can surface a banner and
    /// fall back to remote control.
    var onUnrecoverableFailure: ((String) -> Void)?
    /// Called after a successful launch (including crash relaunch) so the
    /// owner can capture the Connect device id.
    var onBecameRunning: (() -> Void)?

    private var process: Process?
    private var startTask: Task<Void, Never>?
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
        await runStart(resetAttempts: true)
    }

    func stop() {
        startTask?.cancel()
        startTask = nil
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

    private func runStart(resetAttempts: Bool) async {
        switch LibrespotStartGate.role(hasInFlightStart: startTask != nil, hasLiveProcess: process != nil) {
        case .joinInFlight:
            await startTask?.value
            return
        case .alreadyRunning:
            return
        case .lead:
            break
        }

        let task = Task { @MainActor [weak self] in
            await self?.performStart(resetAttempts: resetAttempts)
        }
        startTask = task
        await task.value
        if startTask == task {
            startTask = nil
        }
    }

    private func performStart(resetAttempts: Bool) async {
        if resetAttempts {
            restartAttempts = 0
        }
        cancelPendingRestart()
        isNotInstalled = false
        status = .starting
        await reapStaleInstances()
        guard !Task.isCancelled else { return }

        do {
            let installation = try LibrespotLocator.locate()
            if installation.versionIsUnknown {
                logger.warning(
                    "librespot version unknown (\(installation.version, privacy: .public)); minimum is 0.8.0, proceeding"
                )
            }
            recentStderr = []
            try launch(installation: installation)
            guard !Task.isCancelled else { return }
            logger.info("launched \(installation.version, privacy: .public) from \(installation.binaryURL.path, privacy: .public)")
            status = .running(version: installation.version)
            onBecameRunning?()
        } catch {
            logger.error("start failed: \(error.localizedDescription, privacy: .public)")
            if case LibrespotLocator.LocatorError.notInstalled = error {
                isNotInstalled = true
            }
            status = .failed(error.localizedDescription)
            closeLifetimePipe()
            process = nil
            if !resetAttempts {
                onUnrecoverableFailure?(error.localizedDescription)
            }
        }
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
        let librespotArguments = LibrespotLaunchFlags.processArguments(
            cachePath: cacheURL.path,
            enableOAuth: needsAuthorization,
            deviceName: Self.deviceName
        )

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
        let wasIntentionalStop = process == nil
        guard !wasIntentionalStop else { return }
        process = nil
        closeLifetimePipe()
        let detail = recentStderr.suffix(3).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let kind = LibrespotRestartPolicy.classify(
            terminationStatus: code,
            stderr: detail,
            wasIntentionalStop: false
        )
        let uptime = launchDate.map { Date().timeIntervalSince($0) } ?? 0
        let outcome = LibrespotRestartPolicy.decide(
            kind: kind,
            uptime: uptime,
            attemptsSoFar: restartAttempts,
            stderrDetail: detail
        )
        restartAttempts = outcome.attempts

        switch outcome.decision {
        case .ignore:
            return
        case .resetCredentialsAndFail(let message):
            if let dir = try? cacheDirectory() {
                try? FileManager.default.removeItem(at: dir.appending(path: "credentials.json"))
            }
            degradeToRemoteControl(message: message)
        case .restart(let delay, let attempt):
            logger.info("restarting in \(delay)s (attempt \(attempt)/\(LibrespotRestartPolicy.delaysSeconds.count))")
            status = .starting
            restartTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                await self?.runStart(resetAttempts: false)
            }
        case .degradeToRemote(let message):
            degradeToRemoteControl(message: message)
        }
    }

    private func degradeToRemoteControl(message: String) {
        status = .failed(message)
        closeLifetimePipe()
        process = nil
        onUnrecoverableFailure?(message)
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
