import Foundation

/// Finds the librespot binary installed by the user (Homebrew or manual).
/// A GUI app does not inherit the shell PATH, so known prefixes are probed
/// directly instead of relying on `which`.
enum LibrespotLocator {
    static let candidatePaths = [
        "/opt/homebrew/opt/librespot/bin/librespot",  // Apple Silicon, stable opt prefix
        "/usr/local/opt/librespot/bin/librespot",     // Intel
        "/opt/homebrew/bin/librespot",
        "/usr/local/bin/librespot",
    ]

    /// Oldest release whose CLI contract (flags, OAuth cache) this app targets.
    static let minimumVersion = (major: 0, minor: 8, patch: 0)

    struct Installation {
        let binaryURL: URL
        let version: String
    }

    enum LocatorError: LocalizedError {
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

    /// Fast existence probe, without launching the binary. Used by setup UI.
    static var isInstalled: Bool {
        candidatePaths.contains { FileManager.default.isExecutableFile(atPath: $0) }
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

    /// Probes known paths and validates the binary with `--version`.
    static func locate() throws -> Installation {
        let fileManager = FileManager.default
        guard let path = candidatePaths.first(where: { fileManager.isExecutableFile(atPath: $0) }) else {
            throw LocatorError.notInstalled
        }
        let url = URL(fileURLWithPath: path)

        let process = Process()
        process.executableURL = url
        process.arguments = ["--version"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            throw LocatorError.notRunnable(error.localizedDescription)
        }
        process.waitUntilExit()
        let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(),
                            encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw LocatorError.notRunnable("`--version` exited with code \(process.terminationStatus)")
        }
        let version = output.trimmingCharacters(in: .whitespacesAndNewlines)
        // Block only versions known to be too old. Newer or unparseable
        // versions proceed; the caller logs the raw string for diagnosis.
        if let parsed = parseVersion(from: version), !meetsMinimum(parsed) {
            throw LocatorError.unsupportedVersion(
                found: "\(parsed.major).\(parsed.minor).\(parsed.patch)")
        }
        return Installation(binaryURL: url, version: version.isEmpty ? "unknown" : version)
    }
}
