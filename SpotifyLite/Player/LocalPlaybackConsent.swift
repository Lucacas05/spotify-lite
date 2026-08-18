import Foundation

/// Why the app would start librespot. Map #1 / issue #16: remote control is
/// the default; only an explicit opt-in after per-account consent may launch
/// a process. A 404 / missing Connect device never does.
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

enum LocalPlaybackMenuCopy {
    static let setupTitle = "This Mac (set up…)"
    static let playTitle = "Play on this Mac"
    static let startingTitle = "Starting local player…"
    static let brewInstallCommand = "brew install librespot"

    static func itemTitle(hasConsent: Bool, isStarting: Bool) -> String {
        if isStarting { return startingTitle }
        return hasConsent ? playTitle : setupTitle
    }
}

/// Per-account consent to experimental local playback. Not a secret: it only
/// records that this Spotify user already accepted the ToS/warning sheet.
struct LocalPlaybackConsentStore {
    static let consentedUserIDsKey = "librespotConsentedUserIDs"
    static let lastUserIDKey = "librespotLastSpotifyUserID"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func hasConsent(for userID: String) -> Bool {
        guard let id = Self.normalizedUserID(userID) else { return false }
        return consentedUserIDs.contains(id)
    }

    func grantConsent(for userID: String) {
        guard let id = Self.normalizedUserID(userID) else { return }
        var ids = consentedUserIDs
        ids.insert(id)
        consentedUserIDs = ids
    }

    var lastSignedInUserID: String? {
        defaults.string(forKey: Self.lastUserIDKey).flatMap(Self.normalizedUserID)
    }

    func rememberSignedInUser(_ userID: String) {
        guard let id = Self.normalizedUserID(userID) else { return }
        defaults.set(id, forKey: Self.lastUserIDKey)
    }

    func clearLastSignedInUser() {
        defaults.removeObject(forKey: Self.lastUserIDKey)
    }

    private var consentedUserIDs: Set<String> {
        get {
            Set(defaults.stringArray(forKey: Self.consentedUserIDsKey) ?? [])
        }
        nonmutating set {
            defaults.set(Array(newValue).sorted(), forKey: Self.consentedUserIDsKey)
        }
    }

    static func normalizedUserID(_ userID: String) -> String? {
        let trimmed = userID.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// On-disk layout for librespot's reusable credential. Scoped by Spotify
/// account so logout / account switch cannot inherit another user's cache.
enum LibrespotAccountCache {
    static let credentialsFileName = "credentials.json"
    static let relativeRoot = "SpotifyLite/librespot"
    static let accountsFolder = "accounts"

    static func sanitizedAccountID(_ userID: String) -> String? {
        guard let normalized = LocalPlaybackConsentStore.normalizedUserID(userID) else {
            return nil
        }
        let mapped = normalized.map { character -> Character in
            if character.isLetter || character.isNumber || character == "-" || character == "_" {
                return character
            }
            return "_"
        }
        let sanitized = String(mapped)
        guard !sanitized.isEmpty, !sanitized.allSatisfy({ $0 == "_" }) else { return nil }
        return sanitized
    }

    static func defaultApplicationSupport(fileManager: FileManager = .default) throws -> URL {
        try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
    }

    static func legacyCacheDirectory(applicationSupport: URL) -> URL {
        applicationSupport.appending(path: relativeRoot)
    }

    static func cacheDirectory(for userID: String, applicationSupport: URL) throws -> URL {
        guard let accountID = sanitizedAccountID(userID) else {
            throw LibrespotAccountCacheError.missingSpotifyAccount
        }
        return legacyCacheDirectory(applicationSupport: applicationSupport)
            .appending(path: accountsFolder)
            .appending(path: accountID)
    }

    static func credentialsURL(for userID: String, applicationSupport: URL) throws -> URL {
        try cacheDirectory(for: userID, applicationSupport: applicationSupport)
            .appending(path: credentialsFileName)
    }

    static func legacyCredentialsURL(applicationSupport: URL) -> URL {
        legacyCacheDirectory(applicationSupport: applicationSupport)
            .appending(path: credentialsFileName)
    }

    /// Deletes this account's `credentials.json` and the unscoped legacy file
    /// so another Spotify account cannot reuse them. Leaves consent in place.
    static func wipeCredentials(
        for userID: String?,
        applicationSupport: URL,
        fileManager: FileManager = .default
    ) {
        if let userID, let url = try? credentialsURL(for: userID, applicationSupport: applicationSupport) {
            try? fileManager.removeItem(at: url)
        }
        try? fileManager.removeItem(at: legacyCredentialsURL(applicationSupport: applicationSupport))
    }
}

enum LibrespotAccountCacheError: LocalizedError {
    case missingSpotifyAccount

    var errorDescription: String? {
        switch self {
        case .missingSpotifyAccount:
            return "Local playback needs a signed-in Spotify account."
        }
    }
}
