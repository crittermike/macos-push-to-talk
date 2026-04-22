# Push To Talk for macOS

A tiny macOS menu-bar app: hold **Fn** to unmute your microphone, release to mute. Plays a subtle sound on each transition. Red dot in the menu bar when muted, green when live.

## Install (prebuilt)

Grab the latest `PushToTalk-x.y.z.zip` from the [Releases page](https://github.com/crittermike/macos-push-to-talk/releases), unzip, and drag `PushToTalk.app` to `/Applications`.

The release binary is unsigned (ad-hoc signed only). On first launch, macOS Gatekeeper will block it — right-click the app → **Open**, then click **Open** in the dialog. Or run:

```sh
xattr -dr com.apple.quarantine /Applications/PushToTalk.app
```

## Build from source

Requires macOS 13+ and the Swift toolchain (`xcode-select --install`).

```sh
./build-app.sh
open ./PushToTalk.app
```

## First run

1. Launch the app — red dot appears in the menu bar.
2. macOS prompts for **Accessibility** permission (needed to see the Fn key globally). Grant it in **System Settings → Privacy & Security → Accessibility**, then quit & relaunch.
3. **Launch at Login** is enabled automatically on first run. Toggle it from the menu bar item if you don't want that.
4. Hold **Fn** to talk. Release to mute.

## How it works

- Watches `NSEvent.flagsChanged` globally for the `.function` modifier.
- Toggles the default input device's mute state via CoreAudio (`kAudioDevicePropertyMute`); falls back to driving input volume to 0/1 on devices that don't expose hardware mute.
- Plays the system sounds **Tink** (unmute) and **Pop** (mute) at low volume.
- Starts muted; restores unmuted on quit so you don't get stuck silenced.
- Launch at login uses `SMAppService` (macOS 13+).

## Caveats

- The bare **Fn** key isn't usable as a hotkey for *every* mac app, but `flagsChanged` does see it. On some external keyboards there is no Fn key — change `.function` in `main.swift` to e.g. `.option` to use Right ⌥ instead.
- Audio routing apps (Krisp, etc.) may intercept mute on their own virtual device; switch your input to the underlying physical device for reliable behavior.
- Quit via the menu bar to avoid being left muted.

## Releases

Tagging a `v*` tag on `main` triggers `.github/workflows/release.yml`, which builds the app on `macos-14`, zips `PushToTalk.app`, and uploads it to a GitHub Release with a SHA-256 sum.

