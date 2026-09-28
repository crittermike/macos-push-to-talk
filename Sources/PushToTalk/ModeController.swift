import Foundation

enum MicrophoneMode: String, CaseIterable {
    case teams
    case system

    var title: String {
        switch self {
        case .teams: return "Microsoft Teams (native)"
        case .system: return "System microphones (legacy)"
        }
    }
}

@MainActor
protocol SystemMicrophone: AnyObject {
    var onFailure: ((String) -> Void)? { get set }
    func setMuted(_ muted: Bool) throws
    func stop() throws
}

enum ControlStatus {
    case teams(TeamsStatus, TeamsIssue?)
    case system(muted: Bool)
    case switching
    case failed(String)
}

struct ControlFeedback {
    private(set) var lastConfirmedMuted: Bool?
    private(set) var transitionSoundMuted: Bool?
    private(set) var standbyTitle: String?

    mutating func update(_ status: ControlStatus) {
        transitionSoundMuted = nil
        standbyTitle = nil
        switch status {
        case .teams(let state, _):
            switch state {
            case .ready(let reading):
                lastConfirmedMuted = reading.muted
            case .changing:
                break
            case .unavailable(let issue):
                lastConfirmedMuted = nil
                if issue.isExpectedAbsence { standbyTitle = "Waiting for a Teams call" }
            case .checking, .failed:
                lastConfirmedMuted = nil
            }
        case .system(let muted):
            if let previous = lastConfirmedMuted, previous != muted {
                transitionSoundMuted = muted
            }
            lastConfirmedMuted = muted
        case .switching, .failed:
            lastConfirmedMuted = nil
        }
    }
}

@MainActor
final class ModeController {
    private let makeTeams: () -> TeamsController
    private let makeSystem: () -> SystemMicrophone
    private var teams: TeamsController?
    private var system: SystemMicrophone?
    private var held = false
    private var stopped = false
    private(set) var switching = false
    private(set) var mode: MicrophoneMode
    private(set) var notice: String?
    var onChange: ((ControlStatus) -> Void)?

    init(mode: MicrophoneMode, makeTeams: @escaping () -> TeamsController, makeSystem: @escaping () -> SystemMicrophone) {
        self.mode = mode
        self.makeTeams = makeTeams
        self.makeSystem = makeSystem
    }

    func start() {
        guard teams == nil, system == nil, !stopped else { return }
        switch mode {
        case .teams:
            let controller = makeTeams()
            teams = controller
            controller.onChange = { [weak self] status, issue in
                guard let self, !self.switching, !self.stopped else { return }
                self.onChange?(.teams(status, issue))
            }
            onChange?(.teams(.checking, nil))
            controller.refresh()
        case .system:
            let controller = makeSystem()
            system = controller
            controller.onFailure = { [weak self] message in self?.onChange?(.failed(message)) }
            setSystemMuted(true)
        }
    }

    func setHeld(_ down: Bool) {
        guard !switching, !stopped, down != held else { return }
        held = down
        if let teams {
            teams.setHeld(down)
        } else {
            setSystemMuted(!down)
        }
    }

    func endHold() {
        setHeld(false)
    }

    func refresh() {
        guard !switching, !stopped else { return }
        teams?.refresh()
    }

    func select(_ newMode: MicrophoneMode) async -> Bool {
        guard newMode != mode, !switching, !stopped else { return false }
        switching = true
        held = false
        onChange?(.switching)
        notice = nil
        if let teams {
            await teams.stop()
            if let issue = teams.lastIssue, teams.status.confirmedMuted != true {
                notice = "Teams remute was not confirmed: \(issue.description)"
            }
        }
        self.teams = nil
        guard !stopped else {
            switching = false
            return false
        }
        do {
            try system?.stop()
        } catch {
            switching = false
            onChange?(.failed("Could not restore legacy microphone settings: \(error.localizedDescription). Check system input levels."))
            return false
        }
        system = nil
        mode = newMode
        switching = false
        start()
        return true
    }

    func stop() async -> String? {
        guard !stopped else { return nil }
        stopped = true
        held = false
        var failure: String?
        if let teams {
            await teams.stop()
            if let issue = teams.lastIssue, teams.status.confirmedMuted != true {
                let message = "Teams remute was not confirmed: \(issue.description)"
                failure = message
                NSLog("Push To Talk: %@", message)
            }
        }
        teams = nil
        do {
            try system?.stop()
        } catch {
            NSLog("Push To Talk: could not restore legacy microphone settings: %@", error.localizedDescription)
            let message = "Could not restore legacy microphone settings: \(error.localizedDescription)"
            failure = message
            onChange?(.failed(message))
        }
        system = nil
        return failure
    }

    private func setSystemMuted(_ muted: Bool) {
        guard let system else {
            onChange?(.failed("Legacy microphone control is stopped. Select a mode again."))
            return
        }
        do {
            try system.setMuted(muted)
            onChange?(.system(muted: muted))
        } catch {
            onChange?(.failed("Legacy microphone control failed: \(error.localizedDescription)"))
        }
    }
}
