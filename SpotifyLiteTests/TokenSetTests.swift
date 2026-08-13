import XCTest
@testable import SpotifyLite

final class TokenSetTests: XCTestCase {
    func testTokenExpiringWithinSafetyWindowIsExpired() {
        let tokens = TokenSet(
            accessToken: "access",
            refreshToken: "refresh",
            expiresAt: Date().addingTimeInterval(30)
        )

        XCTAssertTrue(tokens.isExpired)
    }

    func testTokenOutsideSafetyWindowIsUsable() {
        let tokens = TokenSet(
            accessToken: "access",
            refreshToken: "refresh",
            expiresAt: Date().addingTimeInterval(120)
        )

        XCTAssertFalse(tokens.isExpired)
    }

    func testTokenSetRoundTripsThroughCodable() throws {
        let original = TokenSet(
            accessToken: "access",
            refreshToken: "refresh",
            expiresAt: Date(timeIntervalSince1970: 1_800_000_000)
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TokenSet.self, from: data)

        XCTAssertEqual(decoded.accessToken, original.accessToken)
        XCTAssertEqual(decoded.refreshToken, original.refreshToken)
        XCTAssertEqual(decoded.expiresAt, original.expiresAt)
    }
}
