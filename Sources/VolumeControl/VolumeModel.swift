import AppKit
import CoreAudio
import ServiceManagement
import os

let log = Logger(subsystem: "dev.alper.VolumeControl", category: "audio")

/// Saved per-app volume. Only apps with something changed are stored.
struct AppSetting: Codable, Equatable {
    var name: String
    var volume: Double = 1
    var muted = false
    /// The volume during calls, set by dragging the slider during one and applied to every call after. Without it,
    /// calls use the normal volume if that was changed, and otherwise leave the app to macOS, which may lower it.
    var callVolume: Double?
    var callMuted = false

    init(name: String) { self.name = name }

    init(from decoder: Decoder) throws {  // Settings saved before call volumes existed lack those keys.
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        volume = try container.decodeIfPresent(Double.self, forKey: .volume) ?? 1
        muted = try container.decodeIfPresent(Bool.self, forKey: .muted) ?? false
        callVolume = try container.decodeIfPresent(Double.self, forKey: .callVolume)
        callMuted = try container.decodeIfPresent(Bool.self, forKey: .callMuted) ?? false
    }

    var gain: Float { muted ? 0 : Float(volume) }
    var hasNormalVolume: Bool { volume != 1 || muted }
    var hasCallVolume: Bool { callVolume != nil || callMuted }
    var isDefault: Bool { !hasNormalVolume && !hasCallVolume }

    /// The volume and mute state the app has during calls.
    var callLevel: (volume: Double, muted: Bool) {
        hasCallVolume ? (callVolume ?? volume, callMuted) : (volume, muted)
    }
}

struct AppRow: Identifiable, Equatable {
    enum Status { case playing, silent, notRunning }

    let id: String
    let name: String
    let status: Status
    /// What the slider shows: the call volume during a call, the normal volume otherwise.
    let volume: Double
    let muted: Bool
    /// Whether the percentage button has something to reset (the call volume during a call).
    let canReset: Bool
    let callState: CallState
    /// Outside calls: the volume set for calls, if any ("50%", "muted").
    let savedCallVolume: String?

    enum CallState: Equatable {
        case none
        /// Playing at the volume set for calls.
        case callVolume
        /// Left to macOS, which lowers other apps during a call: to `volume` if that could be measured, otherwise
        /// by an unknown amount (and `volume` is its normal one).
        case lowered(measured: Bool)
    }
    let error: String?
    /// Worth showing straight away: FaceTime, and apps that are playing, played recently or have a custom volume.
    /// The rest are folded away under "Show N more apps" once the list gets long.
    let isProminent: Bool
}

@MainActor
final class VolumeModel: ObservableObject {
    static let maxVolume = 2.0

    @Published private(set) var rows: [AppRow] = []
    /// Tallest the app list may get before it scrolls; set from the screen's height.
    @Published var maxListHeight: CGFloat = 420
    @Published private(set) var permission = AudioCapturePermission.status
    /// Whether the apps folded away under "Show N more apps" are shown. Folded again whenever the panel closes.
    @Published var showsAllApps = false
    /// Whether an app is in a call; sliders then set the volume for calls.
    @Published private(set) var callActive = false
    /// When off, no audio is routed through the app and every app plays at its normal volume.
    @Published private(set) var isEnabled = UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true

    private struct AppGroup {
        let identity: AppIdentity
        var objectIDs: Set<AudioObjectID> = []
        var isRunningOutput = false
        var isRunningInput = false
        /// The devices its processes play to.
        var outputDevices: Set<AudioDeviceID> = []
        /// Using the microphone and the speakers at once: FaceTime, Zoom, WhatsApp, a call in the browser and the
        /// like. Counted per app, not per process: an app may record in one process and play in another.
        var isInCall: Bool { isRunningOutput && isRunningInput }
    }

    /// Up to this many rows, everything is shown; a longer list folds away the apps that aren't prominent.
    private static let unfoldedRowLimit = 4
    /// An app that went quiet stays prominent this long, so pausing a video doesn't hide its slider.
    private static let recentlyPlayedInterval: TimeInterval = 5 * 60

    private static let settingsKey = "appSettings"
    private static let enabledKey = "enabled"
    /// How long an app's audio path stays up after it goes quiet, so pausing and resuming doesn't briefly play at
    /// the wrong volume. Kept short: while it's up, the audio device keeps running and the Mac can't idle-sleep.
    private static let idleTeardownDelay: TimeInterval = 15
    private static let resetTeardownDelay: TimeInterval = 2
    /// Wait between attempts after a tap fails to start: quick at first (failures are often transient, e.g. while
    /// AirPods switch into call mode), then backing off but never giving up while the app keeps playing.
    private static let retryDelays: [TimeInterval] = [1, 3, 10, 30, 60]

    private var settings: [String: AppSetting] = [:]
    private var groups: [String: AppGroup] = [:]
    private var taps: [String: VolumeTap] = [:]
    private var errors: [String: String] = [:]
    /// Tap failures per app, so a failing setup is retried with backoff rather than in a tight loop.
    private var failures: [String: (signature: String, attempts: Int, failedAt: Date, retryAt: Date)] = [:]
    private var pendingTeardowns: [String: (item: DispatchWorkItem, deadline: DispatchTime)] = [:]
    /// Last IO-cycle count seen per tap, and since when it has been that value (for stall detection).
    private var lastIOCycles: [String: (cycles: UInt64, since: Date)] = [:]
    /// Last audible IO cycle seen per tap, since when, and whether a long silence was logged. Silence is normal
    /// (a quiet moment in a call), but a tap that captures nothing for minutes while the app plays is worth a line
    /// in the log when someone reports hearing nothing.
    private var silence: [String: (cycle: UInt64, since: Date, reported: Bool)] = [:]
    private static let silenceReportInterval: TimeInterval = 60
    private var lastPermissionCheck = Date.distantPast
    /// Measures how far macOS lowers apps during a call, while that's on screen.
    private let duckingMeter = DuckingMeter()
    private var lastPlayed: [String: Date] = [:]
    private var panelIsOpen = false

    private var systemListeners: [PropertyListener] = []
    /// Format listeners for the default output and every device a tap plays to, with the format last seen.
    private var devices: [AudioDeviceID: (signature: String, listeners: [PropertyListener])] = [:]
    /// Per process object, with the PID they were added for: Core Audio reuses object IDs, and a listener doesn't
    /// carry over to the next process that gets the same ID.
    private var processListeners: [AudioObjectID: (pid: pid_t, listeners: [PropertyListener])] = [:]
    /// What to listen to on a process to learn that it started or stopped playing or recording. macOS 27 never
    /// announces changes of IsRunningOutput and IsRunningInput themselves (seen with a listener for every property),
    /// only of IsRunning and of the device lists. The device lists also cover a process that is already playing and
    /// starts recording, i.e. a call.
    private static let playbackProperties: [(AudioObjectPropertySelector, AudioObjectPropertyScope)] = [
        (kAudioProcessPropertyIsRunning, kAudioObjectPropertyScopeGlobal),
        (kAudioProcessPropertyDevices, kAudioObjectPropertyScopeOutput),
        (kAudioProcessPropertyDevices, kAudioObjectPropertyScopeInput),
        (kAudioProcessPropertyIsRunningOutput, kAudioObjectPropertyScopeGlobal),
        (kAudioProcessPropertyIsRunningInput, kAudioObjectPropertyScopeGlobal),
    ]
    private var safetyRefreshTimer: Timer?
    /// A backstop for notifications that don't arrive (seen after waking from sleep: an app played for minutes
    /// unnoticed), so the state is also re-read this often. A handful of property reads; with the tolerance, macOS
    /// folds the wake-up into others.
    private static let safetyRefreshInterval: TimeInterval = 15
    private var lastCallSeen = Date.distantPast
    private var callEndCheckScheduled = false
    private static let callEndDelay: TimeInterval = 3
    /// The default output device.
    private var outputDevice = AudioDeviceID.unknown
    private var refreshScheduled = false
    private var hasRequestedPermission = false
    private var watchdogTimer: Timer?
    /// A tap counts as stalled only after this long without progress.
    private static let stallTimeout: TimeInterval = 4
    /// Asking macOS's privacy service is an IPC round trip, so the watchdog only does it this often (opening the
    /// panel checks too).
    private static let permissionCheckInterval: TimeInterval = 30

    init() {
        loadSettings()
        duckingMeter.onChange = { [weak self] in self?.rebuildRows() }
        systemListeners = [
            AudioObjectID.system.addListener(kAudioHardwarePropertyProcessObjectList) { [weak self] in
                MainActor.assumeIsolated { self?.scheduleRefresh() }
            },
            AudioObjectID.system.addListener(kAudioHardwarePropertyDefaultOutputDevice) { [weak self] in
                MainActor.assumeIsolated { self?.outputDeviceChanged() }
            },
            AudioObjectID.system.addListener(kAudioHardwarePropertyServiceRestarted) { [weak self] in
                MainActor.assumeIsolated { self?.audioServiceRestarted() }
            },
        ].compactMap { $0 }
        outputDeviceChanged()
        updateSafetyRefresh()
        // Each new build is a new app to macOS, so after an update it asks again. Ask now rather than when a saved
        // volume is first needed (System Settings may still show the old build's permission as on).
        if isEnabled && !settings.isEmpty && permission == .unknown {
            requestPermissionIfNeeded()
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopAll() }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            // Progress readings from before sleep mustn't count: audio takes a moment to resume after waking.
            MainActor.assumeIsolated { self?.lastIOCycles.removeAll() }
        }
        workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.didWake() }
        }
    }

    /// Re-syncs after sleep without rebuilding anything (a rebuild could itself cause a blip): device changes still
    /// arrive through the device listeners, and a real stall is caught by the checks scheduled here.
    private func didWake() {
        log.notice("Woke from sleep")
        lastIOCycles.removeAll()
        recheckDeviceFormats()
        scheduleRefresh()  // In case a process started or stopped playing without every notification arriving.
        guard !taps.isEmpty else { return }
        // A baseline reading now, and a verdict once a stall could count, instead of waiting for the regular timer.
        for delay in [1, 1 + Self.stallTimeout + 0.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                MainActor.assumeIsolated { self?.checkTaps() }
            }
        }
    }

    /// True when some app has a custom volume that can't be applied for lack of permission.
    var needsPermission: Bool {
        isEnabled && permission != .authorized && !settings.isEmpty
    }

    // MARK: - User actions

    /// During a call this sets the app's volume for calls, which every later call uses too; the normal volume stays.
    func setVolume(_ volume: Double, for row: AppRow) {
        if callActive {
            // Back where it would be without a volume for calls (the level macOS lowers it to, or its normal
            // volume): forget the volume for calls rather than keep a copy of that.
            let without = levelWithoutCallVolume(row.id)
            if !without.muted, abs(volume - without.volume) < 0.03 { return forgetCallVolume(row) }
        }
        // Snap to 100% so it's easy to get back to "unchanged".
        let volume = abs(volume - 1) < 0.03 ? 1 : min(max(volume, 0), Self.maxVolume)
        if callActive {
            update(row) { $0.callVolume = volume; if volume > 0 { $0.callMuted = false } }
        } else {
            update(row) { $0.volume = volume; if volume > 0 { $0.muted = false } }
        }
    }

    func toggleMute(_ row: AppRow) {
        if callActive {
            update(row) { setting in
                let level = setting.callLevel
                if level.muted || level.volume == 0 {
                    // Back to the volume for calls, or to what applies without one; only if that's silent too
                    // (normally muted, say), a volume for calls at the normal volume (100% if that's 0).
                    setting.callMuted = false
                    if setting.callVolume == 0 { setting.callVolume = nil }
                    let unmuted = setting.callLevel
                    if unmuted.muted || unmuted.volume == 0 { setting.callVolume = setting.volume > 0 ? setting.volume : 1 }
                } else {
                    setting.callMuted = true
                }
            }
        } else {
            update(row) { setting in
                if setting.muted || setting.volume == 0 {
                    setting.muted = false
                    if setting.volume == 0 { setting.volume = 1 }
                } else {
                    setting.muted = true
                }
            }
        }
    }

    /// Puts every app back at 100% and unmuted, forgetting all saved volumes.
    func resetAll() {
        guard !settings.isEmpty else { return }
        settings.removeAll()
        saveSettings()
        failures.removeAll()
        errors.removeAll()
        log.notice("Reset all volumes to 100%")
        reconcileAll()
    }

    /// During a call, forgets the app's volume for calls; otherwise sets its normal volume back to 100%.
    func reset(_ row: AppRow) {
        if callActive { forgetCallVolume(row) } else { update(row) { $0.volume = 1; $0.muted = false } }
    }

    func forgetCallVolume(_ row: AppRow) {
        update(row) { $0.callVolume = nil; $0.callMuted = false }
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
        log.notice("Volume control \(enabled ? "enabled" : "disabled", privacy: .public)")
        failures.removeAll()
        errors.removeAll()
        if !enabled { stopAll() }
        updateSafetyRefresh()
        refresh()
    }

    /// Only while on: turned off, nothing depends on knowing who's playing until the panel opens, which re-reads too.
    private func updateSafetyRefresh() {
        safetyRefreshTimer?.invalidate()
        safetyRefreshTimer = nil
        guard isEnabled else { return }
        let timer = Timer(timeInterval: Self.safetyRefreshInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.recheckDeviceFormats()
                self?.refresh()
            }
        }
        timer.tolerance = Self.safetyRefreshInterval / 3
        RunLoop.main.add(timer, forMode: .common)
        safetyRefreshTimer = timer
    }

    func refreshPermission() {
        let status = AudioCapturePermission.status
        guard status != permission else { return }
        permission = status
        failures.removeAll()
        reconcileAll()
    }

    /// Shows the system permission prompt, at most once per launch.
    private func requestPermissionIfNeeded() {
        guard permission != .authorized, !hasRequestedPermission else { return }
        requestPermission()
    }

    /// Shows the system permission prompt (when macOS hasn't decided yet; after a "Don't Allow" it answers straight
    /// away and only System Settings can change it).
    func requestPermission() {
        hasRequestedPermission = true
        AudioCapturePermission.request { [weak self] granted in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.permission = granted ? .authorized : AudioCapturePermission.status
                log.notice("Audio capture permission granted: \(granted)")
                self.failures.removeAll()
                self.reconcileAll()
            }
        }
    }

    private static let launchAtLoginKey = "launchAtLogin"

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.launchAtLoginKey)
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                log.error("Couldn't change login item: \(error)")
            }
            objectWillChange.send()
        }
    }

    /// The login item belongs to one copy of the app, so re-register after an update replaced or moved it.
    func restoreLaunchAtLogin() {
        guard UserDefaults.standard.bool(forKey: Self.launchAtLoginKey), SMAppService.mainApp.status != .enabled else { return }
        do {
            try SMAppService.mainApp.register()
            log.notice("Re-registered as login item")
        } catch {
            log.error("Couldn't re-register login item: \(error)")
        }
    }

    private func update(_ row: AppRow, _ change: (inout AppSetting) -> Void) {
        var setting = settings[row.id] ?? AppSetting(name: row.name)
        change(&setting)
        if callActive, setting.hasCallVolume {
            let level = setting.callLevel, without = levelWithoutCallVolume(row.id)
            if level.muted == without.muted, level.muted || abs(level.volume - without.volume) < 0.001 {
                setting.callVolume = nil
                setting.callMuted = false
            }
        }
        settings[row.id] = setting.isDefault ? nil : setting
        saveSettings()
        // Touching the slider retries a tap that failed (at most once a second while dragging).
        if let failure = failures[row.id], Date().timeIntervalSince(failure.failedAt) > 1 {
            failures[row.id] = nil
        }

        if !setting.isDefault && isEnabled {
            requestPermissionIfNeeded()
        }
        reconcile(row.id)
        rebuildRows()
    }

    // MARK: - Core Audio state

    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.refreshScheduled = false
                self?.refresh()
            }
        }
    }

    private func refresh() {
        let processes = AudioProcess.all(excluding: duckingMeter.helperPID.map { [$0] } ?? [])

        let current = Dictionary(processes.map { ($0.objectID, $0.pid) }, uniquingKeysWith: { first, _ in first })
        for (id, entry) in processListeners where current[id] != entry.pid {
            entry.listeners.forEach { $0.remove() }
            processListeners[id] = nil
        }
        for (id, pid) in current where processListeners[id] == nil {
            let listeners = Self.playbackProperties.compactMap { selector, scope in
                id.addListener(selector, scope: scope) { [weak self] in
                    MainActor.assumeIsolated { self?.scheduleRefresh() }
                }
            }
            processListeners[id] = (pid, listeners)
        }

        var groups: [String: AppGroup] = [:]
        for process in processes {
            let identity = AppIdentity.of(process)
            var group = groups[identity.key] ?? AppGroup(identity: identity)
            group.objectIDs.insert(process.objectID)
            group.isRunningOutput = group.isRunningOutput || process.isRunningOutput
            group.isRunningInput = group.isRunningInput || process.isRunningInput
            group.outputDevices.formUnion(process.outputDevices)
            groups[identity.key] = group
        }
        self.groups = groups
        // A calling app can stop its speaker or microphone for a moment (muting in the call, say); the call lasts
        // until it has been over for a few seconds, so volumes don't swap back and forth.
        let now = Date()
        if groups.values.contains(where: \.isInCall) { lastCallSeen = now }
        let callActive = now.timeIntervalSince(lastCallSeen) < Self.callEndDelay
        if callActive && !groups.values.contains(where: \.isInCall) && !callEndCheckScheduled {
            callEndCheckScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.callEndDelay + 0.1) { [weak self] in
                MainActor.assumeIsolated {
                    self?.callEndCheckScheduled = false
                    self?.refresh()
                }
            }
        }
        if callActive != self.callActive {
            self.callActive = callActive
            if !callActive { duckingMeter.forgetLevels() }
            let callers = groups.values.filter(\.isInCall).map(\.identity.key).sorted()
            log.notice("Call \(callActive ? "started" : "ended", privacy: .public) \(callers, privacy: .public)")
        }

        reconcileAll()
    }

    private func outputDeviceChanged() {
        outputDevice = (try? AudioObjectID.defaultOutputDevice()) ?? .unknown
        let signature = watchedSignature(of: outputDevice)
        log.notice("Output device is now \(self.outputDevice) (\(signature, privacy: .public))")
        refresh()
    }

    /// The device's format: as last seen by its listeners if it's followed, otherwise read now.
    private func signature(of device: AudioDeviceID) -> String {
        devices[device]?.signature ?? (device.isValid ? device.formatSignature() : "")
    }

    /// The device's format, following its changes from now on (until `forgetUnusedDevices`).
    private func watchedSignature(of device: AudioDeviceID) -> String {
        if let known = devices[device] { return known.signature }
        guard device.isValid else { return "" }

        // Sample-rate or channel changes (e.g. AirPods switching to call mode) invalidate our aggregate devices.
        let bump = { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.recheckFormat(of: device) else { return }
                self.scheduleRefresh()
            }
        }
        let listeners = [
            device.addListener(kAudioDevicePropertyNominalSampleRate, bump),
            device.addListener(kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeOutput, bump),
            device.addListener(kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeInput, bump),
            device.addListener(kAudioDevicePropertyDeviceIsAlive, bump),
        ].compactMap { $0 }
        let signature = device.formatSignature()
        devices[device] = (signature, listeners)
        return signature
    }

    /// Only real changes count, so notifications caused by our own aggregate devices can't trigger rebuild loops.
    /// Returns whether the format changed.
    private func recheckFormat(of device: AudioDeviceID) -> Bool {
        guard let known = devices[device] else { return false }
        let signature = device.formatSignature()
        guard signature != known.signature else { return false }
        devices[device]?.signature = signature
        log.notice("Format of device \(device) changed (\(signature, privacy: .public))")
        return true
    }

    /// For format changes whose notification didn't arrive (as some don't around sleep); the refresh that follows
    /// rebuilds what they affect.
    private func recheckDeviceFormats() {
        for device in devices.keys { _ = recheckFormat(of: device) }
    }

    /// Stops following devices that neither are the default output nor have a tap playing to them.
    private func forgetUnusedDevices() {
        let inUse = Set(taps.values.map(\.outputDevice)).union([outputDevice])
        for (device, entry) in devices where !inUse.contains(device) {
            entry.listeners.forEach { $0.remove() }
            devices[device] = nil
        }
    }

    /// Where the app's audio is played back while it runs through us: the device the app plays to itself, which
    /// isn't always the default output (Google Meet, Zoom and many other apps let you pick a speaker). A tap mutes
    /// the app everywhere, so playing it anywhere else would take it away from, say, the headset the call is on. A
    /// tap can only play to one device, so when the app plays to several (or it can't be told yet), the default.
    private func tapDevice(for key: String, _ group: AppGroup) -> AudioDeviceID {
        let devices = Set(group.outputDevices.flatMap { $0.playbackDevices() })
        // Stay put while the current device is still one of them, so a second stream (a notification sound on
        // another device, say) doesn't move the tap back and forth.
        if let current = taps[key]?.outputDevice, devices.contains(current) { return current }
        return devices.count == 1 ? devices.first! : outputDevice
    }

    /// How macOS lowers the app during this call if it has no volume for calls: not at all (no call, the calling app,
    /// not playing, or it has a custom normal volume, which we keep playing), or to the measured level, which is only
    /// known for apps playing to the default output, where the meter runs (nil elsewhere, or not measured yet).
    private enum Lowering { case none, lowered(Double?) }

    private func lowering(_ key: String) -> Lowering {
        guard callActive, let group = groups[key], group.isRunningOutput, !group.isInCall,
              settings[key]?.hasNormalVolume != true else { return .none }
        let devices = Set(group.outputDevices.flatMap { $0.playbackDevices() })
        let onDefaultOutput = devices.isEmpty || devices == [outputDevice]
        return .lowered(onDefaultOutput ? duckingMeter.level.map { ($0 * 100).rounded() / 100 } : nil)
    }

    /// What the app's row shows during this call without a volume for calls.
    private func levelWithoutCallVolume(_ key: String) -> (volume: Double, muted: Bool) {
        if case .lowered(let level) = lowering(key) { return (level ?? 1, false) }
        return (settings[key]?.volume ?? 1, settings[key]?.muted ?? false)
    }

    /// The gain the user chose for the app right now, or nil if it's left alone.
    ///
    /// During calls, calling apps make macOS turn other audio down ("ducking", up to 15 dB). An app nobody changed
    /// is left to that. One with a volume for calls, or a custom normal volume, plays at exactly that through us,
    /// which macOS doesn't duck. The calling app itself isn't ducked, so at 100% it needs nothing.
    private func chosenGain(_ key: String, _ group: AppGroup) -> Float? {
        guard let setting = settings[key] else { return nil }
        if callActive {
            let level = setting.callLevel
            let gain: Float = level.muted ? 0 : Float(level.volume)
            if setting.hasCallVolume { return group.isInCall && gain == 1 ? nil : gain }
        }
        return setting.hasNormalVolume ? setting.gain : nil
    }

    /// Whether the app's audio should run through us right now.
    private func needsTap(_ key: String, _ group: AppGroup) -> Bool {
        group.isRunningOutput && chosenGain(key, group) != nil
    }

    private func reconcileAll() {
        for key in Set(groups.keys).union(taps.keys) {
            reconcile(key)
        }
        forgetUnusedDevices()
        updateDuckingMeter()
        rebuildRows()
    }

    /// The level macOS lowers apps to is only measured while it's on screen: during a call, with the panel open.
    private func updateDuckingMeter() {
        let wanted = isEnabled && callActive && panelIsOpen && permission == .authorized
        duckingMeter.measure(on: wanted ? outputDevice : nil)
    }

    /// Creates, updates or removes the tap for one app so it matches the app's setting and playback state.
    private func reconcile(_ key: String) {
        guard isEnabled, let group = groups[key], outputDevice.isValid else {
            errors[key] = nil
            teardown(key)
            return
        }

        let chosen = chosenGain(key, group)
        if group.isRunningOutput, let gain = chosen {
            cancelTeardown(key)
            if permission != .authorized {
                // Never tap without permission: the app would be muted and we'd only receive silence.
                permission = AudioCapturePermission.status
                guard permission == .authorized else {
                    teardown(key)
                    requestPermissionIfNeeded()
                    return
                }
            }
            ensureTap(for: key, group: group, device: tapDevice(for: key, group), gain: gain)
        } else {
            errors[key] = nil
            guard let tap = taps[key] else { return }
            // Keep the tap around for a bit so pausing and resuming doesn't briefly play at full volume.
            if tap.processObjectIDs != group.objectIDs {
                // A process joined or left while the app is quiet; keep the tap for its resume if that's possible.
                try? tap.updateProcesses(group.objectIDs)
            }
            if tap.deviceSignature != signature(of: tap.outputDevice) || tap.processObjectIDs != group.objectIDs {
                teardown(key)
            } else {
                if chosen == nil && callActive && !group.isInCall {
                    // Handed back to macOS during a call: it's lowered as soon as it's no longer played by us
                    // (exempt from that), where a grace period would play it at full volume meanwhile.
                    teardown(key)
                    return
                }
                tap.gain = chosen ?? 1
                // Slow when the app has only gone quiet; quick when the tap isn't wanted at all any more.
                scheduleTeardown(key, after: chosen != nil ? Self.idleTeardownDelay : Self.resetTeardownDelay)
            }
        }
    }

    private func signature(of group: AppGroup, on device: AudioDeviceID) -> String {
        "\(group.objectIDs.sorted())/\(device)/\(signature(of: device))"
    }

    private func ensureTap(for key: String, group: AppGroup, device: AudioDeviceID, gain: Float) {
        if let tap = taps[key], tap.outputDevice == device, tap.deviceSignature == signature(of: device) {
            if tap.processObjectIDs != group.objectIDs {
                do {
                    try tap.updateProcesses(group.objectIDs)
                    log.notice("Updated tap for \(key, privacy: .public) (processes \(group.objectIDs.sorted(), privacy: .public))")
                } catch {
                    log.error("Couldn't update tap for \(key, privacy: .public), rebuilding: \(error, privacy: .public)")
                }
            }
            if tap.processObjectIDs == group.objectIDs {
                tap.gain = gain
                return
            }
        }

        let signature = signature(of: group, on: device)
        if let failure = failures[key], failure.signature == signature, Date() < failure.retryAt {
            teardown(key)
            return
        }

        // Build the new tap before removing the old one, so the app isn't briefly heard at full volume.
        let deviceSignature = watchedSignature(of: device)
        let previous = taps.removeValue(forKey: key)
        lastIOCycles[key] = nil
        silence[key] = nil
        do {
            taps[key] = try VolumeTap(processObjectIDs: group.objectIDs, outputDevice: device,
                                      deviceSignature: deviceSignature, gain: gain)
            errors[key] = nil
            failures[key] = nil
            log.notice("Started tap for \(key, privacy: .public) (processes \(group.objectIDs.sorted(), privacy: .public), device \(device)\(device == self.outputDevice ? " (default)" : "", privacy: .public), gain \(gain))")
        } catch {
            recordFailure(for: key, signature: signature, message: "\(error)")
        }
        previous?.invalidate()
        updateWatchdog()
    }

    /// Shows the error on the app's row and schedules a retry with backoff.
    private func recordFailure(for key: String, signature: String, message: String) {
        let attempts = (failures[key]?.signature == signature ? failures[key]!.attempts : 0) + 1
        let delay = Self.retryDelays[min(attempts, Self.retryDelays.count) - 1]
        failures[key] = (signature, attempts, Date(), Date().addingTimeInterval(delay))
        errors[key] = message
        log.error("Tap for \(key, privacy: .public) failed (attempt \(attempts), retrying in \(delay)s): \(message, privacy: .public)")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay + 0.2) { [weak self] in
            MainActor.assumeIsolated {
                self?.reconcile(key)
                self?.rebuildRows()
            }
        }
    }

    private func teardown(_ key: String) {
        cancelTeardown(key)
        lastIOCycles[key] = nil
        silence[key] = nil
        guard let tap = taps.removeValue(forKey: key) else { return }
        tap.invalidate()
        log.notice("Stopped tap for \(key, privacy: .public)")
        updateWatchdog()
    }

    private func scheduleTeardown(_ key: String, after delay: TimeInterval) {
        let deadline = DispatchTime.now() + delay
        if let pending = pendingTeardowns[key] {
            guard deadline < pending.deadline else { return }
            pending.item.cancel()
        }
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pendingTeardowns[key] = nil
                let stillNeeded = self.isEnabled && self.groups[key].map { self.needsTap(key, $0) } == true
                if !stillNeeded { self.teardown(key) }
            }
        }
        pendingTeardowns[key] = (item, deadline)
        DispatchQueue.main.asyncAfter(deadline: deadline, execute: item)
    }

    private func cancelTeardown(_ key: String) {
        pendingTeardowns.removeValue(forKey: key)?.item.cancel()
    }

    private func stopAll() {
        for key in taps.keys { teardown(key) }
    }

    /// After coreaudiod restarts, every device, process and tap ID we hold is dead (and may be reused).
    private func audioServiceRestarted() {
        log.notice("Core Audio restarted; rebuilding")
        for tap in taps.values { tap.abandon() }
        taps.removeAll()
        lastIOCycles.removeAll()
        silence.removeAll()
        pendingTeardowns.values.forEach { $0.item.cancel() }
        pendingTeardowns.removeAll()
        processListeners.values.forEach { $0.listeners.forEach { $0.remove() } }
        processListeners.removeAll()
        devices.values.forEach { $0.listeners.forEach { $0.remove() } }
        devices.removeAll()
        failures.removeAll()
        errors.removeAll()
        updateWatchdog()
        outputDeviceChanged()
    }

    /// While taps run, checks every 5 seconds that audio is still flowing (and every 30 that permission wasn't
    /// revoked), since either would leave the app muted with nothing playing in its place.
    private func updateWatchdog() {
        if taps.isEmpty {
            watchdogTimer?.invalidate()
            watchdogTimer = nil
        } else if watchdogTimer == nil {
            let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkTaps() }
            }
            timer.tolerance = 1  // Lets macOS batch this wake-up with others.
            RunLoop.main.add(timer, forMode: .common)
            watchdogTimer = timer
        }
    }

    private func checkTaps() {
        let now = Date()
        if now.timeIntervalSince(lastPermissionCheck) >= Self.permissionCheckInterval {
            lastPermissionCheck = now
            let status = AudioCapturePermission.status
            if status != .authorized {
                // Without it, taps only receive silence while the apps stay muted.
                log.error("System Audio Recording permission was revoked; stopping all taps")
                permission = status
                stopAll()
                updateDuckingMeter()
                rebuildRows()
                return
            }
        }
        for (key, tap) in taps {
            let cycles = tap.ioCycles
            log.debug("\(key, privacy: .public): \(cycles) IO cycles, input peak \(tap.inputPeak), gain \(tap.gain)")
            let audible = tap.lastAudibleCycle
            if let entry = silence[key], entry.cycle == audible {
                if !entry.reported, now.timeIntervalSince(entry.since) >= Self.silenceReportInterval,
                   groups[key]?.isRunningOutput == true {
                    silence[key]?.reported = true
                    log.notice("Tap for \(key, privacy: .public) has captured only silence for \(Int(now.timeIntervalSince(entry.since)))s while the app plays (\(cycles) IO cycles)")
                }
            } else {
                if silence[key]?.reported == true { log.notice("Tap for \(key, privacy: .public) captures audio again") }
                silence[key] = (audible, now, false)
            }
            guard let last = lastIOCycles[key], last.cycles == cycles else {
                lastIOCycles[key] = (cycles, now)
                continue
            }
            // Two checks close together (e.g. just after waking) can see no progress without anything being wrong.
            guard now.timeIntervalSince(last.since) >= Self.stallTimeout else { continue }
            teardown(key)
            if let group = groups[key] {
                recordFailure(for: key, signature: signature(of: group, on: tap.outputDevice), message: "Audio stopped flowing")
            }
        }
        rebuildRows()
    }

    // MARK: - Rows

    /// The apps folded away under "Show N more apps".
    var otherRows: [AppRow] { rows.filter { !$0.isProminent } }

    /// Folding one app away saves no room, and a short list doesn't need it.
    var foldsOtherRows: Bool { rows.count > Self.unfoldedRowLimit && otherRows.count > 1 }

    var visibleRows: [AppRow] { foldsOtherRows && !showsAllApps ? rows.filter(\.isProminent) : rows }

    /// The list is only rearranged while the panel is closed (see `rebuildRows`), and opens folded.
    func setPanelOpen(_ open: Bool) {
        panelIsOpen = false
        if open {
            refresh()  // Never show a stale picture of who's playing.
        } else {
            showsAllApps = false
            rebuildRows()
        }
        panelIsOpen = open
        updateDuckingMeter()
    }

    var hasSettings: Bool { !settings.isEmpty }

    private func rebuildRows() {
        var keys = Set(groups.filter { $0.value.isRunningOutput || $0.value.identity.isApp }.keys)
        keys.formUnion(settings.keys)
        keys.insert(AppIdentity.faceTimeKey)

        let now = Date()
        for (key, group) in groups where group.isRunningOutput { lastPlayed[key] = now }
        let wasProminent = Dictionary(uniqueKeysWithValues: self.rows.map { ($0.id, $0.isProminent) })
        let wasVisible = Set(visibleRows.map(\.id))

        let rows = keys.map { key -> AppRow in
            let group = groups[key]
            let setting = settings[key]  // Only custom volumes are stored.
            let status: AppRow.Status = group == nil ? .notRunning : group!.isRunningOutput ? .playing : .silent
            let playedRecently = lastPlayed[key].map { now.timeIntervalSince($0) < Self.recentlyPlayedInterval } ?? false
            var isProminent = key == AppIdentity.faceTimeKey || setting != nil || playedRecently || errors[key] != nil
            // While the panel is open, a row that's on screen stays in its section, so it can't jump away from under
            // the pointer (say, a folded-out app whose slider leaves 100%). A hidden row can still come forward.
            if panelIsOpen, let was = wasProminent[key], was || wasVisible.contains(key) { isProminent = was }

            let hasNormalVolume = setting?.hasNormalVolume == true
            let hasCallVolume = setting?.hasCallVolume == true
            var volume = setting?.volume ?? 1
            var muted = setting?.muted ?? false
            var callState = AppRow.CallState.none
            if callActive, let setting, hasCallVolume {
                (volume, muted) = setting.callLevel
                callState = .callVolume
            } else if case .lowered(let level) = lowering(key) {
                if let level { volume = level }
                // Measured as (next to) not lowered: nothing to point out.
                if (level ?? 0) < 0.99 { callState = .lowered(measured: level != nil) }
            }
            let savedCallVolume = callActive || !hasCallVolume ? nil
                : setting!.callMuted ? "muted" : "\(Int(((setting!.callVolume ?? 1) * 100).rounded()))%"

            return AppRow(id: key,
                          name: group?.identity.name ?? setting?.name ?? (key == AppIdentity.faceTimeKey ? "FaceTime" : key),
                          status: status,
                          volume: volume,
                          muted: muted,
                          canReset: callActive ? hasCallVolume : hasNormalVolume,
                          callState: callState,
                          savedCallVolume: savedCallVolume,
                          error: errors[key],
                          isProminent: isProminent)
        }
        .sorted { a, b in
            // Playing and silent apps share a rank so rows don't jump around while you drag a slider.
            func rank(_ row: AppRow) -> Int {
                (row.isProminent ? 0 : 10) + (row.status == .notRunning ? 1 : 0)
            }
            return (rank(a), a.name.localizedLowercase) < (rank(b), b.name.localizedLowercase)
        }
        if rows != self.rows { self.rows = rows }
    }

    // MARK: - Persistence

    private func loadSettings() {
        guard let data = UserDefaults.standard.data(forKey: Self.settingsKey),
              let settings = try? JSONDecoder().decode([String: AppSetting].self, from: data) else { return }
        self.settings = settings
    }

    private func saveSettings() {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: Self.settingsKey)
        }
    }
}
