import Cocoa
import CoreAudio
import AudioToolbox
import ServiceManagement

// MARK: - Microphone control via CoreAudio

final class MicController: SystemMicrophone {
    /// Per-device saved input volumes so unmute restores the user's level instead of slamming to 1.0.
    /// Saved on the FIRST mute we apply to each device so we capture the user's true setting
    /// (including 0, which means "user keeps this mic muted").
    private var savedVolumes: [AudioDeviceID: [UInt32: Float32]] = [:]
    private var savedMutes: [AudioDeviceID: UInt32] = [:]
    private var currentMuted: Bool = true
    private var active = true
    private var defaultDeviceListener: AudioObjectPropertyListenerBlock?
    private var deviceListListener: AudioObjectPropertyListenerBlock?
    private var listenerIssues: [String] = []
    var onFailure: ((String) -> Void)?

    private struct Failure: LocalizedError {
        let messages: [String]
        var errorDescription: String? { messages.joined(separator: "; ") }
    }

    init() {
        installDefaultInputDeviceListener()
        installDeviceListListener()
    }

    func setMuted(_ muted: Bool) throws {
        guard active else { throw Failure(messages: ["Legacy controller is stopped"]) }
        currentMuted = muted
        try applyMuted(muted)
    }

    /// Re-applies the most recently requested mute state. Used when the default input device changes
    /// or when the device list changes (e.g., a USB mic is plugged in, or an app spins up an aggregate device).
    func reapply() {
        guard active else { return }
        do {
            try applyMuted(currentMuted)
        } catch {
            NSLog("Push To Talk: %@", error.localizedDescription)
            onFailure?(error.localizedDescription)
        }
    }

    func stop() throws {
        active = false
        var issues: [String] = []
        removeListener(&defaultDeviceListener, selector: kAudioHardwarePropertyDefaultInputDevice, issues: &issues)
        removeListener(&deviceListListener, selector: kAudioHardwarePropertyDevices, issues: &issues)
        for (device, original) in savedMutes {
            var address = inputAddress(kAudioDevicePropertyMute)
            if write(original, device: device, address: &address, issues: &issues) {
                savedMutes.removeValue(forKey: device)
            }
        }
        for (device, channels) in savedVolumes {
            for (channel, original) in channels {
                var address = inputAddress(kAudioDevicePropertyVolumeScalar, channel: channel)
                if write(original, device: device, address: &address, issues: &issues) {
                    savedVolumes[device]?.removeValue(forKey: channel)
                }
            }
        }
        if !issues.isEmpty { throw Failure(messages: issues) }
    }

    private func applyMuted(_ muted: Bool) throws {
        var issues = listenerIssues
        let devices = Self.allInputDeviceIDs()
        if devices.isEmpty { issues.append("No input devices found") }
        for device in devices {
            applyMuted(muted, to: device, issues: &issues)
        }
        if !issues.isEmpty { throw Failure(messages: issues) }
    }

    private func applyMuted(_ muted: Bool, to dev: AudioDeviceID, issues: inout [String]) {
        var muteAddr = inputAddress(kAudioDevicePropertyMute)
        var controllable = false
        if AudioObjectHasProperty(dev, &muteAddr) && isSettable(dev, &muteAddr) {
            if muted, savedMutes[dev] == nil {
                var original: UInt32 = 0
                var size = UInt32(MemoryLayout<UInt32>.size)
                let status = AudioObjectGetPropertyData(dev, &muteAddr, 0, nil, &size, &original)
                if status == noErr { savedMutes[dev] = original }
                else { issues.append("Cannot save mute for device \(dev) (\(status))") }
            }
            if savedMutes[dev] != nil {
                controllable = true
                _ = write(UInt32(muted ? 1 : 0), device: dev, address: &muteAddr, issues: &issues)
            }
        }
        // Always also drive the volume scalar: some devices accept mute=1 but the scalar is what
        // actually carries audio through Core Audio routing apps. If the hardware mute didn't take
        // (or doesn't exist), the scalar is our only line of defense.
        for channel: UInt32 in 0...4 {
            var addr = inputAddress(kAudioDevicePropertyVolumeScalar, channel: channel)
            guard AudioObjectHasProperty(dev, &addr), isSettable(dev, &addr) else { continue }
            if muted {
                if savedVolumes[dev]?[channel] == nil {
                    var current: Float32 = 0
                    var size = UInt32(MemoryLayout<Float32>.size)
                    let status = AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &current)
                    if status == noErr {
                        savedVolumes[dev, default: [:]][channel] = current
                    } else {
                        issues.append("Cannot save volume for device \(dev), channel \(channel) (\(status))")
                    }
                }
            }
            if let original = savedVolumes[dev]?[channel] {
                controllable = true
                _ = write(muted ? Float32(0) : original, device: dev, address: &addr, issues: &issues)
            }
        }
        if muted, !controllable { issues.append("Device \(dev) has no controllable input mute or volume") }
    }

    private func inputAddress(_ selector: AudioObjectPropertySelector, channel: UInt32 = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeInput, mElement: channel)
    }

    private func write<T>(_ value: T, device: AudioDeviceID, address: inout AudioObjectPropertyAddress, issues: inout [String]) -> Bool {
        let status = withUnsafePointer(to: value) {
            AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<T>.size), $0)
        }
        if status != noErr { issues.append("Cannot update device \(device) (\(status))") }
        return status == noErr
    }

    private func removeListener(_ block: inout AudioObjectPropertyListenerBlock?, selector: AudioObjectPropertySelector, issues: inout [String]) {
        guard let installed = block else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, installed
        )
        block = nil
        if status != noErr { issues.append("Cannot remove audio device listener (\(status))") }
    }

    private func isSettable(_ dev: AudioDeviceID, _ addr: UnsafeMutablePointer<AudioObjectPropertyAddress>) -> Bool {
        var settable: DarwinBoolean = false
        let status = AudioObjectIsPropertySettable(dev, addr, &settable)
        return status == noErr && settable.boolValue
    }

    private func installDefaultInputDeviceListener() {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async { self?.reapply() }
        }
        defaultDeviceListener = block
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &addr,
            DispatchQueue.main,
            block
        )
        if status != noErr {
            defaultDeviceListener = nil
            listenerIssues.append("Cannot watch default input device (\(status))")
        }
    }

    private func installDeviceListListener() {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            // A device was added or removed (e.g., USB mic plugged in, or Teams/Zoom created an
            // aggregate device). Re-apply our current mute state so the new device honors it too.
            DispatchQueue.main.async { self?.reapply() }
        }
        deviceListListener = block
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &addr,
            DispatchQueue.main,
            block
        )
        if status != noErr {
            deviceListListener = nil
            listenerIssues.append("Cannot watch input device changes (\(status))")
        }
    }

    /// All audio devices that expose at least one input stream.
    static func allInputDeviceIDs() -> [AudioDeviceID] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &dataSize
        ) == noErr, dataSize > 0 else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        let status = ids.withUnsafeMutableBufferPointer { buf -> OSStatus in
            return AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &dataSize, buf.baseAddress!
            )
        }
        guard status == noErr else { return [] }
        return ids.filter { hasInputStreams($0) }
    }

    private static func hasInputStreams(_ dev: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(dev, &addr, 0, nil, &size) == noErr else { return false }
        return size > 0
    }

    static func defaultInputDeviceID() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID
        )
        return status == noErr && deviceID != 0 ? deviceID : nil
    }
}

// MARK: - App

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var statusTextItem: NSMenuItem!
    private var diagnosticItem: NSMenuItem!
    private var modeMenu: NSMenu!
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var refreshTimer: Timer?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var lockObservers: [NSObjectProtocol] = []
    private var fnDown = false
    private var requireFnRelease = false
    private var sessionActive = true
    private var terminating = false
    private var modeChangePending = false
    private var feedback = ControlFeedback()
    private var lastLoggedStatus: String?
    private var modes: ModeController!

    private var unmuteSound: NSSound?
    private var muteSound: NSSound?
    private var launchAtLoginItem: NSMenuItem!
    private var unmuteSoundMenu: NSMenu!
    private var muteSoundMenu: NSMenu!

    private static let availableSoundNames: [String] = [
        "Basso", "Blow", "Bottle", "Frog", "Funk", "Glass",
        "Hero", "Morse", "Ping", "Pop", "Purr", "Sosumi",
        "Submarine", "Tink",
    ]
    private static let unmuteSoundDefaultsKey = "unmuteSoundName"
    private static let muteSoundDefaultsKey = "muteSoundName"
    private static let defaultUnmuteSoundName = "Tink"
    private static let defaultMuteSoundName = "Pop"
    // Empty string in UserDefaults represents the "None" choice.
    private static let noneSoundStoredValue = ""
    private static let noneSoundDisplayName = "None"
    private static let modeDefaultsKey = "microphoneControlMode"

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Push To Talk — hold Fn to talk", action: nil, keyEquivalent: ""))
        statusTextItem = NSMenuItem(title: "Checking Teams...", action: nil, keyEquivalent: "")
        diagnosticItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        menu.addItem(statusTextItem)
        menu.addItem(diagnosticItem)
        menu.addItem(NSMenuItem.separator())

        let modeItem = NSMenuItem(title: "Control Mode", action: nil, keyEquivalent: "")
        modeMenu = NSMenu()
        modeMenu.autoenablesItems = false
        for mode in MicrophoneMode.allCases {
            let item = NSMenuItem(title: mode.title, action: #selector(selectMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            modeMenu.addItem(item)
        }
        modeItem.submenu = modeMenu
        menu.addItem(modeItem)
        let accessibilityItem = NSMenuItem(title: "Accessibility Settings...", action: #selector(openAccessibilitySettings), keyEquivalent: "")
        accessibilityItem.target = self
        menu.addItem(accessibilityItem)
        menu.addItem(NSMenuItem.separator())

        let unmuteSoundItem = NSMenuItem(title: "Unmute Sound", action: nil, keyEquivalent: "")
        unmuteSoundMenu = buildSoundMenu(action: #selector(selectUnmuteSound(_:)))
        unmuteSoundItem.submenu = unmuteSoundMenu
        menu.addItem(unmuteSoundItem)

        let muteSoundItem = NSMenuItem(title: "Mute Sound", action: nil, keyEquivalent: "")
        muteSoundMenu = buildSoundMenu(action: #selector(selectMuteSound(_:)))
        muteSoundItem.submenu = muteSoundMenu
        menu.addItem(muteSoundItem)

        menu.addItem(NSMenuItem.separator())
        launchAtLoginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launchAtLoginItem.target = self
        menu.addItem(launchAtLoginItem)
        menu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem.menu = menu

        reloadSounds()
        refreshSoundMenuStates()

        let key = "didAttemptInitialLoginRegistration"
        if !UserDefaults.standard.bool(forKey: key) {
            do {
                try SMAppService.mainApp.register()
            } catch {
                NSLog("Push To Talk: initial login registration failed: %@", error.localizedDescription)
            }
            UserDefaults.standard.set(true, forKey: key)
        }
        refreshLaunchAtLoginState()

        ensureAccessibilityPermission()

        let savedMode = UserDefaults.standard.string(forKey: Self.modeDefaultsKey)
        let mode = savedMode.flatMap(MicrophoneMode.init(rawValue:)) ?? .teams
        modes = ModeController(
            mode: mode,
            makeTeams: { TeamsController(client: TeamsAccessibility()) },
            makeSystem: { MicController() }
        )
        modes.onChange = { [weak self] status in self?.showStatus(status) }
        modes.start()
        refreshModeMenu()
        requireFnRelease = NSEvent.modifierFlags.contains(.function)

        let mask: NSEvent.EventTypeMask = .flagsChanged
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handleFlags(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handleFlags(event)
            return event
        }
        installLifecycleObservers()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshState() }
        }
        refreshTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateLater }
        terminating = true
        modes.endHold()
        refreshTimer?.invalidate()
        showStatus(.switching)
        refreshModeMenu()
        Task {
            if let failure = await modes.stop() {
                let alert = NSAlert()
                alert.messageText = "Check your microphone before continuing"
                alert.informativeText = failure
                alert.runModal()
            }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let m = globalMonitor { NSEvent.removeMonitor(m) }
        if let m = localMonitor { NSEvent.removeMonitor(m) }
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        for observer in lockObservers { DistributedNotificationCenter.default().removeObserver(observer) }
    }

    private func handleFlags(_ event: NSEvent) {
        let down = event.modifierFlags.contains(.function)
        guard !terminating, !modeChangePending, sessionActive, AXIsProcessTrusted() else { return }
        if requireFnRelease {
            if !down { requireFnRelease = false }
            return
        }
        guard down != fnDown else { return }
        fnDown = down
        modes.setHeld(down)
    }

    private func endHold() {
        fnDown = false
        requireFnRelease = true
        modes.endHold()
    }

    private func refreshState() {
        guard !terminating else { return }
        let physicallyDown = NSEvent.modifierFlags.contains(.function)
        if !physicallyDown {
            if fnDown { endHold() }
            requireFnRelease = false
        }
        if !AXIsProcessTrusted() { endHold() }
        if sessionActive { modes.refresh() }
    }

    private func installLifecycleObservers() {
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            workspaceObservers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.sessionActive = false
                    self?.endHold()
                }
            })
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            workspaceObservers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.sessionActive = true
                    self?.refreshState()
                }
            })
        }
        for (name, active) in [("com.apple.screenIsLocked", false), ("com.apple.screenIsUnlocked", true)] {
            lockObservers.append(DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name(name), object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.sessionActive = active
                    if active { self?.refreshState() }
                    else { self?.endHold() }
                }
            })
        }
    }

    @objc private func selectMode(_ sender: NSMenuItem) {
        guard !terminating, !modeChangePending,
              let value = sender.representedObject as? String,
              let mode = MicrophoneMode(rawValue: value), mode != modes.mode else { return }
        modeChangePending = true
        modes.endHold()
        fnDown = false
        requireFnRelease = true
        feedback = ControlFeedback()
        refreshModeMenu()
        Task {
            if await modes.select(mode) {
                UserDefaults.standard.set(mode.rawValue, forKey: Self.modeDefaultsKey)
            }
            modeChangePending = false
            refreshModeMenu()
        }
    }

    private func refreshModeMenu() {
        for item in modeMenu.items {
            item.state = (item.representedObject as? String) == modes.mode.rawValue ? .on : .off
            item.isEnabled = !terminating && !modeChangePending
        }
    }

    private func playSound(muted: Bool) {
        let s = muted ? muteSound : unmuteSound
        s?.stop()
        s?.volume = 0.35
        s?.play()
    }

    private func buildSoundMenu(action: Selector) -> NSMenu {
        let submenu = NSMenu()
        let noneItem = NSMenuItem(title: Self.noneSoundDisplayName, action: action, keyEquivalent: "")
        noneItem.target = self
        noneItem.representedObject = Self.noneSoundStoredValue
        submenu.addItem(noneItem)
        submenu.addItem(NSMenuItem.separator())
        for name in Self.availableSoundNames {
            let item = NSMenuItem(title: name, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = name
            submenu.addItem(item)
        }
        return submenu
    }

    private func currentUnmuteSoundName() -> String {
        return UserDefaults.standard.string(forKey: Self.unmuteSoundDefaultsKey) ?? Self.defaultUnmuteSoundName
    }

    private func currentMuteSoundName() -> String {
        return UserDefaults.standard.string(forKey: Self.muteSoundDefaultsKey) ?? Self.defaultMuteSoundName
    }

    private func reloadSounds() {
        let unmuteName = currentUnmuteSoundName()
        let muteName = currentMuteSoundName()
        unmuteSound = unmuteName.isEmpty ? nil : NSSound(named: NSSound.Name(unmuteName))
        muteSound = muteName.isEmpty ? nil : NSSound(named: NSSound.Name(muteName))
    }

    private func refreshSoundMenuStates() {
        let unmuteName = currentUnmuteSoundName()
        let muteName = currentMuteSoundName()
        for item in unmuteSoundMenu.items {
            guard let value = item.representedObject as? String else { continue }
            item.state = (value == unmuteName) ? .on : .off
        }
        for item in muteSoundMenu.items {
            guard let value = item.representedObject as? String else { continue }
            item.state = (value == muteName) ? .on : .off
        }
    }

    private func previewSound(name: String) {
        guard !name.isEmpty, let sound = NSSound(named: NSSound.Name(name)) else { return }
        sound.stop()
        sound.volume = 0.35
        sound.play()
    }

    @objc private func selectUnmuteSound(_ sender: NSMenuItem) {
        let name = (sender.representedObject as? String) ?? Self.noneSoundStoredValue
        UserDefaults.standard.set(name, forKey: Self.unmuteSoundDefaultsKey)
        reloadSounds()
        refreshSoundMenuStates()
        previewSound(name: name)
    }

    @objc private func selectMuteSound(_ sender: NSMenuItem) {
        let name = (sender.representedObject as? String) ?? Self.noneSoundStoredValue
        UserDefaults.standard.set(name, forKey: Self.muteSoundDefaultsKey)
        reloadSounds()
        refreshSoundMenuStates()
        previewSound(name: name)
    }

    private func showStatus(_ status: ControlStatus) {
        feedback.update(status)
        let title: String
        var detail = "Hold Fn to talk; release to mute."
        var symbol: String?
        var color = NSColor.secondaryLabelColor
        var failed = false
        switch status {
        case .teams(let state, let issue):
            if let issue { detail = issue.description }
            switch state {
            case .checking:
                title = "Teams: checking connection"
                symbol = "ellipsis.circle"
            case .changing(let muted):
                title = muted ? "Teams: confirming mute..." : "Teams: confirming unmute..."
                if let lastMuted = feedback.lastConfirmedMuted {
                    color = lastMuted ? .systemRed : .systemGreen
                } else {
                    symbol = "questionmark.circle"
                }
            case .ready(let reading):
                title = reading.muted ? "Teams: muted" : "Teams: live"
                color = reading.muted ? .systemRed : .systemGreen
                if !reading.canPress { detail = "Teams mic control is disabled; unmute may be restricted." }
            case .unavailable(let issue):
                title = issue == .permissionRequired ? "Teams: Accessibility required" : "Teams: not connected"
                detail = issue.description
                symbol = "questionmark.circle"
            case .failed(let issue):
                title = "Teams: state unknown"
                detail = issue.description
                color = .systemOrange
                symbol = "exclamationmark.triangle.fill"
                failed = true
            }
        case .system(let muted):
            title = muted ? "System microphones: muted (legacy)" : "System microphones: live (legacy)"
            detail = "Legacy mode changes CoreAudio, not Teams' mute indicator."
            color = muted ? .systemRed : .systemGreen
        case .switching:
            title = "Finishing microphone changes..."
            symbol = "ellipsis.circle"
            color = .systemYellow
        case .failed(let message):
            title = "Microphone control failed"
            detail = message
            color = .systemOrange
            symbol = "exclamationmark.triangle.fill"
            failed = true
        }
        if let notice = modes?.notice { detail += " \(notice)" }
        statusTextItem.title = title
        diagnosticItem.title = detail
        updateIcon(color: color, symbol: symbol, tooltip: "\(title)\n\(detail)")
        if let muted = feedback.transitionSoundMuted, !terminating {
            playSound(muted: muted)
        }
        let diagnostic = "\(title): \(detail)"
        if failed, diagnostic != lastLoggedStatus { NSLog("Push To Talk: %@", diagnostic) }
        lastLoggedStatus = diagnostic
    }

    private func updateIcon(color: NSColor, symbol: String?, tooltip: String) {
        guard let button = statusItem.button else { return }
        button.toolTip = tooltip
        button.setAccessibilityLabel(tooltip)
        if let symbol, let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip) {
            button.image = image
            button.contentTintColor = color
            return
        }
        let size = NSSize(width: 14, height: 14)
        let image = NSImage(size: size, flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 2, dy: 2)).fill()
            return true
        }
        image.isTemplate = false
        button.contentTintColor = nil
        button.image = image
    }

    private func ensureAccessibilityPermission() {
        let key = "AXTrustedCheckOptionPrompt" as CFString
        let opts = [key: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    @objc private func openAccessibilitySettings() {
        ensureAccessibilityPermission()
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    @objc private func toggleLaunchAtLogin() {
        let svc = SMAppService.mainApp
        do {
            if svc.status == .enabled {
                try svc.unregister()
            } else {
                try svc.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't update Launch at Login"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
        refreshLaunchAtLoginState()
    }

    private func refreshLaunchAtLoginState() {
        launchAtLoginItem.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
