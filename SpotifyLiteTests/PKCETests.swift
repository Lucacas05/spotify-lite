import XCTest
@testable import SpotifyLite

final class PKCETests: XCTestCase {
    func testChallengeMatchesRFC7636Example() {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"

        XCTAssertEqual(
            PKCE.challenge(for: verifier),
            "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
        )
    }

    func testGeneratedVerifierIsURLSafeAndHasEnoughEntropy() throws {
        let first = try PKCE.generateVerifier()
        let second = try PKCE.generateVerifier()

        XCTAssertEqual(first.count, 86)
        XCTAssertNotEqual(first, second)
        XCTAssertNotNil(first.wholeMatch(of: /[A-Za-z0-9_-]+/))
        XCTAssertFalse(first.contains("="))
    }

    func testBase64URLEncodingRemovesPaddingAndUnsafeCharacters() {
        XCTAssertEqual(Data([0xfb, 0xff, 0xff]).base64URLEncoded(), "-___")
        XCTAssertEqual(Data([0x66]).base64URLEncoded(), "Zg")
    }
}
