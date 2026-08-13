import Darwin
import Foundation

/// Keeps the librespot child from outliving SpotifyLite.
///
/// `NSApplication.willTerminateNotification` does not fire on crash, SIGKILL,
/// or Xcode stop, so a direct `Process` child becomes an orphan (~30 MB). The
/// wrapper holds stdin open in the parent; when that pipe closes the shell
/// trap kills librespot. Stale instances are also reaped before every start.
enum LibrespotProcessLifetime {
    static let bashPath = "/bin/bash"

    /// `bash -c` script: `$0` is the librespot binary, `$@` its arguments.
    /// stdin is a pipe kept open by the parent.
    ///
    /// Parent death closes the pipe → `cat` signals the waiting shell →
    /// librespot is killed. librespot death makes `wait` return normally. This
    /// is event-driven: the previous loop spawned `/bin/sleep` four times per
    /// second for the entire playback-engine lifetime.
    ///
    /// In a non-interactive shell, backgrounded jobs get stdin redirected to
    /// /dev/null, so the reader must inherit the real stdin via fd 3 — plain
    /// `cat &` would see instant EOF and kill librespot immediately.
    static let wrapperScript = """
        cleanup() { kill "$child" "$reader" 2>/dev/null || true; wait "$child" 2>/dev/null || true; }
        parent_closed() {
          trap - EXIT TERM INT HUP
          kill "$child" "$reader" 2>/dev/null || true
          wait "$child" 2>/dev/null || true
          exit 0
        }
        trap cleanup EXIT INT HUP
        trap parent_closed TERM
        exec 3<&0
        "$0" "$@" &
        child=$!
        (cat <&3 >/dev/null; kill -TERM "$$") &
        reader=$!
        wait "$child"
        status=$?
        kill "$reader" 2>/dev/null || true
        wait "$reader" 2>/dev/null || true
        trap - EXIT TERM INT HUP
        exit "$status"
        """

    static func wrapperArguments(binaryPath: String, librespotArguments: [String]) -> [String] {
        ["-c", wrapperScript, binaryPath] + librespotArguments
    }

    static func pgrepPattern(deviceName: String, cachePath: String) -> String {
        let name = NSRegularExpression.escapedPattern(for: deviceName)
        let cache = NSRegularExpression.escapedPattern(for: cachePath)
        return "bin/librespot.*--name \(name).*--system-cache \(cache)"
    }

    static func parsePIDs(_ output: String) -> [pid_t] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            pid_t(line.trimmingCharacters(in: .whitespacesAndNewlines))
        }.filter { $0 > 1 }
    }

    /// PIDs of leftover SpotifyLite librespot (or wrapper) processes.
    static func stalePIDs(deviceName: String, cachePath: String) -> [pid_t] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-f", pgrepPattern(deviceName: deviceName, cachePath: cachePath)]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return []
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        return parsePIDs(String(data: data, encoding: .utf8) ?? "")
    }

    static func terminate(pids: [pid_t], signal: Int32 = SIGTERM) {
        for pid in pids {
            kill(pid, signal)
        }
    }

    static func stillRunning(_ pids: [pid_t]) -> [pid_t] {
        pids.filter { kill($0, 0) == 0 }
    }
}
