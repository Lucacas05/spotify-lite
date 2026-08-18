import Foundation

/// Why the app would start librespot. Map #1 / issue #16: remote control is
/// the default; only an explicit opt-in after per-account consent may launch
/// a process. A 404 / missing Connect device never does. Locator / brew
/// discovery success also never does.
enum LocalPlaybackStartReason: Equatable {
    case explicitOptIn
    case missingDevice
    case signIn
}

enum LocalPlaybackStartPolicy {
    static func shouldLaunchLibrespot(
        for reason: LocalPlaybackStartReason,
        hasAccountConsent: Bool
    ) -> Bool {
        switch reason {
        case .explicitOptIn:
            return hasAccountConsent
        case .missingDevice, .signIn:
            return false
        }
    }
}
