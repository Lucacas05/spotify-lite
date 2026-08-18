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

    func testDiscoveryPathsPutBrewPrefixAheadOfFixedPathsAndDeduplicate() {
        let paths = LibrespotLocator.discoveryPaths(
            brewFormulaPrefix: "/opt/homebrew/opt/librespot",
            brewRootPrefix: "/opt/homebrew"
        )
        XCTAssertEqual(paths.first, "/opt/homebrew/opt/librespot/bin/librespot")
        XCTAssertEqual(Set(paths).count, paths.count)
        XCTAssertTrue(paths.contains("/opt/homebrew/bin/librespot"))
        XCTAssertTrue(paths.contains("/usr/local/opt/librespot/bin/librespot"))
        XCTAssertTrue(paths.contains("/usr/local/bin/librespot"))
    }

    func testDiscoveryPathsIncludeCustomBrewPrefixBeforeFixedFallbacks() {
        let paths = LibrespotLocator.discoveryPaths(
            brewFormulaPrefix: "/home/linuxbrew/.linuxbrew/opt/librespot",
            brewRootPrefix: "/home/linuxbrew/.linuxbrew"
        )
        XCTAssertEqual(paths[0], "/home/linuxbrew/.linuxbrew/opt/librespot/bin/librespot")
        XCTAssertEqual(paths[1], "/home/linuxbrew/.linuxbrew/bin/librespot")
        XCTAssertEqual(paths[2], "/opt/homebrew/opt/librespot/bin/librespot")
    }

    func testParseBrewPrefixOutputRequiresZeroStatusAndAbsolutePath() {
        XCTAssertEqual(
            LibrespotLocator.parseBrewPrefixOutput("/opt/homebrew\n", status: 0),
            "/opt/homebrew"
        )
        XCTAssertEqual(
            LibrespotLocator.parseBrewPrefixOutput("warning\n/opt/homebrew/opt/librespot\n", status: 0),
            "/opt/homebrew/opt/librespot"
        )
        XCTAssertNil(LibrespotLocator.parseBrewPrefixOutput("/opt/homebrew", status: 1))
        XCTAssertNil(LibrespotLocator.parseBrewPrefixOutput("Error: No available formula", status: 1))
        XCTAssertNil(LibrespotLocator.parseBrewPrefixOutput("", status: 0))
    }

    func testBrewURLPrefersFixedCandidatesThenPATH() {
        XCTAssertEqual(
            LibrespotLocator.brewURL(fileExists: { $0 == "/opt/homebrew/bin/brew" }, pathEnvironment: nil)?.path,
            "/opt/homebrew/bin/brew"
        )
        XCTAssertEqual(
            LibrespotLocator.brewURL(
                fileExists: { $0 == "/opt/custom/bin/brew" },
                pathEnvironment: "/opt/custom/bin:/usr/bin"
            )?.path,
            "/opt/custom/bin/brew"
        )
        XCTAssertNil(
            LibrespotLocator.brewURL(fileExists: { _ in false }, pathEnvironment: "/usr/bin")
        )
    }

    func testUnknownVersionIsUsableAndTooOldIsRejected() {
        XCTAssertEqual(
            LibrespotLocator.evaluateVersion(output: "librespot HEAD-abcdef", exitStatus: 0),
            .usable(display: "librespot HEAD-abcdef", isUnknown: true)
        )
        XCTAssertEqual(
            LibrespotLocator.evaluateVersion(output: "", exitStatus: 0),
            .usable(display: "unknown", isUnknown: true)
        )
        XCTAssertEqual(
            LibrespotLocator.evaluateVersion(output: "librespot 0.8.0", exitStatus: 0),
            .usable(display: "librespot 0.8.0", isUnknown: false)
        )
        XCTAssertEqual(
            LibrespotLocator.evaluateVersion(output: "librespot 0.7.1", exitStatus: 0),
            .tooOld(found: "0.7.1")
        )
        XCTAssertEqual(
            LibrespotLocator.evaluateVersion(output: "librespot 0.8.0", exitStatus: 1),
            .notRunnable("`--version` exited with code 1")
        )
    }

    func testPickInstallationUsesFirstRunnableBinaryThatMeetsMinimum() {
        let probes = [
            LibrespotLocator.BinaryProbe(
                path: "/old/librespot",
                isExecutable: true,
                versionExitStatus: 0,
                versionOutput: "librespot 0.6.0",
                runError: nil
            ),
            LibrespotLocator.BinaryProbe(
                path: "/broken/librespot",
                isExecutable: true,
                versionExitStatus: -1,
                versionOutput: "",
                runError: "killed"
            ),
            LibrespotLocator.BinaryProbe(
                path: "/good/librespot",
                isExecutable: true,
                versionExitStatus: 0,
                versionOutput: "librespot 0.8.0 c8897dd",
                runError: nil
            ),
        ]
        let installation = try? LibrespotLocator.pickInstallation(from: probes).get()
        XCTAssertEqual(installation?.binaryURL.path, "/good/librespot")
        XCTAssertEqual(installation?.versionIsUnknown, false)
    }

    func testPickInstallationAllowsUnknownVersionWithWarningFlag() {
        let probes = [
            LibrespotLocator.BinaryProbe(
                path: "/head/librespot",
                isExecutable: true,
                versionExitStatus: 0,
                versionOutput: "librespot HEAD-abcdef",
                runError: nil
            ),
        ]
        let result = LibrespotLocator.pickInstallation(from: probes)
        let installation = try? result.get()
        XCTAssertEqual(installation?.binaryURL.path, "/head/librespot")
        XCTAssertEqual(installation?.versionIsUnknown, true)
        // Unknown version is log-only: it must not become LocatorError (banner/UI).
        if case .failure = result {
            XCTFail("unknown version must not hard-block")
        }
    }

    func testPickInstallationFailsUnsupportedWhenEveryCandidateIsTooOld() {
        let probes = [
            LibrespotLocator.BinaryProbe(
                path: "/old/librespot",
                isExecutable: true,
                versionExitStatus: 0,
                versionOutput: "librespot 0.7.0",
                runError: nil
            ),
        ]
        let result = LibrespotLocator.pickInstallation(from: probes)
        XCTAssertEqual(result, .failure(.unsupportedVersion(found: "0.7.0")))
    }

    func testPickInstallationReportsNotInstalledWhenNothingIsExecutable() {
        let probes = [
            LibrespotLocator.BinaryProbe(
                path: "/missing/librespot",
                isExecutable: false,
                versionExitStatus: -1,
                versionOutput: "",
                runError: nil
            ),
        ]
        XCTAssertEqual(LibrespotLocator.pickInstallation(from: probes), .failure(.notInstalled))
    }
}
