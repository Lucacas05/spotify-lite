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
    /// macOS `/bin/bash` is 3.2 (no `wait -n`), so the loop watches both the
    /// child and the stdin reader. Parent death closes the pipe → `cat` exits
    /// → librespot is killed. librespot death makes bash exit so the engine's
    /// termination handler still fires.
    ///
    /// In a non-interactive shell, backgrounded jobs get stdin redirected to
    /// /dev/null, so the reader must inherit the real stdin via fd 3 — plain
    /// `cat &` sees instant EOF and the wrapper kills librespot at ~0.25s.
    static let wrapperScript = """
        cleanup() { kill "$child" "$reader" 2>/dev/null || true; wait "$child" 2>/dev/null || true; }
        trap cleanup EXIT TERM INT HUP
        exec 3<&0
        "$0" "$@" &
        child=$!
        cat <&3 >/dev/null &
        reader=$!
        while kill -0 "$child" 2>/dev/null && kill -0 "$reader" 2>/dev/null; do
          sleep 0.25
        done
        if kill -0 "$child" 2>/dev/null; then
          kill "$child" 2>/dev/null || true
          wait "$child" 2>/dev/null || true
          exit 0
        fi
        wait "$child"
        status=$?
        kill "$reader" 2>/dev/null || true
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
