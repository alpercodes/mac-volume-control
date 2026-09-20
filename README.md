# Volume Control

A menu bar app for macOS that gives every app its own volume slider (0–200%), with FaceTime pinned at the top.
Volumes are remembered per app, so FaceTime is back at your level on every call.

Requires macOS 15 or newer. Runs on both Apple silicon and Intel Macs.

## Using it

Click the slider icon in the menu bar.

- **Slider**: sets the app's volume. It snaps to 100% near the middle. Above 100%, peaks are softly limited
  instead of distorting.
- **Speaker button**: mutes or unmutes the app.
- **Percentage**: click it to reset the app to 100%.
- **Switch next to "App Volume"**: turns the whole thing off. Every app then plays normally, and your settings
  are kept for when you turn it back on. While it's off, the menu bar icon is struck through.
- **Reset All**: puts every app back at 100% and unmuted, and forgets the saved volumes.
- **Open at Login**: starts the app automatically.
- **Quit**: stops all routing immediately; every app plays normally. Saved volumes and the on/off switch are
  remembered and apply again the next time Volume Control starts.

Apps that aren't running keep their setting and are shown dimmed. The FaceTime slider covers calls, which macOS
plays through the `avconferenced` background process, and the ringtone.

The first time you set an app away from 100%, macOS asks for **System Audio Recording** permission. The app
needs it to take an app's audio and play it back at your volume. Nothing is recorded or saved. If you denied
it, enable "Volume Control" in System Settings → Privacy & Security → Screen & System Audio Recording.

**During calls:** macOS turns every other app down while you're on a call (FaceTime, and other calling apps), by
up to 15 dB, and keeps changing the amount as people talk. While Volume Control is on, that doesn't happen: every
app plays at the volume it would have without a call, times its slider. Turn Volume Control off (the switch at the
top) to get macOS's normal lowering back. A call is detected as an app using the microphone and the speakers at the
same time.

Your normal volume controls (keyboard keys, Control Center, AirPods) keep working as usual. They set the overall
level, and the app sets each app's level relative to it.

## How it works

Outside calls, apps at 100% are never touched. When an app with a custom volume plays audio (or, during a call,
any app that plays audio), Volume Control creates a Core Audio *process tap* for it. The tap mutes the app's own
output and hands its audio to Volume Control, which plays it on the current output device at the chosen gain,
exempt from call ducking. A tap is removed 15 seconds after its app goes quiet, a couple of seconds after it's no
longer needed (the app is back at 100% outside a call), and immediately when you turn Volume Control off or quit
it. If Volume Control crashes, macOS unmutes the apps automatically.

## Versions

The version is `CFBundleShortVersionString` in `Resources/Info.plist`; bump it before building a release. Each
version's disk image is kept in `releases/`.

- **0.1**: first stable version.
- **0.2**: shipped as a disk image instead of a zip; quits any other running copy and offers to trash older copies
  after an update; remembers "Open at Login" across updates; lighter on battery (safety check every 5 s instead of
  2 s, audio released 15 s after an app goes quiet instead of 30 s).
- **0.3**: audio from helper processes that macOS doesn't attribute to their app is now matched to the app by its
  bundle ID (e.g. "Google Chrome Helper" → Chrome, WhatsApp's call extension → WhatsApp), so those apps get their own
  slider and aren't left quieter than Safari during calls.
- **0.3.1**: after an update, asks for the audio permission at launch, and the permission banner's button shows
  the macOS prompt ("Allow…") instead of sending you to System Settings, which can still show the previous version
  as allowed.
- **0.4**:
  - While routing audio, the permission is re-checked every 30 s instead of every 5 s. Opening the panel still
    checks right away.
  - Right after waking from sleep, audio that hasn't resumed yet is no longer mistaken for a stall (which rebuilt
    the audio path and could cause a blip). The app also re-syncs which apps are playing on wake.
  - **Reset All** button: every app back to 100% and unmuted.
- **0.4.1**: clicking the menu bar icon while the panel is open now closes it (the click used to close and
  immediately reopen it).
- **0.4.2**: the menu bar icon stays highlighted while the panel is open. On macOS 27 the menu bar draws the
  status item itself, so the app now hands the panel to it (`NSStatusItemExpandedInterfaceSession`) the way the
  system's own menu bar panels do: the menu bar highlights the icon, closes the panel on the next click, and
  includes it in menu bar keyboard navigation. Older versions of macOS keep the previous behaviour.

## Building

Only the Xcode Command Line Tools are needed (`xcode-select --install`).

```sh
./build.sh           # builds build/Volume Control.app and releases/Volume Control <version>.dmg
./build.sh install   # also copies it to ~/Applications and launches it
```

The app is signed ad hoc, so macOS may ask for the audio permission again after each rebuild.

Logs: `/usr/bin/log stream --level debug --predicate 'subsystem == "dev.alper.VolumeControl"'`

## Sharing it with someone

Send the newest disk image from `releases/`, e.g. `Volume Control 0.4.2.dmg` (AirDrop, Messages, iCloud Drive).
On their Mac:

1. Double-click the disk image and drag **Volume Control** onto the **Applications** shortcut next to it.
2. Open it from Applications. macOS says it can't verify the app, because it isn't signed with a paid Apple
   Developer account. Click **Done**.
3. Go to **System Settings → Privacy & Security**, scroll down and click **Open Anyway**.
4. Allow **System Audio Recording** when asked.

macOS treats every new build as a new app, so after each update it asks for the audio permission again, even
though System Settings may still show "Volume Control" as allowed (that entry is the previous build's). Click
**Allow** in the prompt, or **Allow…** in the app's panel.

**Updating:** quit Volume Control (menu bar icon → Quit), open the new disk image, drag the app onto Applications
and choose **Replace**. Steps 2–4 are needed again for every new build. If an old copy ends up next to the new one
anyway (e.g. "Volume Control 2"), the new version offers to move the old one to the Trash, and it always quits any
other copy that's still running, so two copies never handle the same audio.

## Known limitations

- While on, apps also aren't lowered by other things that duck audio, such as Siri speaking, as long as they're
  playing through Volume Control (custom volume, or any app during a call).
- An app that plays to a specific device (for example Zoom set to a USB headset rather than the system
  output) is played on the system output device while its volume isn't 100%.
- When audio starts, the first fraction of a second can play at the original volume before the tap takes over.
- On a FaceTime call on speakers (not headphones), changing the call volume might affect echo cancellation for
  the other person. If they hear an echo, use headphones or set FaceTime back to 100%.
