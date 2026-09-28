# Push To Talk for macOS

A tiny macOS menu-bar app: hold **Fn** to unmute **Microsoft Teams**, release to mute Teams again. Teams' own mute indicator changes, including the indicator other participants see. The source build defaults to **Microsoft Teams (native)** mode; **System microphones (legacy)** remains an explicit menu choice.

In Teams mode, a **hollow gray dot** with **Waiting for a Teams call** means Teams is not running or no accessible meeting window is available. A **red dot** means Teams was observed muted and a **green dot** means it was observed live. During a normal transition, the dot stays at the last confirmed state until Teams confirms the change; there is no reload/spinner icon. Pending text remains in the menu/tooltip. Missing Accessibility permission and real control/read failures show an **orange warning**, not standby. An unconfirmed mute stays a warning even if the meeting window disappears. Teams mode does not play this app's mute/unmute sounds; Teams supplies its own.

## Install (prebuilt)

Grab the latest `PushToTalk-x.y.z.zip` from the [Releases page](https://github.com/crittermike/macos-push-to-talk/releases), unzip, and drag `Push To Talk.app` to `/Applications`.

Version 0.4.0 adds native Teams mode. When upgrading from v0.3.0, quit the old app through its menu before replacing it so its system microphone levels are restored. The new app may need Accessibility permission granted again.

The release binary is unsigned (ad-hoc signed only). On first launch, macOS Gatekeeper will block it — right-click the app → **Open**, then click **Open** in the dialog. Or run:

```sh
xattr -dr com.apple.quarantine "/Applications/Push To Talk.app"
```

## Build from source

Requires macOS 13+ and the Swift toolchain (`xcode-select --install`).

```sh
./test.sh
./build-app.sh
```

The build script creates an ad-hoc-signed `Push To Talk.app` in this repo, without installing or launching it. It refuses to overwrite an existing bundle. To stage a replacement without modifying a running copy, use a different local bundle name:

```sh
./build-app.sh "Push To Talk AX Fix.app"
```

Quit the current copy through its menu before opening the replacement. Rebuilds or a new app path can require granting Accessibility again; the script does not change permissions.

Tests use a fake Teams client: they do not operate your real microphone or Teams. With full Xcode installed, `./test.sh` runs `swift test` (also used in CI). Command Line Tools alone do not include XCTest; in that environment the script compiles and runs the same test methods with a small dependency-free assertion runner.

## Local test / first run

1. **Quit the old Push To Talk app through its menu first.** The v0.3.0 app must restore the OS mic levels it changed. Do not run both copies at once.
2. Open the new bundle from this repo, not `/Applications`:

   ```sh
   open "./Push To Talk.app"
   ```

3. Grant **Accessibility** in **System Settings → Privacy & Security → Accessibility**, then quit and relaunch. If an old entry does not authorize the new build, remove/re-add the new bundle. The app's **Accessibility Settings...** menu item opens that pane. Accessibility is needed for both global Fn detection and Teams controls.
4. Confirm **Control Mode → Microsoft Teams (native)** is selected. The mode choice, sounds, and login setting are remembered. **Launch at Login** is still enabled on first run; disable it while testing if you do not want this local copy used at login.
5. Join a Teams meeting with its meeting window open and not minimized. The app initially **observes** the existing mute state; it does not automatically unmute or mute a newly discovered meeting.
6. Focus another app, then hold Fn and release. Verify **Teams' own mic button/indicator** changes, not just whether audio is audible. Ask another participant to check your mute indicator. Try a quick tap and a normal hold.
7. Check System Settings input levels and any other mic controls: Teams mode must leave them unchanged. Also try muting directly in Teams while holding Fn; the app should reflect that mute without trying to undo it.

## Teams mode: behavior and limits

- Uses native macOS Accessibility on `com.microsoft.teams2` or `com.microsoft.teams`, not the retired Teams localhost API, keyboard shortcut injection, or focus switching. It enables Teams' Chromium Accessibility tree, finds a self-mic **button** in a window with a **Leave** button, reads its state, and presses only when a change is needed.
- Currently requires the exact English action labels **Mute mic** / **Unmute mic**, plus **Leave**, **Leave call**, or **Hang up**. These labels name the action: **Unmute mic means currently muted**. Unknown labels, settings checkboxes, participant controls, multiple matching mic buttons, and multiple Teams app instances are not guessed at.
- Accessibility runs off the main thread with bounded message timeouts and tree scans. Changes are serialized, rapid Fn events are coalesced, and two delayed matching readbacks are required after a press. A release revokes pending unmute permission and waits for an in-flight unmute before remuting. A successful AX press alone is not treated as confirmation.
- AX read failures include the failing API, attribute, and any array range in the menu/tooltip. Empty window/child arrays are checked by count before any indexed read; they do not imply a mute state.
- A disabled control (for example, an organizer restriction) is never pressed. State is observed about twice a second. Manual/organizer changes are reflected, not continuously overridden. Discovery or permission recovery never replays a failed Fn hold; release Fn and press again once connected.
- **No CoreAudio mute or volume writes occur in Teams mode, and it never falls back to OS blocking.** Other apps can still use the microphone. If Teams is already unmuted at launch or you unmute manually while Fn is released, it stays live until you perform a hold/release or mute directly in Teams.
- Sleep, session resignation, screen-lock notifications, mode changes, and normal quit end a hold and attempt to remute. Waking/unlocking does not request unmute. Quit waits for the bounded remute attempt and warns if it could not be confirmed.
- **This is UI automation, not an officially stable Teams API or a hard privacy guarantee.** Minimized/hidden/undiscoverable meeting windows, language differences, permission loss, Teams updates, a stalled AX call, force quit, or a crash can prevent muting. An orange warning is **not muted**: check and mute directly in Teams. If an unconfirmed action leaves the warning latched, mute in Teams and restart Push To Talk.
- Automated tests and a local build do **not** validate live compatibility with the installed Teams build. Verify in a real meeting before relying on it.

## Legacy system microphone mode

Choose **Control Mode → System microphones (legacy)** for the original system-wide use case. This mode starts muted and uses CoreAudio hardware mute **and** input-volume zeroing on all controllable input devices. It watches device/default-input changes. Holding Fn restores saved input levels; releasing mutes again. It does not change Teams' mute indicator.

When leaving legacy mode or quitting, its listeners are disabled and only the mute/volume settings it saved are restored, including pre-existing mute and zero-volume settings. Failures are shown rather than treated as muted. Quit through the menu to restore those settings; a crash or force quit cannot do that cleanup. Audio-routing/virtual devices may not expose usable mute or volume controls.

## Shared features

- Watches `NSEvent.flagsChanged` globally for `.function`. Some external keyboards do not expose a usable Fn key. Ordinary application focus changes do not end a hold.
- Configurable transition sounds in **legacy system microphone mode**: **Tink** for unmute and **Pop** for mute by default, played only after a confirmed change. Pick sounds or **None** from the two sound submenus. Saved choices and sound previews are unchanged; Teams mode never plays app-generated transition sounds.
- Launch at login uses `SMAppService` (macOS 13+).

## Releases

Tagging a `v*` tag on `main` triggers `.github/workflows/release.yml`, which builds the app on `macos-14`, zips `Push To Talk.app`, and uploads it to a GitHub Release with a SHA-256 sum.
