import Cocoa
import CoreAudio
import AudioToolbox
import ServiceManagement

// MARK: - Microphone control via CoreAudio

enum Mic {
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
        return status == noErr ? deviceID : nil
    }

    @discardableResult
    static func setMuted(_ muted: Bool) -> Bool {
        guard let dev = defaultInputDeviceID() else { return false }
        var value: UInt32 = muted ? 1 : 0
        let size = UInt32(MemoryLayout<UInt32>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectHasProperty(dev, &addr) {
            let status = AudioObjectSetPropertyData(dev, &addr, 0, nil, size, &value)
            if status == noErr { return true }
        }
        // Fallback: drive input volume scalar to 0 / 1 across master + per-channel.
        return setInputVolume(dev: dev, volume: muted ? 0.0 : 1.0)
    }

    private static func setInputVolume(dev: AudioDeviceID, volume: Float32) -> Bool {
        var ok = false
        for channel: UInt32 in 0...2 {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: channel
            )
            if AudioObjectHasProperty(dev, &addr) {
                var v = volume
                let status = AudioObjectSetPropertyData(
                    dev, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &v
                )
                if status == noErr { ok = true }
            }
        }
        return ok
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var isTalking = false

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

        // Auto-enable launch at login on first run.
        let key = "didAttemptInitialLoginRegistration"
        if !UserDefaults.standard.bool(forKey: key) {
            try? SMAppService.mainApp.register()
            UserDefaults.standard.set(true, forKey: key)
        }
        refreshLaunchAtLoginState()

        ensureAccessibilityPermission()

        Mic.setMuted(true)
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
        Mic.setMuted(false)
        if let m = globalMonitor { NSEvent.removeMonitor(m) }
        if let m = localMonitor { NSEvent.removeMonitor(m) }
    }

    private func handleFlags(_ event: NSEvent) {
        let down = event.modifierFlags.contains(.function)
        guard down != isTalking else { return }
        isTalking = down
        Mic.setMuted(!down)
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
