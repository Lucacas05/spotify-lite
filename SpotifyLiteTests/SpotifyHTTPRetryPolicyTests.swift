import XCTest
@testable import SpotifyLite

final class SpotifyHTTPRetryPolicyTests: XCTestCase {
    func testAllowsTwoRetriesThenStops() {
        XCTAssertTrue(SpotifyHTTPRetryPolicy.shouldRetryRateLimit(method: "GET", retryCount: 0))
        XCTAssertTrue(SpotifyHTTPRetryPolicy.shouldRetryRateLimit(method: "GET", retryCount: 1))
        XCTAssertFalse(SpotifyHTTPRetryPolicy.shouldRetryRateLimit(method: "GET", retryCount: 2))
        XCTAssertEqual(SpotifyHTTPRetryPolicy.maxRateLimitRetries, 2)
    }

    func testSkipsNonIdempotentPostsIncludingAddToQueue() {
        XCTAssertFalse(SpotifyHTTPRetryPolicy.shouldRetryRateLimit(method: "POST", retryCount: 0))
        XCTAssertFalse(SpotifyHTTPRetryPolicy.shouldRetryRateLimit(method: "post", retryCount: 0))
        XCTAssertTrue(SpotifyHTTPRetryPolicy.shouldRetryRateLimit(method: "PUT", retryCount: 0))
        XCTAssertTrue(SpotifyHTTPRetryPolicy.shouldRetryRateLimit(method: "GET", retryCount: 0))
    }

    func testRetryAfterUsesHeaderSecondsWithoutJitter() {
        XCTAssertEqual(SpotifyHTTPRetryPolicy.retryAfterSeconds(from: "3"), 3)
        XCTAssertEqual(SpotifyHTTPRetryPolicy.retryAfterSeconds(from: nil), 1)
        XCTAssertEqual(SpotifyHTTPRetryPolicy.retryAfterSeconds(from: "nope"), 1)
        XCTAssertEqual(SpotifyHTTPRetryPolicy.retryAfterSeconds(from: "-2"), 0)
    }
}

final class AuthErrorCopyTests: XCTestCase {
    func testTokenRequestFailedDoesNotExposeRawJSON() {
        let message = AuthError.tokenRequestFailed.localizedDescription
        XCTAssertFalse(message.contains("{"))
        XCTAssertFalse(message.contains("invalid_grant"))
        XCTAssertFalse(message.contains("access_token"))
    }

    func testInvalidGrantAndClientAuthErrorsAreDefinitiveRefreshFailures() {
        let revoked = Data(#"{"error":"invalid_grant","error_description":"Refresh token revoked"}"#.utf8)
        XCTAssertTrue(TokenEndpoint.isDefinitiveRefreshRejection(status: 400, data: revoked))
        XCTAssertTrue(TokenEndpoint.isDefinitiveRefreshRejection(status: 401, data: Data()))
        XCTAssertTrue(AuthError.invalidGrant.isDefinitiveRefreshFailure)
    }

    func testTokenEndpointServerErrorIsNotADeadSession() {
        XCTAssertFalse(TokenEndpoint.isDefinitiveRefreshRejection(status: 500, data: Data()))
        XCTAssertFalse(TokenEndpoint.isDefinitiveRefreshRejection(status: 429, data: Data()))
        XCTAssertFalse(AuthError.tokenRequestFailed.isDefinitiveRefreshFailure)
    }
}
