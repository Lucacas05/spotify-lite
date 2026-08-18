import XCTest
@testable import SpotifyLite

final class LibrespotSupervisorTests: XCTestCase {
    func testStartGateJoinsInFlightAndNeverLeadsASecondProcess() {
        XCTAssertEqual(
            LibrespotStartGate.role(hasInFlightStart: true, hasLiveProcess: false),
            .joinInFlight
        )
        XCTAssertEqual(
            LibrespotStartGate.role(hasInFlightStart: true, hasLiveProcess: true),
            .joinInFlight
        )
        XCTAssertEqual(
            LibrespotStartGate.role(hasInFlightStart: false, hasLiveProcess: true),
            .alreadyRunning
        )
        XCTAssertEqual(
            LibrespotStartGate.role(hasInFlightStart: false, hasLiveProcess: false),
            .lead
        )
    }

    func testCrashIsRestartableWithBackoffThenDegradesToRemote() {
        let first = LibrespotRestartPolicy.decide(
            kind: .crash(code: 1),
            uptime: 3,
            attemptsSoFar: 0
        )
        XCTAssertEqual(first.decision, .restart(delaySeconds: 1, attempt: 1))
        XCTAssertEqual(first.attempts, 1)

        let second = LibrespotRestartPolicy.decide(
            kind: .crash(code: 1),
            uptime: 3,
            attemptsSoFar: first.attempts
        )
        XCTAssertEqual(second.decision, .restart(delaySeconds: 2, attempt: 2))

        let third = LibrespotRestartPolicy.decide(
            kind: .crash(code: 1),
            uptime: 3,
            attemptsSoFar: second.attempts
        )
        XCTAssertEqual(third.decision, .restart(delaySeconds: 4, attempt: 3))

        let giveUp = LibrespotRestartPolicy.decide(
            kind: .crash(code: 9),
            uptime: 3,
            attemptsSoFar: third.attempts,
            stderrDetail: "audio backend died"
        )
        XCTAssertEqual(
            giveUp.decision,
            .degradeToRemote(message: "Local playback stopped: audio backend died")
        )
    }

    func testHealthyUptimeResetsRestartBudget() {
        let outcome = LibrespotRestartPolicy.decide(
            kind: .crash(code: 1),
            uptime: LibrespotRestartPolicy.healthyUptimeSeconds + 1,
            attemptsSoFar: 3
        )
        XCTAssertEqual(outcome.decision, .restart(delaySeconds: 1, attempt: 1))
        XCTAssertEqual(outcome.attempts, 1)
    }

    func testUnexpectedZeroExitDegradesInsteadOfLeavingFailedWithNoFallback() {
        let outcome = LibrespotRestartPolicy.decide(
            kind: .unexpectedCleanExit,
            uptime: 5,
            attemptsSoFar: 0
        )
        XCTAssertEqual(outcome.decision, .degradeToRemote(message: "Local playback stopped."))
    }

    func testCredentialsRejectionIsNotRestartable() {
        let kind = LibrespotRestartPolicy.classify(
            terminationStatus: 1,
            stderr: "Login request was denied INVALID_CREDENTIALS",
            wasIntentionalStop: false
        )
        XCTAssertEqual(kind, .credentialsRejected)
        let outcome = LibrespotRestartPolicy.decide(kind: kind, uptime: 2, attemptsSoFar: 0)
        XCTAssertEqual(
            outcome.decision,
            .resetCredentialsAndFail(message: LibrespotRestartPolicy.credentialsRejectedMessage)
        )
    }

    func testIntentionalStopIsIgnored() {
        let kind = LibrespotRestartPolicy.classify(
            terminationStatus: 0,
            stderr: "",
            wasIntentionalStop: true
        )
        XCTAssertEqual(kind, .intentionalStop)
        XCTAssertEqual(
            LibrespotRestartPolicy.decide(kind: kind, uptime: 1, attemptsSoFar: 2).decision,
            .ignore
        )
    }

    func testNonzeroWithoutCredentialsIsCrash() {
        XCTAssertEqual(
            LibrespotRestartPolicy.classify(
                terminationStatus: 137,
                stderr: "killed",
                wasIntentionalStop: false
            ),
            .crash(code: 137)
        )
        XCTAssertEqual(
            LibrespotRestartPolicy.classify(
                terminationStatus: 0,
                stderr: "",
                wasIntentionalStop: false
            ),
            .unexpectedCleanExit
        )
    }

    func testProcessArgumentsNeverIncludeOnEvent() {
        let arguments = LibrespotLaunchFlags.processArguments(
            cachePath: "/tmp/cache",
            enableOAuth: true
        )
        XCTAssertFalse(arguments.contains("--onevent"))
        XCTAssertTrue(arguments.contains("--enable-oauth"))
        XCTAssertEqual(arguments.first, "--name")
        XCTAssertTrue(arguments.contains("SpotifyLite"))
    }

    func testPlayDoesNotAutoStartLibrespotOnMissingDevice() {
        XCTAssertFalse(LocalPlaybackStartPolicy.startOnNoActiveDevice)
    }

    func testConfirmedDeviceIDIgnoresEmptyAndMissingDevices() throws {
        XCTAssertNil(PlaybackActiveDevice.confirmedID(from: nil))

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let withDevice = try decoder.decode(
            PlaybackState.self,
            from: Data(#"""
            {
              "device": {
                "id": "abc123",
                "name": "SpotifyLite",
                "type": "Computer",
                "is_active": true,
                "volume_percent": 50
              },
              "is_playing": true,
              "progress_ms": 0,
              "item": null
            }
            """#.utf8)
        )
        XCTAssertEqual(PlaybackActiveDevice.confirmedID(from: withDevice), "abc123")

        let emptyID = try decoder.decode(
            PlaybackState.self,
            from: Data(#"""
            {
              "device": {
                "id": "",
                "name": "SpotifyLite",
                "type": "Computer",
                "is_active": true,
                "volume_percent": 50
              },
              "is_playing": false,
              "progress_ms": 0,
              "item": null
            }
            """#.utf8)
        )
        XCTAssertNil(PlaybackActiveDevice.confirmedID(from: emptyID))
    }
}
