import Foundation

/// Finds the librespot binary installed by the user (Homebrew or manual).
/// A GUI app does not inherit the shell PATH, so brew is invoked by absolute
/// path and known prefixes are probed directly instead of relying on `which`.
enum LibrespotLocator {
    /// Homebrew / manual fallbacks, used after `brew --prefix` resolution.
    static let candidatePaths = [
        "/opt/homebrew/opt/librespot/bin/librespot",  // Apple Silicon, stable opt prefix
        "/usr/local/opt/librespot/bin/librespot",     // Intel
        "/opt/homebrew/bin/librespot",
        "/usr/local/bin/librespot",
    ]

    static let brewExecutableCandidates = [
        "/opt/homebrew/bin/brew",
        "/usr/local/bin/brew",
    ]

    /// Oldest release whose CLI contract (flags, OAuth cache) this app targets.
    static let minimumVersion = (major: 0, minor: 8, patch: 0)

    struct Installation: Equatable {
        let binaryURL: URL
        let version: String
        let versionIsUnknown: Bool
    }

    enum LocatorError: LocalizedError, Equatable {
        case notInstalled
        case notRunnable(String)
        case unsupportedVersion(found: String)

        var errorDescription: String? {
            switch self {
            case .notInstalled:
                return "librespot is not installed. Run `brew install librespot` and try again."
            case .notRunnable(let detail):
                return "librespot could not be run: \(detail)"
            case .unsupportedVersion(let found):
                return "librespot \(found) is too old (0.8.0 or newer is required). Update it with `brew upgrade librespot`."
            }
        }
    }

    enum VersionVerdict: Equatable {
        case usable(display: String, isUnknown: Bool)
        case tooOld(found: String)
        case notRunnable(detail: String)
    }

    struct BinaryProbe: Equatable {
        let path: String
        let isExecutable: Bool
        let versionExitStatus: Int32
        let versionOutput: String
        let runError: String?
    }

    /// Fast existence probe, without launching the binary. Used by setup UI.
    static var isInstalled: Bool {
        discoveryPaths().contains { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// `brew --prefix` / `brew --prefix librespot` first, then the fixed paths.
    /// Duplicates are dropped, order is preserved.
    static func discoveryPaths(
        brewFormulaPrefix: String? = nil,
        brewRootPrefix: String? = nil,
        fixedPaths: [String] = candidatePaths
    ) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        func add(_ path: String) {
            let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { return }
            result.append(trimmed)
        }
        if let brewFormulaPrefix {
            add(brewFormulaPrefix + "/bin/librespot")
        }
        if let brewRootPrefix {
            add(brewRootPrefix + "/opt/librespot/bin/librespot")
            add(brewRootPrefix + "/bin/librespot")
        }
        for path in fixedPaths {
            add(path)
        }
        return result
    }

    static func parseBrewPrefixOutput(_ output: String, status: Int32) -> String? {
        guard status == 0 else { return nil }
        let line = output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix("/") }
        guard let line, !line.isEmpty else { return nil }
        return line
    }

    /// First `x.y` or `x.y.z` in `--version` output such as
    /// "librespot 0.8.0 c8897dd (Built on …)". nil when unparseable.
    static func parseVersion(from output: String) -> (major: Int, minor: Int, patch: Int)? {
        guard let match = output.firstMatch(of: /(\d+)\.(\d+)(?:\.(\d+))?/),
              let major = Int(match.1),
              let minor = Int(match.2) else { return nil }
        let patch = match.3.flatMap { Int($0) } ?? 0
        return (major, minor, patch)
    }

    static func meetsMinimum(_ version: (major: Int, minor: Int, patch: Int)) -> Bool {
        let found = [version.major, version.minor, version.patch]
        let minimum = [minimumVersion.major, minimumVersion.minor, minimumVersion.patch]
        for (a, b) in zip(found, minimum) where a != b {
            return a > b
        }
        return true
    }

    /// Unknown / unparseable versions are usable. The engine logs a warning;
    /// there is no Settings row, about panel, or version badge. Too-old
    /// versions are rejected so the next candidate can be tried.
    static func evaluateVersion(output: String, exitStatus: Int32) -> VersionVerdict {
        guard exitStatus == 0 else {
            return .notRunnable("`--version` exited with code \(exitStatus)")
        }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let display = trimmed.isEmpty ? "unknown" : trimmed
        if let parsed = parseVersion(from: trimmed) {
            if meetsMinimum(parsed) {
                return .usable(display: display, isUnknown: false)
            }
            return .tooOld(found: "\(parsed.major).\(parsed.minor).\(parsed.patch)")
        }
        return .usable(display: display, isUnknown: true)
    }

    /// First executable that runs and meets 0.8.0 (or has an unknown version).
    static func pickInstallation(from probes: [BinaryProbe]) -> Result<Installation, LocatorError> {
        var lastTooOld: String?
        var lastNotRunnable: String?
        var sawExecutable = false

        for probe in probes {
            guard probe.isExecutable else { continue }
            sawExecutable = true
            if let runError = probe.runError {
                lastNotRunnable = runError
                continue
            }
            switch evaluateVersion(output: probe.versionOutput, exitStatus: probe.versionExitStatus) {
            case .usable(let display, let isUnknown):
                return .success(
                    Installation(
                        binaryURL: URL(fileURLWithPath: probe.path),
                        version: display,
                        versionIsUnknown: isUnknown
                    )
                )
            case .tooOld(let found):
                lastTooOld = found
            case .notRunnable(let detail):
                lastNotRunnable = detail
            }
        }

        if let lastTooOld {
            return .failure(.unsupportedVersion(found: lastTooOld))
        }
        if sawExecutable {
            return .failure(.notRunnable(lastNotRunnable ?? "could not run `--version`"))
        }
        return .failure(.notInstalled)
    }

    /// Probes brew prefixes and fixed paths, then validates `--version`.
    /// Runs off the calling actor: `brew --prefix` and `--version` block on
    /// child processes and must never stall the main actor.
    static func locate() async throws -> Installation {
        try await Task.detached(priority: .userInitiated) {
            try locateBlocking()
        }.value
    }

    /// Synchronous probe. Call from a background context only.
    static func locateBlocking() throws -> Installation {
        let paths = discoveryPaths(
            brewFormulaPrefix: readBrewPrefix(formula: "librespot"),
            brewRootPrefix: readBrewPrefix(formula: nil)
        )
        let fileManager = FileManager.default
        var probes: [BinaryProbe] = []
        for path in paths {
            let executable = fileManager.isExecutableFile(atPath: path)
            if !executable {
                probes.append(
                    BinaryProbe(
                        path: path,
                        isExecutable: false,
                        versionExitStatus: -1,
                        versionOutput: "",
                        runError: nil
                    )
                )
                continue
            }
            do {
                let (output, status) = try runVersion(at: path)
                probes.append(
                    BinaryProbe(
                        path: path,
                        isExecutable: true,
                        versionExitStatus: status,
                        versionOutput: output,
                        runError: nil
                    )
                )
            } catch {
                probes.append(
                    BinaryProbe(
                        path: path,
                        isExecutable: true,
                        versionExitStatus: -1,
                        versionOutput: "",
                        runError: error.localizedDescription
                    )
                )
            }
            if case .success(let installation) = pickInstallation(from: probes) {
                return installation
            }
        }
        switch pickInstallation(from: probes) {
        case .success(let installation):
            return installation
        case .failure(let error):
            throw error
        }
    }

    static func brewURL(
        fileExists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
        pathEnvironment: String? = ProcessInfo.processInfo.environment["PATH"]
    ) -> URL? {
        for path in brewExecutableCandidates where fileExists(path) {
            return URL(fileURLWithPath: path)
        }
        guard let pathEnvironment else { return nil }
        for directory in pathEnvironment.split(separator: ":") {
            let path = "\(directory)/brew"
            if fileExists(path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    private static func readBrewPrefix(formula: String?) -> String? {
        guard let brew = brewURL() else { return nil }
        let process = Process()
        process.executableURL = brew
        process.arguments = formula.map { ["--prefix", $0] } ?? ["--prefix"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        let output = String(
            data: stdout.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        return parseBrewPrefixOutput(output, status: process.terminationStatus)
    }

    private static func runVersion(at path: String) throws -> (String, Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--version"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        let output = String(
            data: stdout.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        return (output, process.terminationStatus)
    }
}
