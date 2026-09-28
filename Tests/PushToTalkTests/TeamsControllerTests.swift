#if PORTABLE_TESTS
import Foundation
#else
import XCTest
@testable import PushToTalk
#endif
import ApplicationServices

@MainActor
private final class FakeTeams: TeamsClient {
    var muted = true
    var canPress = true
    var connectionID = "meeting-1"
    var readIssue: TeamsIssue?
    var writeIssue: TeamsIssue?
    var issueAfterPress: TeamsIssue?
    var delayReads = 0
    var neverConfirm = false
    var beforeAction: (() -> Void)?
    var afterPress: ((Bool) -> Void)?
    private var pendingMute: Bool?
    private var remainingReads = 0
    private(set) var requests: [Bool] = []
    private(set) var presses: [Bool] = []
    private(set) var reads = 0

    var reading: TeamsReading {
        TeamsReading(connectionID: connectionID, muted: muted, canPress: canPress)
    }

    func read() async throws -> TeamsReading {
        reads += 1
        if let readIssue { throw readIssue }
        if let pendingMute, !neverConfirm {
            if remainingReads == 0 {
                muted = pendingMute
                self.pendingMute = nil
            } else {
                remainingReads -= 1
            }
        }
        return reading
    }

    func setMuted(_ muted: Bool, connectionID: String, permit: UnmutePermit?) async throws -> TeamsAction {
        requests.append(muted)
        beforeAction?()
        if !muted, permit?.isValid != true { return .cancelled }
        if let writeIssue { throw writeIssue }
        if let readIssue { throw readIssue }
        guard connectionID == self.connectionID else { throw TeamsIssue.meetingChanged }
        if self.muted == muted { return .unchanged(reading) }
        guard canPress else { throw TeamsIssue.disabled }
        presses.append(muted)
        pendingMute = muted
        remainingReads = delayReads
        afterPress?(muted)
        if let issueAfterPress {
            self.issueAfterPress = nil
            throw issueAfterPress
        }
        return .pressed
    }
}

@MainActor
private final class FakeSystemMicrophone: SystemMicrophone {
    var onFailure: ((String) -> Void)?
    var onEvent: (String) -> Void = { _ in }
    var stopIssue: TeamsIssue?
    private(set) var active = true
    private(set) var requests: [Bool] = []
    private(set) var restored = false

    func setMuted(_ muted: Bool) throws {
        guard active else { throw TeamsIssue.unexpected("Legacy controller is stopped") }
        requests.append(muted)
        onEvent("system:\(muted)")
    }

    func stop() throws {
        active = false
        onEvent("system:stop")
        if let stopIssue { throw stopIssue }
        restored = true
    }
}

@MainActor
final class TeamsControllerTests: XCTestCase {
    private func controller(_ fake: FakeTeams, attempts: Int = 8) async -> TeamsController {
        let controller = TeamsController(client: fake, confirmationAttempts: attempts, pause: {})
        controller.refresh()
        await controller.waitForIdle()
        return controller
    }

    func testStartupOnlyObservesExistingState() async {
        let fake = FakeTeams()
        fake.muted = false
        let controller = await controller(fake)
        XCTAssertEqual(controller.status.confirmedMuted, false)
        XCTAssertTrue(fake.requests.isEmpty)
    }

    func testHoldAndReleaseConfirmRealState() async {
        let fake = FakeTeams()
        let controller = await controller(fake)
        controller.setHeld(true)
        XCTAssertEqual(controller.status, .changing(muted: false))
        await controller.waitForIdle()
        XCTAssertEqual(controller.status.confirmedMuted, false)
        controller.setHeld(false)
        await controller.waitForIdle()
        XCTAssertEqual(controller.status.confirmedMuted, true)
        XCTAssertEqual(fake.presses, [false, true])
        XCTAssertEqual(fake.reads, 5)
    }

    func testSameStateAndRepeatedFlagsDoNotToggle() async {
        let fake = FakeTeams()
        fake.muted = false
        let controller = await controller(fake)
        controller.setHeld(true)
        controller.setHeld(true)
        await controller.waitForIdle()
        XCTAssertEqual(fake.requests, [false])
        XCTAssertTrue(fake.presses.isEmpty)
        controller.setHeld(false)
        controller.setHeld(false)
        await controller.waitForIdle()
        XCTAssertEqual(fake.presses, [true])
    }

    func testQuickTapCoalescesBeforeAnyUnmute() async {
        let fake = FakeTeams()
        let controller = await controller(fake)
        controller.setHeld(true)
        controller.setHeld(false)
        await controller.waitForIdle()
        XCTAssertEqual(fake.requests, [true])
        XCTAssertTrue(fake.presses.isEmpty)
        XCTAssertEqual(controller.status.confirmedMuted, true)
    }

    func testReleaseRevokesUnmuteQueuedAtAXBoundary() async {
        let fake = FakeTeams()
        let controller = await controller(fake)
        fake.beforeAction = { controller.setHeld(false) }
        controller.setHeld(true)
        await controller.waitForIdle()
        XCTAssertTrue(fake.presses.isEmpty)
        XCTAssertEqual(fake.requests, [false, true])
        XCTAssertEqual(controller.status.confirmedMuted, true)
    }

    func testReleaseDuringInFlightUnmuteWaitsForLagThenRemutes() async {
        let fake = FakeTeams()
        fake.delayReads = 3
        let controller = await controller(fake)
        var statesAfterRelease: [TeamsStatus] = []
        fake.afterPress = { muted in
            if !muted {
                controller.setHeld(false)
                controller.onChange = { status, _ in statesAfterRelease.append(status) }
            }
        }
        controller.setHeld(true)
        await controller.waitForIdle()
        XCTAssertEqual(fake.presses, [false, true])
        XCTAssertEqual(controller.status.confirmedMuted, true)
        XCTAssertFalse(statesAfterRelease.contains { $0.confirmedMuted == false })
        XCTAssertTrue(fake.muted)
    }

    func testReleaseDuringDelayedReadbackDoesNotAcceptOldMutedLabel() async {
        let fake = FakeTeams()
        fake.delayReads = 3
        var pauses = 0
        var release: (() -> Void)?
        let controller = TeamsController(client: fake, confirmationAttempts: 8, pause: {
            pauses += 1
            if pauses == 2 { release?() }
        })
        release = { controller.setHeld(false) }
        controller.refresh()
        await controller.waitForIdle()
        var readyAfterRelease: [Bool] = []
        controller.onChange = { status, _ in
            if pauses >= 2, let muted = status.confirmedMuted { readyAfterRelease.append(muted) }
        }
        controller.setHeld(true)
        await controller.waitForIdle()
        XCTAssertEqual(fake.presses, [false, true])
        XCTAssertEqual(readyAfterRelease, [true])
    }

    func testRapidReleasePressReleaseKeepsNewestReleasedIntent() async {
        let fake = FakeTeams()
        fake.delayReads = 2
        let controller = await controller(fake)
        fake.afterPress = { muted in
            if !muted {
                controller.setHeld(false)
                controller.setHeld(true)
                controller.setHeld(false)
            }
        }
        controller.setHeld(true)
        await controller.waitForIdle()
        XCTAssertEqual(fake.presses, [false, true])
        XCTAssertEqual(controller.status.confirmedMuted, true)
    }

    func testRepressDuringUnmuteConfirmationUsesLatestHoldWithoutDoubleToggle() async {
        let fake = FakeTeams()
        fake.delayReads = 2
        let controller = await controller(fake)
        fake.afterPress = { muted in
            if !muted {
                controller.setHeld(false)
                controller.setHeld(true)
            }
        }
        controller.setHeld(true)
        await controller.waitForIdle()
        XCTAssertEqual(fake.presses, [false])
        XCTAssertEqual(controller.status.confirmedMuted, false)
        controller.setHeld(false)
        await controller.waitForIdle()
        XCTAssertEqual(fake.presses, [false, true])
    }

    func testManualOrOrganizerMuteIsObservedWithoutAutomaticUnmute() async {
        let fake = FakeTeams()
        let controller = await controller(fake)
        controller.setHeld(true)
        await controller.waitForIdle()
        fake.muted = true
        fake.canPress = false
        controller.refresh()
        await controller.waitForIdle()
        XCTAssertEqual(controller.status.confirmedMuted, true)
        XCTAssertEqual(fake.presses, [false])
        controller.setHeld(true)
        await controller.waitForIdle()
        XCTAssertEqual(fake.presses, [false])
    }

    func testDisabledSelfUnmuteIsNotPressed() async {
        let fake = FakeTeams()
        fake.canPress = false
        let controller = await controller(fake)
        controller.setHeld(true)
        await controller.waitForIdle()
        XCTAssertEqual(controller.status, .failed(.disabled))
        XCTAssertTrue(fake.presses.isEmpty)
    }

    func testUnavailableStatesAndRecoveryDoNotReplayHold() async {
        for issue in [TeamsIssue.permissionRequired, .notRunning, .noMeeting] {
            let fake = FakeTeams()
            fake.readIssue = issue
            let controller = await controller(fake)
            XCTAssertEqual(controller.status, .unavailable(issue))
            controller.setHeld(true)
            await controller.waitForIdle()
            fake.readIssue = nil
            controller.refresh()
            await controller.waitForIdle()
            XCTAssertEqual(controller.status.confirmedMuted, true)
            XCTAssertTrue(fake.requests.isEmpty)
            controller.setHeld(false)
            await controller.waitForIdle()
            controller.setHeld(true)
            await controller.waitForIdle()
            XCTAssertEqual(fake.presses, [false])
        }
    }

    func testChangedMeetingCannotReceiveOldUnmute() async {
        let fake = FakeTeams()
        let controller = await controller(fake)
        fake.connectionID = "meeting-2"
        controller.setHeld(true)
        await controller.waitForIdle()
        XCTAssertEqual(controller.status, .failed(.meetingChanged))
        XCTAssertTrue(fake.presses.isEmpty)
        controller.refresh()
        await controller.waitForIdle()
        XCTAssertTrue(fake.presses.isEmpty)
    }

    func testUnconfirmedUnmuteStaysUnknownDespiteOldMutedReadings() async {
        let fake = FakeTeams()
        fake.neverConfirm = true
        let controller = await controller(fake, attempts: 3)
        controller.setHeld(true)
        await controller.waitForIdle()
        XCTAssertEqual(fake.presses, [false])
        XCTAssertEqual(fake.requests, [false, true])
        XCTAssertEqual(controller.status, .failed(.unconfirmed))
        controller.setHeld(false)
        await controller.waitForIdle()
        controller.refresh()
        await controller.waitForIdle()
        XCTAssertNil(controller.status.confirmedMuted)
        XCTAssertEqual(fake.presses, [false])
    }

    func testMuteFailureNeverReportsMutedAndDoesNotRetryForever() async {
        let fake = FakeTeams()
        let controller = await controller(fake)
        controller.setHeld(true)
        await controller.waitForIdle()
        fake.writeIssue = .pressFailed(-25204)
        controller.setHeld(false)
        await controller.waitForIdle()
        XCTAssertEqual(controller.status, .failed(.unconfirmed))
        XCTAssertNil(controller.status.confirmedMuted)
        controller.refresh()
        await controller.waitForIdle()
        XCTAssertNil(controller.status.confirmedMuted)
        XCTAssertEqual(fake.requests, [false, true])
    }

    func testAXErrorAfterAcceptedUnmuteStillSettlesBeforeRemuting() async {
        let fake = FakeTeams()
        fake.delayReads = 3
        fake.issueAfterPress = .pressFailed(-25204)
        let controller = await controller(fake)
        fake.afterPress = { muted in
            if !muted { controller.setHeld(false) }
        }
        controller.setHeld(true)
        await controller.waitForIdle()
        XCTAssertEqual(fake.presses, [false, true])
        XCTAssertEqual(controller.status.confirmedMuted, true)
        XCTAssertEqual(controller.lastIssue, .pressFailed(-25204))
    }

    func testPermissionLossAfterPressIsNotConfirmation() async {
        let fake = FakeTeams()
        let controller = await controller(fake)
        fake.afterPress = { _ in fake.readIssue = .permissionRequired }
        controller.setHeld(true)
        await controller.waitForIdle()
        XCTAssertEqual(controller.status, .unavailable(.permissionRequired))
        XCTAssertNil(controller.status.confirmedMuted)
        XCTAssertEqual(fake.presses, [false])
        fake.readIssue = nil
        controller.refresh()
        await controller.waitForIdle()
        XCTAssertNil(controller.status.confirmedMuted)
        XCTAssertEqual(fake.presses, [false])
    }

    func testEndHoldRemutesWithoutUnmutingOnResume() async {
        let fake = FakeTeams()
        let controller = await controller(fake)
        controller.setHeld(true)
        await controller.waitForIdle()
        controller.endHold()
        await controller.waitForIdle()
        controller.refresh()
        await controller.waitForIdle()
        XCTAssertEqual(controller.status.confirmedMuted, true)
        XCTAssertEqual(fake.presses, [false, true])
    }

    func testStopRemutesAndDisablesFurtherRequests() async {
        let fake = FakeTeams()
        let controller = await controller(fake)
        controller.setHeld(true)
        await controller.waitForIdle()
        await controller.stop()
        XCTAssertEqual(controller.status.confirmedMuted, true)
        let reads = fake.reads
        controller.setHeld(true)
        controller.refresh()
        await controller.waitForIdle()
        XCTAssertEqual(fake.presses, [false, true])
        XCTAssertEqual(fake.reads, reads)
    }

    func testStopCancelsAnUnmuteThatHasNotStarted() async {
        let fake = FakeTeams()
        let controller = await controller(fake)
        controller.setHeld(true)
        await controller.stop()
        XCTAssertTrue(fake.presses.isEmpty)
        XCTAssertEqual(controller.status.confirmedMuted, true)
    }

    func testTeamsModeNeverCreatesSystemControllerEvenOnFailure() async {
        let fake = FakeTeams()
        fake.readIssue = .permissionRequired
        let teams = await controller(fake)
        var systemCreations = 0
        let modes = ModeController(mode: .teams, makeTeams: { teams }, makeSystem: {
            systemCreations += 1
            return FakeSystemMicrophone()
        })
        modes.start()
        modes.setHeld(true)
        modes.setHeld(false)
        modes.refresh()
        await teams.waitForIdle()
        _ = await modes.stop()
        XCTAssertEqual(systemCreations, 0)
    }

    func testLegacyModeRestoresAndStopsBeforeTeamsIsCreated() async {
        let fake = FakeTeams()
        let system = FakeSystemMicrophone()
        var events: [String] = []
        system.onEvent = { events.append($0) }
        let teams = TeamsController(client: fake, pause: {})
        let modes = ModeController(mode: .system, makeTeams: {
            events.append("teams:create")
            return teams
        }, makeSystem: { system })
        modes.start()
        let switched = await modes.select(.teams)
        XCTAssertTrue(switched)
        XCTAssertEqual(events, ["system:true", "system:stop", "teams:create"])
        XCTAssertFalse(system.active)
        XCTAssertTrue(system.restored)
        await teams.waitForIdle()
        modes.setHeld(true)
        await teams.waitForIdle()
        modes.setHeld(false)
        await teams.waitForIdle()
        XCTAssertEqual(system.requests, [true])
        XCTAssertEqual(fake.presses, [false, true])
    }

    func testFailedLegacyRestorePreventsTeamsActivationAndCanBeRetried() async {
        let system = FakeSystemMicrophone()
        system.stopIssue = .unexpected("Restore failed")
        var teamsCreations = 0
        let modes = ModeController(mode: .system, makeTeams: {
            teamsCreations += 1
            return TeamsController(client: FakeTeams(), pause: {})
        }, makeSystem: { system })
        modes.start()
        let switched = await modes.select(.teams)
        XCTAssertFalse(switched)
        XCTAssertEqual(teamsCreations, 0)
        XCTAssertFalse(system.active)
        system.stopIssue = nil
        let retried = await modes.select(.teams)
        XCTAssertTrue(retried)
        XCTAssertTrue(system.restored)
        XCTAssertEqual(teamsCreations, 1)
        _ = await modes.stop()
    }

    func testSwitchToLegacyFirstConfirmsTeamsMute() async {
        let fake = FakeTeams()
        let teams = await controller(fake)
        let system = FakeSystemMicrophone()
        var mutedWhenLegacyCreated: Bool?
        let modes = ModeController(mode: .teams, makeTeams: { teams }, makeSystem: {
            mutedWhenLegacyCreated = teams.status.confirmedMuted
            return system
        })
        modes.start()
        modes.setHeld(true)
        await teams.waitForIdle()
        let switched = await modes.select(.system)
        XCTAssertTrue(switched)
        XCTAssertEqual(mutedWhenLegacyCreated, true)
        XCTAssertEqual(fake.presses, [false, true])
        XCTAssertEqual(system.requests, [true])
        modes.refresh()
        modes.setHeld(true)
        XCTAssertEqual(fake.presses, [false, true])
        _ = await modes.stop()
    }
}

final class TeamsButtonLabelsTests: XCTestCase {
    func testActionLabelsDescribeOppositeOfCurrentState() {
        XCTAssertEqual(TeamsButtonLabels.muted(role: "AXButton", labels: ["Mute mic"]), false)
        XCTAssertEqual(TeamsButtonLabels.muted(role: "AXButton", labels: ["Unmute mic"]), true)
        XCTAssertEqual(TeamsButtonLabels.muted(role: "AXButton", labels: ["", " Unmute mic "]), true)
    }

    func testSettingsParticipantAndNotificationControlsAreRejected() {
        for label in ["Mute all", "Unmute participant", "Mute notifications", "Keyboard shortcut to unmute",
                      "Microphone", "Mute", "Stummschalten"] {
            XCTAssertNil(TeamsButtonLabels.muted(role: "AXButton", labels: [label]))
        }
        XCTAssertNil(TeamsButtonLabels.muted(role: "AXCheckBox", labels: ["Unmute mic"]))
        XCTAssertNil(TeamsButtonLabels.muted(role: "AXButton", labels: ["Mute mic", "Unmute mic"]))
    }

    func testMeetingRequiresARealLeaveButton() {
        XCTAssertTrue(TeamsButtonLabels.isLeaveButton(role: "AXButton", labels: ["Leave"]))
        XCTAssertTrue(TeamsButtonLabels.isLeaveButton(role: "AXButton", labels: ["Leave call"]))
        XCTAssertFalse(TeamsButtonLabels.isLeaveButton(role: "AXStaticText", labels: ["Leave"]))
        XCTAssertFalse(TeamsButtonLabels.isLeaveButton(role: "AXButton", labels: ["Join now"]))
    }
}

final class ControlFeedbackTests: XCTestCase {
    private func ready(_ muted: Bool) -> ControlStatus {
        .teams(.ready(TeamsReading(connectionID: "meeting", muted: muted, canPress: true)), nil)
    }

    func testTeamsTransitionsKeepLastConfirmedIconAndNeverRequestSounds() {
        var feedback = ControlFeedback()
        feedback.update(ready(true))
        XCTAssertEqual(feedback.lastConfirmedMuted, true)
        XCTAssertNil(feedback.transitionSoundMuted)

        feedback.update(.teams(.changing(muted: false), nil))
        XCTAssertEqual(feedback.lastConfirmedMuted, true)
        XCTAssertNil(feedback.transitionSoundMuted)
        feedback.update(ready(false))
        XCTAssertEqual(feedback.lastConfirmedMuted, false)
        XCTAssertNil(feedback.transitionSoundMuted)

        feedback.update(.teams(.changing(muted: true), nil))
        XCTAssertEqual(feedback.lastConfirmedMuted, false)
        XCTAssertNil(feedback.transitionSoundMuted)
        feedback.update(ready(true))
        XCTAssertEqual(feedback.lastConfirmedMuted, true)
        XCTAssertNil(feedback.transitionSoundMuted)
    }

    func testTeamsTransitionWithoutConfirmationDoesNotInventAState() {
        var feedback = ControlFeedback()
        for muted in [true, false] {
            feedback.update(.teams(.changing(muted: muted), nil))
            XCTAssertNil(feedback.lastConfirmedMuted)
            XCTAssertNil(feedback.transitionSoundMuted)
        }
    }

    func testTeamsFailuresAndDisconnectionClearStaleIcons() {
        for state in [TeamsStatus.failed(.unconfirmed), .unavailable(.noMeeting), .checking] {
            var feedback = ControlFeedback()
            feedback.update(ready(true))
            feedback.update(.teams(state, nil))
            XCTAssertNil(feedback.lastConfirmedMuted)
            XCTAssertNil(feedback.transitionSoundMuted)
            feedback.update(.teams(.changing(muted: true), nil))
            XCTAssertNil(feedback.lastConfirmedMuted)
        }
    }

    func testLegacyModeKeepsConfirmedTransitionSounds() {
        var feedback = ControlFeedback()
        feedback.update(.system(muted: true))
        XCTAssertNil(feedback.transitionSoundMuted)
        feedback.update(.system(muted: false))
        XCTAssertEqual(feedback.transitionSoundMuted, false)
        feedback.update(.system(muted: false))
        XCTAssertNil(feedback.transitionSoundMuted)
        feedback.update(.system(muted: true))
        XCTAssertEqual(feedback.transitionSoundMuted, true)
        feedback.update(.failed("Device disconnected"))
        XCTAssertNil(feedback.lastConfirmedMuted)
        XCTAssertNil(feedback.transitionSoundMuted)
    }

    func testModeSwitchDoesNotReusePreviousModesConfirmedState() {
        var feedback = ControlFeedback()
        feedback.update(ready(false))
        feedback.update(.switching)
        XCTAssertNil(feedback.lastConfirmedMuted)
        XCTAssertNil(feedback.transitionSoundMuted)
        feedback.update(.system(muted: true))
        XCTAssertNil(feedback.transitionSoundMuted)
        feedback.update(.switching)
        feedback.update(.teams(.changing(muted: false), nil))
        XCTAssertNil(feedback.lastConfirmedMuted)
        XCTAssertNil(feedback.transitionSoundMuted)
    }
}

final class TeamsAXArrayTests: XCTestCase {
    func testEmptyAXArraysSkipIndexZeroRead() {
        XCTAssertEqual(AXError.illegalArgument.rawValue, -25201)
        for attribute in ["AXWindows", "AXChildren"] {
            var copies = 0
            do {
                let elements: [Int] = try TeamsAXArrayReader.read(
                    attribute: attribute, limit: 16, count: { (.success, 0) },
                    values: { _ in
                        copies += 1
                        return (.illegalArgument, nil)
                    }
                )
                XCTAssertEqual(elements, [])
            } catch {
                XCTAssertTrue(false)
            }
            XCTAssertEqual(copies, 0)
        }
    }

    func testAXArrayReadUsesActualCount() {
        do {
            let elements: [Int] = try TeamsAXArrayReader.read(
                attribute: "AXChildren", limit: 16, count: { (.success, 2) },
                values: { count in
                    XCTAssertEqual(count, 2)
                    return (.success, [1, 2])
                }
            )
            XCTAssertEqual(elements, [1, 2])
        } catch {
            XCTAssertTrue(false)
        }
    }

    func testOversizedAXArrayFailsBeforeCopy() {
        var copies = 0
        do {
            let _: [Int] = try TeamsAXArrayReader.read(
                attribute: "AXWindows", limit: 16, count: { (.success, 17) },
                values: { _ in
                    copies += 1
                    return (.success, [])
                }
            )
            XCTAssertTrue(false)
        } catch {
            XCTAssertEqual(error as? TeamsIssue, .discoveryLimit)
        }
        XCTAssertEqual(copies, 0)
    }

    func testAXArrayCopyErrorsPreserveAPIAttributeAndArguments() {
        for code in [AXError.illegalArgument, .cannotComplete] {
            do {
                let _: [Int] = try TeamsAXArrayReader.read(
                    attribute: "AXChildren", limit: 16, count: { (.success, 2) },
                    values: { _ in (code, nil) }
                )
                XCTAssertTrue(false)
            } catch {
                let expected = TeamsIssue.readFailed(
                    code.rawValue, operation: "AXUIElementCopyAttributeValues(AXChildren, index: 0, maxValues: 2)"
                )
                XCTAssertEqual(error as? TeamsIssue, expected)
                XCTAssertTrue(expected.description.contains("AXChildren, index: 0, maxValues: 2"))
                XCTAssertTrue(expected.description.contains("AX error \(code.rawValue)"))
            }
        }
    }

    func testAXArrayCountErrorsAreNotMistakenForEmptyArrays() {
        var copies = 0
        do {
            let _: [Int] = try TeamsAXArrayReader.read(
                attribute: "AXWindows", limit: 16, count: { (.illegalArgument, 0) },
                values: { _ in
                    copies += 1
                    return (.success, [])
                }
            )
            XCTAssertTrue(false)
        } catch {
            XCTAssertEqual(
                error as? TeamsIssue,
                .readFailed(-25201, operation: "AXUIElementGetAttributeValueCount(AXWindows)")
            )
        }
        XCTAssertEqual(copies, 0)
    }

    func testUnsupportedAXArraysRemainOptional() {
        for code in [AXError.attributeUnsupported, .noValue] {
            do {
                let elements: [Int] = try TeamsAXArrayReader.read(
                    attribute: "AXChildren", limit: 16, count: { (code, 0) },
                    values: { _ in
                        XCTAssertTrue(false)
                        return (.success, [])
                    }
                )
                XCTAssertEqual(elements, [])
            } catch {
                XCTAssertTrue(false)
            }
        }
    }
}
