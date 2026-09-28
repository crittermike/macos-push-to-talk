# Push To Talk for macOS

Speak in Teams without switching away from the app you're working in. Hold **Fn** to unmute; release it to mute. Other participants see your real Teams mute indicator, not an always-unmuted mic.

Teams mode leaves other apps' microphones alone and adds no competing mute/unmute sounds.

## Install

**[Download the latest release](https://github.com/crittermike/macos-push-to-talk/releases/latest)**, unzip it, and drag **Push To Talk.app** to **Applications**.

Requires **macOS 13+** and the **English-language Microsoft Teams desktop app**. The prebuilt app is for **Apple silicon**.

Quit any previous copy through its menu before replacing it. If macOS blocks opening the app, use **System Settings > Privacy & Security > Open Anyway**.

Grant access in **System Settings > Privacy & Security > Accessibility**, then quit and relaunch. After an upgrade, you may need to remove and re-add the app's Accessibility entry.

## Use

Select **Control Mode > Microsoft Teams (native)**. Join a meeting and **mute yourself in Teams first**: the app observes your existing state rather than muting automatically when you join.

Keep the meeting window open and not minimized. Focus another app, then hold **Fn** whenever you want to speak and release it when you're done.

**Menu bar:**

- ○ = waiting for a Teams call
- 🔴 = muted
- 🟢 = live
- ⚠️ = check and mute directly in Teams.

During changes, the dot keeps the last confirmed state.

Use **Launch at Login** in the menu to keep the app available.

## Other calling apps

Choose **Control Mode > System microphones (legacy)** to mute system microphones instead. It does not update the calling app's mute indicator. Quit through the menu to restore your input settings.
