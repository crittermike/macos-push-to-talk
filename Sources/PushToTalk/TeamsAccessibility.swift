import Cocoa
import ApplicationServices

enum TeamsButtonLabels {
    static func muted(role: String?, labels: [String]) -> Bool? {
        guard role == kAXButtonRole as String else { return nil }
        let values = labels.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        let states = values.compactMap { label -> Bool? in
            switch label {
            case "unmute mic": return true
            case "mute mic": return false
            default: return nil
            }
        }
        guard let first = states.first, states.allSatisfy({ $0 == first }) else { return nil }
        return first
    }

    static func isLeaveButton(role: String?, labels: [String]) -> Bool {
        guard role == kAXButtonRole as String else { return false }
        return labels.contains {
            ["leave", "leave call", "hang up"].contains(
                $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            )
        }
    }
}

enum TeamsAXArrayReader {
    static func read<Element>(
        attribute: String,
        limit: Int,
        count: () throws -> (AXError, Int),
        values: (Int) throws -> (AXError, [Element]?)
    ) throws -> [Element] {
        let countOperation = "AXUIElementGetAttributeValueCount(\(attribute))"
        let (countError, total) = try count()
        switch countError {
        case .success: break
        case .attributeUnsupported, .noValue: return []
        default: throw TeamsIssue.readFailed(countError.rawValue, operation: countOperation)
        }
        guard total >= 0 else {
            throw TeamsIssue.readFailed(AXError.illegalArgument.rawValue, operation: countOperation)
        }
        guard total <= limit else { throw TeamsIssue.discoveryLimit }
        // Index 0 is outside an empty AX array, even with a positive maxValues.
        guard total > 0 else { return [] }

        let operation = "AXUIElementCopyAttributeValues(\(attribute), index: 0, maxValues: \(total))"
        let (error, elements) = try values(total)
        guard error == .success else { throw TeamsIssue.readFailed(error.rawValue, operation: operation) }
        guard let elements else { throw TeamsIssue.readFailed(AXError.noValue.rawValue, operation: operation) }
        guard elements.count <= limit else { throw TeamsIssue.discoveryLimit }
        return elements
    }
}

// Actor isolation keeps every AX message and traversal off the main thread and serialized.
actor TeamsAccessibility: TeamsClient {
    private struct ElementIdentity: Hashable {
        let element: AXUIElement

        static func == (lhs: Self, rhs: Self) -> Bool { CFEqual(lhs.element, rhs.element) }
        func hash(into hasher: inout Hasher) { hasher.combine(CFHash(element)) }
    }

    private struct Control {
        let window: AXUIElement
        let button: AXUIElement
        let leaveButton: AXUIElement
        let identifier: String?
        let connectionID: String
        let windows: Set<ElementIdentity>
    }

    private var application: AXUIElement?
    private var pid: pid_t?
    private var cached: Control?
    private var connectionCounter = 0
    private var deadline = ProcessInfo.processInfo.systemUptime
    private let messageTimeout: Float = 0.15
    private let nodeLimit = 2_000

    func read() async throws -> TeamsReading {
        beginOperation()
        let control = try resolve()
        return try snapshot(control)
    }

    func setMuted(_ muted: Bool, connectionID: String, permit: UnmutePermit?) async throws -> TeamsAction {
        beginOperation()
        if !muted, permit?.isValid != true { return .cancelled }
        let control = try resolve()
        let current = try snapshot(control)
        guard current.connectionID == connectionID else { throw TeamsIssue.meetingChanged }
        if current.muted == muted { return .unchanged(current) }
        guard current.canPress else { throw TeamsIssue.disabled }
        try checkBudget()
        if !muted, permit?.isValid != true { return .cancelled }
        let error = AXUIElementPerformAction(control.button, kAXPressAction as CFString)
        guard error == .success else { throw TeamsIssue.pressFailed(error.rawValue) }
        return .pressed
    }

    private func beginOperation() {
        deadline = ProcessInfo.processInfo.systemUptime + 0.8
    }

    private func checkBudget() throws {
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw TeamsIssue.discoveryLimit }
    }

    private func resolve() throws -> Control {
        guard AXIsProcessTrusted() else {
            cached = nil
            throw TeamsIssue.permissionRequired
        }
        let running = ["com.microsoft.teams2", "com.microsoft.teams"]
            .flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0) }
            .filter { !$0.isTerminated }
        guard !running.isEmpty else {
            application = nil
            cached = nil
            pid = nil
            throw TeamsIssue.notRunning
        }
        guard running.count == 1, let app = running.first else { throw TeamsIssue.ambiguousControls }
        if pid != app.processIdentifier || application == nil {
            pid = app.processIdentifier
            cached = nil
            let element = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(element, messageTimeout)
            for attribute in ["AXManualAccessibility", "AXEnhancedUserInterface"] {
                try checkBudget()
                let error = AXUIElementSetAttributeValue(element, attribute as CFString, kCFBooleanTrue)
                if error != .success {
                    NSLog("Push To Talk: enabling %@ returned AX error %d", attribute, error.rawValue)
                }
            }
            application = element
        }
        guard let application else { throw TeamsIssue.notRunning }
        let windows = try elements(application, kAXWindowsAttribute as String, limit: 16)
        let windowIdentities = Set(windows.map { ElementIdentity(element: $0) })
        if let cached, cached.windows == windowIdentities,
           windowIdentities.contains(ElementIdentity(element: cached.window)) {
            do {
                guard try !isMinimized(cached.window),
                      TeamsButtonLabels.isLeaveButton(
                        role: try string(cached.leaveButton, kAXRoleAttribute as String),
                        labels: try labels(cached.leaveButton)
                      ) else { throw TeamsIssue.noMeeting }
                _ = try snapshot(cached)
                return cached
            } catch {
                self.cached = nil
                throw error
            }
        }

        let previous = cached
        cached = nil
        var matches: [(AXUIElement, AXUIElement, AXUIElement)] = []
        var visited = 0
        for window in windows {
            if try isMinimized(window) { continue }
            var stack: [(AXUIElement, Int)] = [(window, 0)]
            var microphones: [AXUIElement] = []
            var leaveButton: AXUIElement?
            var seen = Set<ElementIdentity>()
            while let (element, depth) = stack.popLast() {
                try checkBudget()
                guard visited < nodeLimit, depth <= 40 else { throw TeamsIssue.discoveryLimit }
                guard seen.insert(ElementIdentity(element: element)).inserted else { continue }
                visited += 1
                let role = try string(element, kAXRoleAttribute as String)
                if role == kAXButtonRole as String {
                    let captions = try labels(element)
                    if TeamsButtonLabels.muted(role: role, labels: captions) != nil {
                        microphones.append(element)
                    }
                    if TeamsButtonLabels.isLeaveButton(role: role, labels: captions) {
                        leaveButton = element
                    }
                }
                let children = try elements(element, kAXChildrenAttribute as String, limit: nodeLimit - visited)
                guard stack.count + children.count <= nodeLimit - visited else { throw TeamsIssue.discoveryLimit }
                stack.append(contentsOf: children.map { ($0, depth + 1) })
            }
            if let leaveButton {
                matches.append(contentsOf: microphones.map { (window, $0, leaveButton) })
            }
        }
        guard !matches.isEmpty else { throw TeamsIssue.noMeeting }
        guard matches.count == 1, let (window, button, leaveButton) = matches.first else {
            throw TeamsIssue.ambiguousControls
        }
        let identifier = try string(button, kAXIdentifierAttribute as String)
        let connectionID: String
        if let previous, CFEqual(previous.window, window), CFEqual(previous.button, button),
           previous.identifier == identifier {
            connectionID = previous.connectionID
        } else {
            connectionCounter += 1
            connectionID = "\(app.processIdentifier):\(connectionCounter)"
        }
        let control = Control(
            window: window, button: button, leaveButton: leaveButton, identifier: identifier,
            connectionID: connectionID, windows: windowIdentities
        )
        cached = control
        return control
    }

    private func snapshot(_ control: Control) throws -> TeamsReading {
        guard let muted = TeamsButtonLabels.muted(
            role: try string(control.button, kAXRoleAttribute as String),
            labels: try labels(control.button)
        ) else { throw TeamsIssue.noMeeting }
        guard let enabled = try attribute(control.button, kAXEnabledAttribute as String) as? Bool else {
            throw TeamsIssue.readFailed(
                AXError.noValue.rawValue, operation: "AXUIElementCopyAttributeValue(AXEnabled)"
            )
        }
        try checkBudget()
        var actionNames: CFArray?
        let error = AXUIElementCopyActionNames(control.button, &actionNames)
        guard error == .success else {
            throw TeamsIssue.readFailed(error.rawValue, operation: "AXUIElementCopyActionNames(self-mic)")
        }
        let actions = (actionNames as? [String]) ?? []
        return TeamsReading(
            connectionID: control.connectionID, muted: muted,
            canPress: enabled && actions.contains(kAXPressAction as String)
        )
    }

    private func isMinimized(_ window: AXUIElement) throws -> Bool {
        try attribute(window, kAXMinimizedAttribute as String) as? Bool == true
    }

    private func labels(_ element: AXUIElement) throws -> [String] {
        try [string(element, kAXTitleAttribute as String), string(element, kAXDescriptionAttribute as String)]
            .compactMap { $0 }
    }

    private func string(_ element: AXUIElement, _ name: String) throws -> String? {
        try attribute(element, name) as? String
    }

    private func attribute(_ element: AXUIElement, _ name: String) throws -> CFTypeRef? {
        try checkBudget()
        AXUIElementSetMessagingTimeout(element, messageTimeout)
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        switch error {
        case .success: return value
        case .attributeUnsupported, .noValue: return nil
        default:
            throw TeamsIssue.readFailed(error.rawValue, operation: "AXUIElementCopyAttributeValue(\(name))")
        }
    }

    private func elements(_ element: AXUIElement, _ name: String, limit: Int) throws -> [AXUIElement] {
        try TeamsAXArrayReader.read(
            attribute: name,
            limit: limit,
            count: {
                try checkBudget()
                AXUIElementSetMessagingTimeout(element, messageTimeout)
                var count = 0
                let error = AXUIElementGetAttributeValueCount(element, name as CFString, &count)
                return (error, count)
            },
            values: { count in
                try checkBudget()
                var value: CFArray?
                let error = AXUIElementCopyAttributeValues(element, name as CFString, 0, count, &value)
                return (error, value as? [AXUIElement])
            }
        )
    }
}
