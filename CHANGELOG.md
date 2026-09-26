# Changelog

Newest first. Every version's disk image is on the
[releases page](https://github.com/alpercodes/mac-volume-control/releases).

## 0.6 — 2026-09-26

- **Calls work differently.** Apps you haven't changed are no longer kept at full volume during calls: macOS
  lowers them as usual, and the panel shows where they are (say 40%, marked "Lowered by macOS for the call").
  The amount is measured live by a small helper inside the app, while you're on a call with the panel open,
  and remembered for the rest of the call. Where it can't be measured (an app playing to another device), the
  percentage reads "macOS". A phone icon next to the title shows that a call is on.
- **Volumes for calls.** Dragging a slider during a call sets the app's volume for calls: it plays steadily at
  that level, and every later call uses it too, while its normal volume stays as it was. Drag it back to the
  lowered level or click the percentage to hand it back to macOS; outside calls, "During calls: 60%" under the
  app shows it, with a button to forget it. Reset All forgets these too.
- Apps nobody changed are no longer routed through Volume Control during calls, which is less work for the Mac
  and fewer ways for a call's audio to go wrong.
- Fixed: an app that plays to a device of its own choosing, like a headset picked in Google Meet's or Zoom's
  settings while the Mac's sound output is set to something else, went silent on that device as soon as its audio
  ran through Volume Control (because of a custom volume, or, before this version, because a call started). Its
  audio was moved to the system output device, where you might not be listening. It now plays on the device the
  app itself plays to, including through the device macOS builds around a call's microphone and speaker. An app
  that plays to several devices at once still plays on the system output.
- A call is recognised per app rather than per process, so an app that records in one process and plays in
  another (possible in browsers) counts as the calling app and isn't routed as if it were background audio.
- Fixed: audio that couldn't be played back (for instance while a headset's layout changes as it switches to
  call mode) kept the app muted with nothing in its place, and the safety check didn't notice as long as the
  audio engine kept running. Only audio actually played now counts as working, so the app is unmuted and its
  audio path rebuilt within seconds. The captured audio is also found anew each cycle, even if the device
  gains a microphone.
- Missed notifications of a device's format changing (seen around sleep) are caught by the regular check and on
  waking, instead of leaving a tap built for the old format.
- Losing the System Audio Recording permission in any way, not only through "Don't Allow", stops all taps.
- An app that stays quiet while one of its processes starts or quits keeps its audio path, so it doesn't start
  at full volume when it resumes.
- The log names the apps in a call, the device each tap plays to, and a tap that captures nothing but silence
  for a minute while its app plays, to make reports like "suddenly heard nothing" traceable.

## 0.5.2 — 2026-09-21

- Fixed: after pausing for more than 15 seconds, a resumed video played at the wrong volume until the next
  15-second check. macOS 27 doesn't announce that a process started or stopped playing under the property the
  app listened to; it announces it as "is running" and as a change of the process's device list. The app listens
  to those now, so a saved volume applies the moment playback starts. The 15-second check stays as a backstop.

## 0.5.1 — 2026-09-20

- FaceTime is no longer pinned to the top of the list. It's sorted by name like every other app, and is still
  always listed, so the call volume can be set before a call.

## 0.5 — 2026-09-20

- A long app list folds up. FaceTime, apps that are playing or played in the last five minutes, and apps with a
  custom volume are always shown; once there are more than four rows, the rest go under **Show N more apps**,
  with their names underneath. While the panel is open, rows on screen keep their place, so an app doesn't jump
  to another section while you drag its slider. The list is folded again each time the panel opens.
- The panel takes its new size in the same screen refresh as its content when you fold the list or flip the
  on/off switch. It used to follow a frame later, which showed as a flicker.
- Fixed: an app could play for minutes without being noticed (not shown as playing, slider without effect),
  because Core Audio's "started playing" notification doesn't always arrive, seen after waking from sleep. While
  on, the app now also re-reads who's playing every 15 s, and whenever the panel opens or it's switched on.
  Listeners are also re-added when Core Audio reuses a process object's ID for a different process.

## 0.4.2 — 2026-09-20

- The menu bar icon stays highlighted while the panel is open. On macOS 27 the menu bar draws status items
  itself, where nothing the app sets on the icon reaches the screen, so the panel is now handed to the menu bar
  as an `NSStatusItemExpandedInterfaceSession`, the way the system's own menu bar panels work: the menu bar
  highlights the icon, closes the panel on the next click, and includes it in menu bar keyboard navigation.
  Earlier versions of macOS keep the previous behaviour.

## 0.4.1 — 2026-09-20

- Clicking the menu bar icon while the panel is open closes it. The click used to close the panel and
  immediately reopen it.

## 0.4 — 2026-09-19

- **Reset All** button: every app back to 100% and unmuted.
- While routing audio, the permission is re-checked every 30 s instead of every 5 s. Opening the panel still
  checks right away.
- Right after waking from sleep, audio that hasn't resumed yet is no longer mistaken for a stall, which rebuilt
  the audio path and could cause a blip. The app also re-syncs which apps are playing on wake.

## 0.3.1 — 2026-09-19

- After an update, the audio permission is requested at launch, and the permission banner's button shows the
  macOS prompt ("Allow…") instead of sending you to System Settings, which can still show the previous version
  as allowed.

## 0.3 — 2026-09-19

- Audio from helper processes that macOS doesn't attribute to their app is matched to the app by its bundle ID
  ("Google Chrome Helper" → Chrome, WhatsApp's call extension → WhatsApp), so those apps get their own slider
  and aren't left quieter than Safari during calls.

## 0.2 — 2026-09-19

- Shipped as a disk image instead of a zip, so an update replaces the old copy instead of landing next to it.
- Quits any other running copy, and offers to move older copies to the Trash after an update.
- Remembers "Open at Login" across updates.
- Lighter on battery: the safety check runs every 5 s instead of every 2 s, and audio is released 15 s after an
  app goes quiet instead of 30 s.

## 0.1 — 2026-09-19

- First stable version: a volume slider per app, FaceTime pinned at the top, volumes remembered per app, an
  on/off switch, and playback exempt from the volume lowering macOS applies during calls.
