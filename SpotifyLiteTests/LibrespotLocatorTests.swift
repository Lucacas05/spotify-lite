import XCTest
@testable import SpotifyLite

final class LibrespotLocatorTests: XCTestCase {
    func testParsesRealVersionOutput() throws {
        let output = "librespot 0.8.0 c8897dd (Built on 2025-11-10, Build ID: 1762793321, Profile: release)"
        let version = try XCTUnwrap(LibrespotLocator.parseVersion(from: output))
        XCTAssertEqual(version.major, 0)
        XCTAssertEqual(version.minor, 8)
        XCTAssertEqual(version.patch, 0)
    }

    func testParsesTwoComponentVersion() throws {
        let version = try XCTUnwrap(LibrespotLocator.parseVersion(from: "librespot 0.9"))
        XCTAssertEqual(version.major, 0)
        XCTAssertEqual(version.minor, 9)
        XCTAssertEqual(version.patch, 0)
    }

    func testUnparseableOutputReturnsNil() {
        XCTAssertNil(LibrespotLocator.parseVersion(from: "librespot HEAD-abcdef"))
        XCTAssertNil(LibrespotLocator.parseVersion(from: ""))
    }

    func testMinimumVersionGate() {
        XCTAssertTrue(LibrespotLocator.meetsMinimum((major: 0, minor: 8, patch: 0)))
        XCTAssertTrue(LibrespotLocator.meetsMinimum((major: 0, minor: 8, patch: 1)))
        XCTAssertTrue(LibrespotLocator.meetsMinimum((major: 1, minor: 0, patch: 0)))
        // Numeric — not lexicographic — comparison: 0.10.0 > 0.8.0.
        XCTAssertTrue(LibrespotLocator.meetsMinimum((major: 0, minor: 10, patch: 0)))
        XCTAssertFalse(LibrespotLocator.meetsMinimum((major: 0, minor: 7, patch: 1)))
        XCTAssertFalse(LibrespotLocator.meetsMinimum((major: 0, minor: 7, patch: 99)))
    }

    func testUnsupportedVersionMessageMentionsBrewUpgrade() {
        let message = LibrespotLocator.LocatorError.unsupportedVersion(found: "0.6.0")
            .errorDescription ?? ""
        XCTAssertTrue(message.contains("0.6.0"))
        XCTAssertTrue(message.contains("brew upgrade librespot"))
    }
}
