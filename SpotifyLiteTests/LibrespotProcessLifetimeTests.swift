import XCTest
@testable import SpotifyLite

final class LibrespotProcessLifetimeTests: XCTestCase {
    func testWrapperKeepsBinaryAndFlagsAsSeparateArguments() {
        let args = LibrespotProcessLifetime.wrapperArguments(
            binaryPath: "/opt/homebrew/bin/librespot",
            librespotArguments: ["--name", "SpotifyLite", "--system-cache", "/tmp/cache"]
        )

        XCTAssertEqual(args.first, "-c")
        XCTAssertEqual(args[1], LibrespotProcessLifetime.wrapperScript)
        XCTAssertEqual(args[2], "/opt/homebrew/bin/librespot")
        XCTAssertEqual(
            Array(args.dropFirst(3)),
            ["--name", "SpotifyLite", "--system-cache", "/tmp/cache"]
        )
    }

    func testWrapperKillsChildWhenStdinClosesAndWhenChildExits() {
        let script = LibrespotProcessLifetime.wrapperScript

        XCTAssertTrue(script.contains("trap cleanup EXIT TERM INT HUP"))
        XCTAssertTrue(script.contains("cat >/dev/null"))
        XCTAssertTrue(script.contains("kill -0 \"$child\""))
        XCTAssertTrue(script.contains("kill -0 \"$reader\""))
        XCTAssertTrue(script.contains("exit \"$status\""))
        XCTAssertFalse(script.contains("credentials.json"))
    }

    func testPgrepPatternMatchesNameAndEscapesCachePath() {
        let pattern = LibrespotProcessLifetime.pgrepPattern(
            deviceName: "SpotifyLite",
            cachePath: "/tmp/foo.bar/SpotifyLite/librespot"
        )

        XCTAssertTrue(pattern.contains("bin/librespot"))
        XCTAssertTrue(pattern.contains("--name SpotifyLite"))
        XCTAssertTrue(pattern.contains("--system-cache"))
        XCTAssertTrue(pattern.contains("foo\\.bar"))
        XCTAssertFalse(pattern.contains("credentials.json"))
    }

    func testParsePIDsSkipsJunkAndPIDOne() {
        XCTAssertEqual(
            LibrespotProcessLifetime.parsePIDs("123\n456\n1\nnot-a-pid\n"),
            [123, 456]
        )
        XCTAssertEqual(LibrespotProcessLifetime.parsePIDs(""), [])
        XCTAssertEqual(LibrespotProcessLifetime.parsePIDs("  99  \n"), [99])
    }
}
