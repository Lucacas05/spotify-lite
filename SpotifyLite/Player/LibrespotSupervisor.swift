import Foundation

/// Coordination for the librespot child: one in-flight `start()`, and a
/// small restart budget on crash. No `--onevent` bridge lives here.
enum LibrespotStartRole: Equatable {
    /// Another `start()` is already running; wait for that task.
    case joinInFlight
    /// A live process already exists; do not launch another.
    case alreadyRunning
    /// This caller performs the start.
    case lead
}

enum LibrespotStartGate {
    /// Decide before any `await`. Concurrent callers must share one start.
    static func role(hasInFlightStart: Bool, hasLiveProcess: Bool) -> LibrespotStartRole {
        if hasInFlightStart { return .joinInFlight }
        if hasLiveProcess { return .alreadyRunning }
        return .lead
    }
}

enum LibrespotExitKind: Equatable {
    case intentionalStop
    case credentialsRejected
    case crash(code: Int32)
    case unexpectedCleanExit
}

enum LibrespotRestartDecision: Equatable {
    case ignore
    case resetCredentialsAndFail(message: String)
    case restart(delaySeconds: Int, attempt: Int)
    case degradeToRemote(message: String)
}

enum LibrespotRestartPolicy {
    /// 1 s, 2 s, 4 s — a few attempts, then give up.
    static let delaysSeconds: [Int] = [1, 2, 4]
    static let healthyUptimeSeconds: TimeInterval = 60

    static let credentialsRejectedMessage =
        "Spotify rejected the saved credentials. They were reset — try playing again to re-authorize."

    static func classify(
        terminationStatus: Int32,
        stderr: String,
        wasIntentionalStop: Bool
    ) -> LibrespotExitKind {
        if wasIntentionalStop { return .intentionalStop }
        if stderr.contains("INVALID_CREDENTIALS") || stderr.contains("Login request was denied") {
            return .credentialsRejected
        }
        if terminationStatus != 0 { return .crash(code: terminationStatus) }
        return .unexpectedCleanExit
    }

    /// Crash / nonzero is restartable. Intentional stop, rejected credentials,
    /// and a clean unexpected exit are not. After the delay list is exhausted,
    /// degrade to remote control — never leave `.failed` with no fallback.
    static func decide(
        kind: LibrespotExitKind,
        uptime: TimeInterval,
        attemptsSoFar: Int,
        stderrDetail: String = ""
    ) -> (decision: LibrespotRestartDecision, attempts: Int) {
        switch kind {
        case .intentionalStop:
            return (.ignore, 0)
        case .credentialsRejected:
            return (.resetCredentialsAndFail(message: credentialsRejectedMessage), 0)
        case .unexpectedCleanExit:
            return (.degradeToRemote(message: "Local playback stopped."), attemptsSoFar)
        case .crash(let code):
            var attempts = attemptsSoFar
            if uptime > healthyUptimeSeconds {
                attempts = 0
            }
            if attempts < delaysSeconds.count {
                attempts += 1
                let delay = delaysSeconds[attempts - 1]
                return (.restart(delaySeconds: delay, attempt: attempts), attempts)
            }
            let trimmed = stderrDetail.trimmingCharacters(in: .whitespacesAndNewlines)
            let message = trimmed.isEmpty
                ? "Local playback stopped (librespot exited with code \(code))."
                : "Local playback stopped: \(trimmed)"
            return (.degradeToRemote(message: message), attempts)
        }
    }
}

enum PlaybackActiveDevice {
    /// 204 (nil playback state) or a payload without a device id: nothing is active.
    static func confirmedID(from state: PlaybackState?) -> String? {
        guard let id = state?.device?.id, !id.isEmpty else { return nil }
        return id
    }
}

enum LocalPlaybackStartPolicy {
    /// Honor #16 and map #1: a 404 / missing Connect device never launches librespot.
    static let startOnNoActiveDevice = false
}

enum LibrespotLaunchFlags {
    /// Connect CLI flags. No `--onevent` — that bridge is parked on map #11.
    static func processArguments(
        cachePath: String,
        enableOAuth: Bool,
        deviceName: String = "SpotifyLite"
    ) -> [String] {
        var arguments = [
            "--name", deviceName,
            "--backend", "rodio",
            "--zeroconf-backend", "dns-sd",
            "--device-type", "computer",
            "--bitrate", "320",
            "--system-cache", cachePath,
        ]
        if enableOAuth {
            arguments.append("--enable-oauth")
        }
        return arguments
    }
}
