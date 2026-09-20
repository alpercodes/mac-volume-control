# Changelog

Newest first. Every version's disk image is on the
[releases page](https://github.com/alpercodes/mac-volume-control/releases).

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
