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

    struct Installation {
        let binaryURL: URL
        let version: String
    }

    enum LocatorError: LocalizedError {
        case notInstalled
        case notRunnable(String)

        var errorDescription: String? {
            switch self {
            case .notInstalled:
                return "librespot is not installed. Run `brew install librespot` and try again."
            case .notRunnable(let detail):
                return "librespot could not be run: \(detail)"
            }
        }
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
        return Installation(binaryURL: url, version: version.isEmpty ? "unknown" : version)
    }
}
