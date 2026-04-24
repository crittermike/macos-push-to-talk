import Cocoa
import CoreAudio
import AudioToolbox
import ServiceManagement

// MARK: - Microphone control via CoreAudio

final class MicController {
    /// Per-device saved input volumes so unmute restores the user's level instead of slamming to 1.0.
    private var savedVolumes: [AudioDeviceID: [UInt32: Float32]] = [:]
    private var currentMuted: Bool = true
    private var deviceListenerProc: AudioObjectPropertyListenerBlock?

    init() {
        installDefaultInputDeviceListener()
    }

    func setMuted(_ muted: Bool) {
        currentMuted = muted
        applyMuted(muted)
    }

    /// Re-applies the most recently requested mute state. Used when the default input device changes.
    func reapply() {
        applyMuted(currentMuted)
    }

    private func applyMuted(_ muted: Bool) {
        guard let dev = Self.defaultInputDeviceID() else { return }

        // Try the hardware mute property first.
        var muteAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectHasProperty(dev, &muteAddr) && isSettable(dev, &muteAddr) {
            var value: UInt32 = muted ? 1 : 0
            let status = AudioObjectSetPropertyData(
                dev, &muteAddr, 0, nil,
                UInt32(MemoryLayout<UInt32>.size), &value
            )
            if status == noErr {
                // Some devices accept mute=1 but the volume scalar is what actually carries audio
                // through Core Audio routing apps. Drive volume too for belt-and-suspenders.
                applyVolumeFallback(dev: dev, muted: muted)
                return
            }
        }
        applyVolumeFallback(dev: dev, muted: muted)
    }

    private func applyVolumeFallback(dev: AudioDeviceID, muted: Bool) {
        for channel: UInt32 in 0...4 {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: channel
            )
            guard AudioObjectHasProperty(dev, &addr), isSettable(dev, &addr) else { continue }

            if muted {
                // Save current volume before zeroing.
                var current: Float32 = 0
                var size = UInt32(MemoryLayout<Float32>.size)
                if AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &current) == noErr {
                    if current > 0 {
                        savedVolumes[dev, default: [:]][channel] = current
                    }
                }
                var zero: Float32 = 0
                AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &zero)
            } else {
                var restore: Float32 = savedVolumes[dev]?[channel] ?? 1.0
                AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &restore)
            }
        }
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
            // Fired when the user (or system) changes the default input device.
            // Re-apply the current mute state to the new device.
            DispatchQueue.main.async { self?.reapply() }
        }
        deviceListenerProc = block
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &addr,
            DispatchQueue.main,
            block
        )
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

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var isTalking = false
    private let mic = MicController()

    private let unmuteSound = NSSound(named: NSSound.Name("Tink"))
    private let muteSound = NSSound(named: NSSound.Name("Pop"))
    private var launchAtLoginItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Push To Talk — hold Fn to talk", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        launchAtLoginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launchAtLoginItem.target = self
        menu.addItem(launchAtLoginItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu

        let key = "didAttemptInitialLoginRegistration"
        if !UserDefaults.standard.bool(forKey: key) {
            try? SMAppService.mainApp.register()
            UserDefaults.standard.set(true, forKey: key)
        }
        refreshLaunchAtLoginState()

        ensureAccessibilityPermission()

        mic.setMuted(true)
        updateIcon(muted: true)

        let mask: NSEvent.EventTypeMask = .flagsChanged
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handleFlags(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handleFlags(event)
            return event
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        mic.setMuted(false)
        if let m = globalMonitor { NSEvent.removeMonitor(m) }
        if let m = localMonitor { NSEvent.removeMonitor(m) }
    }

    private func handleFlags(_ event: NSEvent) {
        let down = event.modifierFlags.contains(.function)
        guard down != isTalking else { return }
        isTalking = down
        mic.setMuted(!down)
        updateIcon(muted: !down)
        playSound(muted: !down)
    }

    private func playSound(muted: Bool) {
        let s = muted ? muteSound : unmuteSound
        s?.stop()
        s?.volume = 0.35
        s?.play()
    }

    private func updateIcon(muted: Bool) {
        guard let button = statusItem.button else { return }
        let size = NSSize(width: 14, height: 14)
        let image = NSImage(size: size, flipped: false) { rect in
            let color = muted ? NSColor.systemRed : NSColor.systemGreen
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 2, dy: 2)).fill()
            return true
        }
        image.isTemplate = false
        button.image = image
        button.toolTip = muted ? "Muted (hold Fn to talk)" : "Talking…"
    }

    private func ensureAccessibilityPermission() {
        let key = "AXTrustedCheckOptionPrompt" as CFString
        let opts = [key: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(opts)
        if !trusted {
            let alert = NSAlert()
            alert.messageText = "Accessibility permission needed"
            alert.informativeText = "PushToTalk needs Accessibility access to detect the Fn key globally. Grant it in System Settings → Privacy & Security → Accessibility, then relaunch."
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
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

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
