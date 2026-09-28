import Foundation

struct TeamsReading: Equatable {
    let connectionID: String
    let muted: Bool
    let canPress: Bool
}

enum TeamsIssue: Error, Equatable, CustomStringConvertible {
    case permissionRequired
    case notRunning
    case noMeeting
    case ambiguousControls
    case disabled
    case meetingChanged
    case discoveryLimit
    case readFailed(Int32, operation: String)
    case pressFailed(Int32)
    case unconfirmed
    case unexpected(String)

    var description: String {
        switch self {
        case .permissionRequired: return "Accessibility permission required. Grant access, then relaunch."
        case .notRunning: return "Teams is not running."
        case .noMeeting: return "No accessible Teams meeting. Keep an English-language meeting window open."
        case .ambiguousControls: return "Multiple Teams apps or mic controls found. Close extra meeting windows."
        case .disabled: return "Teams has disabled the mic control. You may not be allowed to unmute."
        case .meetingChanged: return "The Teams meeting control changed. Release Fn and try again."
        case .discoveryLimit: return "Teams Accessibility discovery timed out or exceeded its scan limit."
        case .readFailed(let code, let operation):
            return "Could not read Teams mic state: \(operation) failed (AX error \(code))."
        case .pressFailed(let code): return "Teams mic action returned AX error \(code)."
        case .unconfirmed: return "Teams mic change was not confirmed. Check mute in Teams; restart this app if needed."
        case .unexpected(let message): return "Teams control failed: \(message)"
        }
    }

    var isUnavailable: Bool {
        switch self {
        case .permissionRequired, .notRunning, .noMeeting: return true
        default: return false
        }
    }
}

enum TeamsStatus: Equatable {
    case checking
    case changing(muted: Bool)
    case ready(TeamsReading)
    case unavailable(TeamsIssue)
    case failed(TeamsIssue)

    var confirmedMuted: Bool? {
        if case .ready(let reading) = self { return reading.muted }
        return nil
    }
}

// A release can revoke permission while a synchronous AX call is on another executor.
final class UnmutePermit: @unchecked Sendable {
    private let lock = NSLock()
    private var valid = true

    var isValid: Bool {
        lock.lock()
        defer { lock.unlock() }
        return valid
    }

    func revoke() {
        lock.lock()
        valid = false
        lock.unlock()
    }
}

enum TeamsAction {
    case unchanged(TeamsReading)
    case pressed
    case cancelled
}

protocol TeamsClient: AnyObject {
    func read() async throws -> TeamsReading
    func setMuted(_ muted: Bool, connectionID: String, permit: UnmutePermit?) async throws -> TeamsAction
}

@MainActor
final class TeamsController {
    private struct Request {
        let revision: Int
        let muted: Bool
        let connectionID: String
        let permit: UnmutePermit?
    }

    private let client: TeamsClient
    private let confirmationAttempts: Int
    private let pause: () async throws -> Void
    private var reading: TeamsReading?
    private var holdConnectionID: String?
    private var lastTargetID: String?
    private var permit: UnmutePermit?
    private var held = false
    private var acceptingInput = true
    private var stopped = false
    private var revision = 0
    private var pending: Request?
    private var refreshPending = false
    private var worker: Task<Void, Never>?
    private var uncertainAction = false

    private(set) var status: TeamsStatus = .checking
    private(set) var lastIssue: TeamsIssue?
    var onChange: ((TeamsStatus, TeamsIssue?) -> Void)?

    init(
        client: TeamsClient,
        confirmationAttempts: Int = 12,
        pause: @escaping () async throws -> Void = { try await Task.sleep(nanoseconds: 100_000_000) }
    ) {
        precondition(confirmationAttempts >= 2)
        self.client = client
        self.confirmationAttempts = confirmationAttempts
        self.pause = pause
    }

    func refresh() {
        guard acceptingInput else { return }
        refreshPending = true
        startWorker()
    }

    func setHeld(_ down: Bool) {
        guard acceptingInput, down != held else { return }
        held = down
        permit?.revoke()
        if down {
            lastIssue = nil
            guard let reading else {
                // Discovery/reconnection never replays this key-down.
                publish(.unavailable(.noMeeting))
                refresh()
                return
            }
            let newPermit = UnmutePermit()
            permit = newPermit
            holdConnectionID = reading.connectionID
            enqueue(muted: false, connectionID: reading.connectionID, permit: newPermit)
        } else {
            requestMute()
            holdConnectionID = nil
        }
    }

    func endHold() {
        setHeld(false)
    }

    func stop() async {
        guard acceptingInput else {
            await waitForIdle()
            return
        }
        acceptingInput = false
        held = false
        permit?.revoke()
        refreshPending = false
        requestMute()
        await waitForIdle()
        stopped = true
    }

    func waitForIdle() async {
        while let worker { await worker.value }
    }

    private func requestMute() {
        guard let connectionID = holdConnectionID ?? reading?.connectionID ?? lastTargetID else { return }
        enqueue(muted: true, connectionID: connectionID, permit: nil)
    }

    private func enqueue(muted: Bool, connectionID: String, permit: UnmutePermit?) {
        revision += 1
        pending?.permit?.revoke()
        pending = Request(revision: revision, muted: muted, connectionID: connectionID, permit: permit)
        lastTargetID = connectionID
        publish(.changing(muted: muted))
        startWorker()
    }

    private func startWorker() {
        guard worker == nil, !stopped else { return }
        worker = Task {
            while !stopped {
                if let request = pending {
                    pending = nil
                    await execute(request)
                } else if refreshPending {
                    refreshPending = false
                    await observe(at: revision)
                } else {
                    break
                }
            }
            worker = nil
        }
    }

    private func execute(_ request: Request) async {
        var pressed = false
        do {
            if !request.muted {
                guard request.permit?.isValid == true else { return }
                guard !uncertainAction else { throw TeamsIssue.unconfirmed }
            }
            let action: TeamsAction
            do {
                action = try await client.setMuted(
                    request.muted, connectionID: request.connectionID, permit: request.permit
                )
            } catch let issue as TeamsIssue {
                guard case .pressFailed = issue else { throw issue }
                lastIssue = issue
                NSLog("Push To Talk: %@", issue.description)
                // A transport error can arrive after Teams accepted the press.
                // Settle that possible toggle before attempting a corrective one.
                action = .pressed
            }
            switch action {
            case .cancelled:
                return
            case .unchanged(let current):
                reading = current
                guard !uncertainAction else { throw TeamsIssue.unconfirmed }
                finish(.ready(current), request: request)
            case .pressed:
                pressed = true
                uncertainAction = true
                var matchingReads = 0
                for _ in 0..<confirmationAttempts {
                    try await pause()
                    let current = try await client.read()
                    guard current.connectionID == request.connectionID else { throw TeamsIssue.meetingChanged }
                    reading = current
                    matchingReads = current.muted == request.muted ? matchingReads + 1 : 0
                    if matchingReads >= 2 {
                        uncertainAction = false
                        finish(.ready(current), request: request)
                        return
                    }
                }
                throw TeamsIssue.unconfirmed
            }
        } catch {
            let issue = (error as? TeamsIssue) ?? .unexpected(error.localizedDescription)
            if case .pressFailed = issue { uncertainAction = true }
            if pressed { uncertainAction = true }
            if issue.isUnavailable || issue == .meetingChanged { reading = nil }
            lastIssue = issue
            NSLog("Push To Talk: %@", issue.description)
            finish(issue.isUnavailable ? .unavailable(issue) : .failed(issue), request: request)

            // A failed unmute may still have reached Teams. Attempt one state-aware
            // remute, never another unmute, and never claim a no-op cleared uncertainty.
            if !request.muted, uncertainAction, pending == nil {
                request.permit?.revoke()
                enqueue(muted: true, connectionID: request.connectionID, permit: nil)
            }
        }
    }

    private func observe(at observedRevision: Int) async {
        do {
            let current = try await client.read()
            guard revision == observedRevision else { return }
            reading = current
            if uncertainAction {
                publish(.failed(lastIssue ?? .unconfirmed))
            } else {
                publish(.ready(current))
            }
        } catch {
            guard revision == observedRevision else { return }
            let issue = (error as? TeamsIssue) ?? .unexpected(error.localizedDescription)
            reading = nil
            publish(issue.isUnavailable ? .unavailable(issue) : .failed(issue))
        }
    }

    private func finish(_ status: TeamsStatus, request: Request) {
        guard request.revision == revision else { return }
        publish(status)
    }

    private func publish(_ newStatus: TeamsStatus) {
        status = newStatus
        onChange?(newStatus, lastIssue)
    }
}
