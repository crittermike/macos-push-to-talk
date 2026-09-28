import Foundation

// Command Line Tools lack XCTest. Adapt only the assertions used by the same test cases.
class XCTestCase {}

private var assertionFailures = 0
private var currentTest = ""

private func check(_ passed: Bool, _ message: String, file: StaticString, line: UInt) {
    if !passed {
        assertionFailures += 1
        fputs("\(file):\(line): \(currentTest): \(message)\n", stderr)
    }
}

func XCTAssertEqual<T: Equatable>(_ actual: T, _ expected: T, file: StaticString = #filePath, line: UInt = #line) {
    check(actual == expected, "\(actual) != \(expected)", file: file, line: line)
}

func XCTAssertTrue(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) {
    check(value, "Expected true", file: file, line: line)
}

func XCTAssertFalse(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) {
    check(!value, "Expected false", file: file, line: line)
}

func XCTAssertNil<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) {
    check(value == nil, "Expected nil, got \(String(describing: value))", file: file, line: line)
}

@main
struct PortableTestRunner {
    @MainActor
    static func main() async {
        let tests = TeamsControllerTests()
        let labels = TeamsButtonLabelsTests()
        let arrays = TeamsAXArrayTests()
        let feedback = ControlFeedbackTests()
        let cases: [(String, @MainActor () async -> Void)] = [
            ("startup", tests.testStartupOnlyObservesExistingState),
            ("hold/release", tests.testHoldAndReleaseConfirmRealState),
            ("no-op/repeat", tests.testSameStateAndRepeatedFlagsDoNotToggle),
            ("quick tap", tests.testQuickTapCoalescesBeforeAnyUnmute),
            ("queued AX cancellation", tests.testReleaseRevokesUnmuteQueuedAtAXBoundary),
            ("release during AX", tests.testReleaseDuringInFlightUnmuteWaitsForLagThenRemutes),
            ("release during readback", tests.testReleaseDuringDelayedReadbackDoesNotAcceptOldMutedLabel),
            ("coalesced release", tests.testRapidReleasePressReleaseKeepsNewestReleasedIntent),
            ("coalesced hold", tests.testRepressDuringUnmuteConfirmationUsesLatestHoldWithoutDoubleToggle),
            ("manual/organizer mute", tests.testManualOrOrganizerMuteIsObservedWithoutAutomaticUnmute),
            ("disabled control", tests.testDisabledSelfUnmuteIsNotPressed),
            ("unavailable/recovery", tests.testUnavailableStatesAndRecoveryDoNotReplayHold),
            ("meeting changed", tests.testChangedMeetingCannotReceiveOldUnmute),
            ("confirmation timeout", tests.testUnconfirmedUnmuteStaysUnknownDespiteOldMutedReadings),
            ("mute failure", tests.testMuteFailureNeverReportsMutedAndDoesNotRetryForever),
            ("accepted AX failure", tests.testAXErrorAfterAcceptedUnmuteStillSettlesBeforeRemuting),
            ("permission loss", tests.testPermissionLossAfterPressIsNotConfirmation),
            ("end hold", tests.testEndHoldRemutesWithoutUnmutingOnResume),
            ("stop", tests.testStopRemutesAndDisablesFurtherRequests),
            ("stop queued unmute", tests.testStopCancelsAnUnmuteThatHasNotStarted),
            ("Teams isolation", tests.testTeamsModeNeverCreatesSystemControllerEvenOnFailure),
            ("legacy restoration", tests.testLegacyModeRestoresAndStopsBeforeTeamsIsCreated),
            ("restoration failure", tests.testFailedLegacyRestorePreventsTeamsActivationAndCanBeRetried),
            ("switch to legacy", tests.testSwitchToLegacyFirstConfirmsTeamsMute),
            ("action labels", { labels.testActionLabelsDescribeOppositeOfCurrentState() }),
            ("unsafe labels", { labels.testSettingsParticipantAndNotificationControlsAreRejected() }),
            ("meeting context", { labels.testMeetingRequiresARealLeaveButton() }),
            ("empty AX arrays", { arrays.testEmptyAXArraysSkipIndexZeroRead() }),
            ("AX array count", { arrays.testAXArrayReadUsesActualCount() }),
            ("AX array limit", { arrays.testOversizedAXArrayFailsBeforeCopy() }),
            ("AX copy diagnostics", { arrays.testAXArrayCopyErrorsPreserveAPIAttributeAndArguments() }),
            ("AX count failures", { arrays.testAXArrayCountErrorsAreNotMistakenForEmptyArrays() }),
            ("optional AX arrays", { arrays.testUnsupportedAXArraysRemainOptional() }),
            ("quiet Teams transitions", { feedback.testTeamsTransitionsKeepLastConfirmedIconAndNeverRequestSounds() }),
            ("unconfirmed transition icon", { feedback.testTeamsTransitionWithoutConfirmationDoesNotInventAState() }),
            ("failed transition icon", { feedback.testTeamsFailuresAndDisconnectionClearStaleIcons() }),
            ("legacy transition sounds", { feedback.testLegacyModeKeepsConfirmedTransitionSounds() }),
            ("mode feedback isolation", { feedback.testModeSwitchDoesNotReusePreviousModesConfirmedState() }),
        ]
        guard let expected = CommandLine.arguments.dropFirst().first.flatMap(Int.init), cases.count == expected else {
            fputs("Portable test list is out of date; register every test method.\n", stderr)
            exit(1)
        }
        for (name, run) in cases {
            currentTest = name
            await run()
        }
        print("\(cases.count) deterministic tests, \(assertionFailures) assertion failures (portable runner).")
        if assertionFailures > 0 { exit(1) }
    }
}
