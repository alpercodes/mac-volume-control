# Volume Control

A menu bar app for macOS that gives every app its own volume slider (0–200%), with FaceTime pinned at the top.
Volumes are remembered per app, so FaceTime is back at your level on every call.

Requires macOS 15 or newer. Runs on both Apple silicon and Intel Macs.

## Installing

Download the newest disk image from the
[releases page](https://github.com/alpercodes/mac-volume-control/releases), then:

1. Open the disk image and drag **Volume Control** onto the **Applications** shortcut next to it.
2. Open it from Applications. macOS says it can't verify the app, because it's signed ad hoc rather than with a
   paid Apple Developer account. Click **Done**.
3. Go to **System Settings → Privacy & Security**, scroll down and click **Open Anyway**.
4. Allow **System Audio Recording** when asked. That permission is how the app takes an app's audio and plays it
   back at your volume. Nothing is recorded or saved.

### Updating

Quit Volume Control (menu bar icon → Quit), open the new disk image, drag the app onto Applications and choose
**Replace**. Steps 2–4 are needed again for every build: macOS treats each one as a new app, so it asks for the
audio permission again even though System Settings may still list "Volume Control" as allowed (that entry belongs
to the previous build). Click **Allow** in the prompt, or **Allow…** in the app's panel.

If an old copy ends up beside the new one anyway (e.g. "Volume Control 2"), the new version offers to move the
old one to the Trash, and it always quits any other copy that's still running, so two copies never handle the
same audio.

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

The first time you set an app away from 100%, macOS asks for System Audio Recording permission. If you denied it,
enable "Volume Control" in System Settings → Privacy & Security → Screen & System Audio Recording, or use the
**Allow…** button in the app's panel.

Your normal volume controls (keyboard keys, Control Center, AirPods) keep working as usual. They set the overall
level, and the app sets each app's level relative to it.

### During calls

macOS turns every other app down while you're on a call (FaceTime, and other calling apps), by up to 15 dB, and
keeps changing the amount as people talk. While Volume Control is on, that doesn't happen: every app plays at the
volume it would have without a call, times its slider. Turn Volume Control off (the switch at the top) to get
macOS's normal lowering back. A call is detected as an app using the microphone and the speakers at the same
time.

## How it works

Outside calls, apps at 100% are never touched. When an app with a custom volume plays audio (or, during a call,
any app that plays audio), Volume Control creates a Core Audio *process tap* for it. The tap mutes the app's own
output and hands its audio to Volume Control, which plays it on the current output device at the chosen gain,
exempt from call ducking. A tap is removed 15 seconds after its app goes quiet, a couple of seconds after it's no
longer needed (the app is back at 100% outside a call), and immediately when you turn Volume Control off or quit
it. If Volume Control crashes, macOS unmutes the apps automatically.

### Undocumented interfaces

Two things here have no public API, and both are in the code with a comment explaining them:

- **Opting out of ducking** (`kAudioDevicePropertyProcessDuckOptOut`, the `'nodk'` device property) is what keeps
  audio played through Volume Control from being turned down by the call it's playing. Without it, routing a
  FaceTime call through the app would have the call duck itself. If a future macOS drops the property, the app
  logs a warning and everything still works, just quieter during calls.
- **Asking about the System Audio Recording permission** (`TCCAccessPreflight` and `TCCAccessRequest` for
  `kTCCServiceAudioCapture`, from the private TCC framework) is the only way to know whether permission was
  granted; Apple's own sample code for process taps uses the same two calls. If they disappear, the app assumes
  it has access and lets macOS put up its prompt when a tap is first read.

Relying on these means the app can't be distributed through the Mac App Store.

## Building from source

Building needs the **macOS 27 SDK** — Command Line Tools 27 (`xcode-select --install`) or Xcode 27 — because the
menu bar panel uses `NSStatusItemExpandedInterfaceSession`, which was introduced in macOS 27. The app that comes
out runs on macOS 15 and newer; only the toolchain has to be current. There's no Xcode project and no
dependencies.

```sh
./build.sh           # builds build/Volume Control.app and releases/Volume Control <version>.dmg
./build.sh install   # also copies it to ~/Applications and launches it
```

The build is universal (Apple silicon and Intel) and signed ad hoc, so macOS asks for the audio permission again
after each rebuild.

The version is `CFBundleShortVersionString` in `Resources/Info.plist`; bump it and add an entry to
[CHANGELOG.md](CHANGELOG.md) before building a release. `build/` and `releases/` aren't tracked; disk images are
published on the releases page.

Logs: `/usr/bin/log stream --level debug --predicate 'subsystem == "dev.alper.VolumeControl"'`

## Known limitations

- While on, apps also aren't lowered by other things that duck audio, such as Siri speaking, as long as they're
  playing through Volume Control (custom volume, or any app during a call).
- An app that plays to a specific device (for example Zoom set to a USB headset rather than the system
  output) is played on the system output device while its volume isn't 100%.
- When audio starts, the first fraction of a second can play at the original volume before the tap takes over.
- On a FaceTime call on speakers (not headphones), changing the call volume might affect echo cancellation for
  the other person. If they hear an echo, use headphones or set FaceTime back to 100%.

## Changes

See [CHANGELOG.md](CHANGELOG.md).
