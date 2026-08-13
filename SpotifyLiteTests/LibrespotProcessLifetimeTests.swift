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

    func testWrapperScriptDoesNotTouchCredentials() {
        XCTAssertFalse(LibrespotProcessLifetime.wrapperScript.contains("credentials.json"))
    }

    private func launchWrapper(childArgs: [String]) throws -> (process: Process, stdin: FileHandle) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: LibrespotProcessLifetime.bashPath)
        process.arguments = LibrespotProcessLifetime.wrapperArguments(
            binaryPath: "/bin/sleep", librespotArguments: childArgs)
        let pipe = Pipe()
        process.standardInput = pipe
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return (process, pipe.fileHandleForWriting)
    }

    /// Backgrounded jobs in a non-interactive shell get stdin from /dev/null;
    /// a wrapper whose reader misses the real stdin kills the child instantly.
    func testWrapperKeepsChildAliveWhileParentHoldsStdin() throws {
        let (process, stdin) = try launchWrapper(childArgs: ["60"])
        defer { process.terminate(); try? stdin.close() }

        Thread.sleep(forTimeInterval: 2.0)
        XCTAssertTrue(process.isRunning, "wrapper (and child) must survive while stdin is open")
    }

    func testWrapperKillsChildWhenStdinCloses() throws {
        let (process, stdin) = try launchWrapper(childArgs: ["60"])
        defer { process.terminate() }

        try stdin.close()
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTAssertFalse(process.isRunning, "wrapper must exit soon after stdin closes")
        XCTAssertEqual(process.terminationStatus, 0)
    }

    func testWrapperExitsWhenChildExits() throws {
        let (process, stdin) = try launchWrapper(childArgs: ["0.2"])
        defer { try? stdin.close() }

        let deadline = Date().addingTimeInterval(5)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTAssertFalse(process.isRunning, "wrapper must exit when the child exits on its own")
        XCTAssertEqual(process.terminationStatus, 0)
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
