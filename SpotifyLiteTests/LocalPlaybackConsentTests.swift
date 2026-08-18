import XCTest
@testable import SpotifyLite

final class LocalPlaybackConsentTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var store: LocalPlaybackConsentStore!
    private var applicationSupport: URL!

    override func setUp() {
        super.setUp()
        suiteName = "SpotifyLiteTests.LocalPlaybackConsent.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        store = LocalPlaybackConsentStore(defaults: defaults)
        applicationSupport = FileManager.default.temporaryDirectory
            .appending(path: "SpotifyLiteTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: applicationSupport, withIntermediateDirectories: true)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: applicationSupport)
        super.tearDown()
    }

    func testHttp404IdentifiesMissingDeviceAndIsNotAStartTrigger() {
        XCTAssertTrue(SpotifyAPIError.http(404, "No active device").isNoActiveDevice)
        XCTAssertFalse(SpotifyAPIError.http(403, "").isNoActiveDevice)
        XCTAssertFalse(
            LocalPlaybackStartPolicy.shouldLaunchLibrespot(
                for: .missingDevice, hasAccountConsent: false)
        )
        XCTAssertFalse(
            LocalPlaybackStartPolicy.shouldLaunchLibrespot(
                for: .missingDevice, hasAccountConsent: true)
        )
        XCTAssertFalse(
            LocalPlaybackStartPolicy.shouldLaunchLibrespot(
                for: .signIn, hasAccountConsent: true)
        )
    }

    func testExplicitOptInStartsOnlyAfterConsent() {
        XCTAssertFalse(
            LocalPlaybackStartPolicy.shouldLaunchLibrespot(
                for: .explicitOptIn, hasAccountConsent: false)
        )
        XCTAssertTrue(
            LocalPlaybackStartPolicy.shouldLaunchLibrespot(
                for: .explicitOptIn, hasAccountConsent: true)
        )
    }

    func testConsentIsStoredPerAccount() {
        XCTAssertFalse(store.hasConsent(for: "user-a"))
        store.grantConsent(for: "user-a")
        XCTAssertTrue(store.hasConsent(for: "user-a"))
        XCTAssertFalse(store.hasConsent(for: "user-b"))
    }

    func testConsentSurvivesSignOutOfLastUserPointer() {
        store.grantConsent(for: "user-a")
        store.rememberSignedInUser("user-a")
        store.clearLastSignedInUser()
        XCTAssertNil(store.lastSignedInUserID)
        XCTAssertTrue(store.hasConsent(for: "user-a"))
    }

    func testEmptyUserIDIsRejected() {
        store.grantConsent(for: "   ")
        XCTAssertFalse(store.hasConsent(for: "   "))
        XCTAssertNil(LibrespotAccountCache.sanitizedAccountID("   "))
        XCTAssertNil(LibrespotAccountCache.sanitizedAccountID("..."))
    }

    func testSanitizationBlocksPathTraversal() throws {
        XCTAssertEqual(LibrespotAccountCache.sanitizedAccountID("../other"), "___other")
        let dir = try LibrespotAccountCache.cacheDirectory(
            for: "../other", applicationSupport: applicationSupport)
        XCTAssertEqual(dir.lastPathComponent, "___other")
        XCTAssertEqual(dir.deletingLastPathComponent().lastPathComponent, "accounts")
    }

    func testWipeDeletesOnlyThatAccountAndLegacyCredentials() throws {
        let userA = "user-a"
        let userB = "user-b"
        let aURL = try LibrespotAccountCache.credentialsURL(
            for: userA, applicationSupport: applicationSupport)
        let bURL = try LibrespotAccountCache.credentialsURL(
            for: userB, applicationSupport: applicationSupport)
        let legacyURL = LibrespotAccountCache.legacyCredentialsURL(
            applicationSupport: applicationSupport)

        try FileManager.default.createDirectory(
            at: aURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: bURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: legacyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("a-creds".utf8).write(to: aURL)
        try Data("b-creds".utf8).write(to: bURL)
        try Data("legacy-creds".utf8).write(to: legacyURL)

        LibrespotAccountCache.wipeCredentials(
            for: userA, applicationSupport: applicationSupport)

        XCTAssertFalse(FileManager.default.fileExists(atPath: aURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path))
        XCTAssertEqual(try String(contentsOf: bURL, encoding: .utf8), "b-creds")
    }

    func testWipeWithNilUserStillDeletesLegacyCredentials() throws {
        let legacyURL = LibrespotAccountCache.legacyCredentialsURL(
            applicationSupport: applicationSupport)
        try FileManager.default.createDirectory(
            at: legacyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("legacy-creds".utf8).write(to: legacyURL)

        LibrespotAccountCache.wipeCredentials(
            for: nil, applicationSupport: applicationSupport)

        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path))
    }

    func testAccountsGetIsolatedCacheDirectories() throws {
        let a = try LibrespotAccountCache.cacheDirectory(
            for: "user-a", applicationSupport: applicationSupport)
        let b = try LibrespotAccountCache.cacheDirectory(
            for: "user-b", applicationSupport: applicationSupport)
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a.lastPathComponent, "user-a")
        XCTAssertEqual(b.lastPathComponent, "user-b")
    }

    func testMenuTitleStaysSetupUntilConsent() {
        XCTAssertEqual(
            LocalPlaybackMenuCopy.itemTitle(hasConsent: false, isStarting: false),
            "This Mac (set up…)"
        )
        XCTAssertEqual(
            LocalPlaybackMenuCopy.itemTitle(hasConsent: true, isStarting: false),
            "Play on this Mac"
        )
        XCTAssertEqual(
            LocalPlaybackMenuCopy.itemTitle(hasConsent: false, isStarting: true),
            "Starting local player…"
        )
        XCTAssertEqual(
            LocalPlaybackMenuCopy.itemTitle(hasConsent: true, isStarting: true),
            "Starting local player…"
        )
        XCTAssertEqual(LocalPlaybackMenuCopy.brewInstallCommand, "brew install librespot")
    }
}
