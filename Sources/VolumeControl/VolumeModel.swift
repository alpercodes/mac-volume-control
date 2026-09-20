import AppKit
import CoreAudio
import ServiceManagement
import os

let log = Logger(subsystem: "dev.alper.VolumeControl", category: "audio")

/// Saved per-app volume. Only apps whose volume differs from 100% (or are muted) are stored.
struct AppSetting: Codable, Equatable {
    var name: String
    var volume: Double = 1
    var muted = false

    var gain: Float { muted ? 0 : Float(volume) }
    var isDefault: Bool { volume == 1 && !muted }
}

struct AppRow: Identifiable, Equatable {
    enum Status { case playing, silent, notRunning }

    let id: String
    let name: String
    let status: Status
    let volume: Double
    let muted: Bool
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
    /// When off, no audio is routed through the app and every app plays at its normal volume.
    @Published private(set) var isEnabled = UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true

    private struct AppGroup {
        let identity: AppIdentity
        var objectIDs: Set<AudioObjectID> = []
        var isRunningOutput = false
        /// A process using the microphone and the speakers at once: FaceTime, Zoom, WhatsApp and the like.
        var isInCall = false
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
    private var lastPermissionCheck = Date.distantPast
    private var lastPlayed: [String: Date] = [:]
    private var panelIsOpen = false

    private var systemListeners: [PropertyListener] = []
    private var deviceListeners: [PropertyListener] = []
    /// Per process object, with the PID they were added for: Core Audio reuses object IDs, and a listener doesn't
    /// carry over to the next process that gets the same ID.
    private var processListeners: [AudioObjectID: (pid: pid_t, listeners: [PropertyListener])] = [:]
    private var safetyRefreshTimer: Timer?
    /// Core Audio's "started playing" notifications don't always arrive (seen after waking from sleep: an app played
    /// for minutes unnoticed), so the state is also re-read this often. A handful of property reads; with the
    /// tolerance, macOS folds the wake-up into others.
    private static let safetyRefreshInterval: TimeInterval = 15
    private var callActive = false
    private var outputDevice = AudioDeviceID.unknown
    private var outputDeviceSignature = ""
    private var deviceGeneration = 0
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
        isEnabled && permission != .authorized && (!settings.isEmpty || callActive)
    }

    // MARK: - User actions

    func setVolume(_ volume: Double, for row: AppRow) {
        // Snap to 100% so it's easy to get back to "unchanged".
        let volume = abs(volume - 1) < 0.03 ? 1 : min(max(volume, 0), Self.maxVolume)
        update(row) { $0.volume = volume; if volume > 0 { $0.muted = false } }
    }

    func toggleMute(_ row: AppRow) {
        update(row) { setting in
            if setting.muted || setting.volume == 0 {
                setting.muted = false
                if setting.volume == 0 { setting.volume = 1 }
            } else {
                setting.muted = true
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

    func reset(_ row: AppRow) {
        update(row) { $0.volume = 1; $0.muted = false }
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
            MainActor.assumeIsolated { self?.refresh() }
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
        settings[row.id] = setting.isDefault ? nil : setting
        saveSettings()
        // Touching the slider retries a tap that failed (at most once a second while dragging).
        if let failure = failures[row.id], Date().timeIntervalSince(failure.failedAt) > 1 {
            failures[row.id] = nil
        }

        if !setting.isDefault && isEnabled {
            requestPermissionIfNeeded()
        }
        taps[row.id]?.gain = setting.gain
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
        let processes = AudioProcess.all()

        let current = Dictionary(processes.map { ($0.objectID, $0.pid) }, uniquingKeysWith: { first, _ in first })
        for (id, entry) in processListeners where current[id] != entry.pid {
            entry.listeners.forEach { $0.remove() }
            processListeners[id] = nil
        }
        for (id, pid) in current where processListeners[id] == nil {
            let listeners = [kAudioProcessPropertyIsRunningOutput, kAudioProcessPropertyIsRunningInput].compactMap {
                id.addListener($0) { [weak self] in
                    MainActor.assumeIsolated { self?.scheduleRefresh() }
                }
            }
            processListeners[id] = (pid, listeners)
        }

        var groups: [String: AppGroup] = [:]
        for process in processes {
            let identity = AppIdentity.of(process)
            groups[identity.key, default: AppGroup(identity: identity)].objectIDs.insert(process.objectID)
            if process.isRunningOutput { groups[identity.key]?.isRunningOutput = true }
            if process.isRunningOutput && process.isRunningInput { groups[identity.key]?.isInCall = true }
        }
        self.groups = groups
        let callActive = groups.values.contains { $0.isInCall }
        if callActive != self.callActive {
            self.callActive = callActive
            log.notice("Call \(callActive ? "started" : "ended", privacy: .public)")
        }

        reconcileAll()
    }

    private func outputDeviceChanged() {
        deviceListeners.forEach { $0.remove() }
        outputDevice = (try? AudioObjectID.defaultOutputDevice()) ?? .unknown
        outputDeviceSignature = outputDevice.formatSignature()
        deviceGeneration += 1
        log.notice("Output device is now \(self.outputDevice) (\(self.outputDeviceSignature, privacy: .public))")

        // Sample-rate or channel changes (e.g. AirPods switching to call mode) invalidate our aggregate devices.
        // Only real changes count, so notifications caused by our own aggregate devices can't trigger rebuild loops.
        let bump = { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let signature = self.outputDevice.formatSignature()
                guard signature != self.outputDeviceSignature else { return }
                self.outputDeviceSignature = signature
                self.deviceGeneration += 1
                log.notice("Output device format changed (\(signature, privacy: .public))")
                self.scheduleRefresh()
            }
        }
        deviceListeners = [
            outputDevice.addListener(kAudioDevicePropertyNominalSampleRate, bump),
            outputDevice.addListener(kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeOutput, bump),
            outputDevice.addListener(kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeInput, bump),
            outputDevice.addListener(kAudioDevicePropertyDeviceIsAlive, bump),
        ].compactMap { $0 }

        refresh()
    }

    private func gain(for key: String) -> Float {
        settings[key]?.gain ?? 1
    }

    /// Whether the app's audio should run through us right now.
    ///
    /// Besides apps with a custom volume, that's every other app during a call: calling apps make macOS turn all
    /// other audio down ("ducking", up to 15 dB). Audio we play is exempt from that, so while Volume Control is on,
    /// everything sounds the way it does without a call. Turned off, macOS ducks as usual.
    private func needsTap(_ key: String, _ group: AppGroup) -> Bool {
        guard group.isRunningOutput else { return false }
        return gain(for: key) != 1 || (callActive && !group.isInCall && group.identity.isApp)
    }

    private func reconcileAll() {
        for key in Set(groups.keys).union(taps.keys) {
            reconcile(key)
        }
        rebuildRows()
    }

    /// Creates, updates or removes the tap for one app so it matches the app's setting and playback state.
    private func reconcile(_ key: String) {
        let gain = gain(for: key)
        guard isEnabled, let group = groups[key], outputDevice.isValid else {
            errors[key] = nil
            teardown(key)
            return
        }

        if needsTap(key, group) {
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
            ensureTap(for: key, group: group, gain: gain)
        } else {
            errors[key] = nil
            guard let tap = taps[key] else { return }
            // Keep the tap around for a bit so pausing and resuming doesn't briefly play at full volume.
            if tap.deviceGeneration != deviceGeneration || tap.processObjectIDs != group.objectIDs {
                teardown(key)
            } else {
                tap.gain = gain
                // Quick when the tap isn't wanted at all any more; slow when the app has only gone quiet.
                let wanted = gain != 1 || (callActive && !group.isInCall && group.identity.isApp)
                scheduleTeardown(key, after: wanted ? Self.idleTeardownDelay : Self.resetTeardownDelay)
            }
        }
    }

    private func signature(of group: AppGroup) -> String {
        "\(group.objectIDs.sorted())/\(outputDevice)/\(deviceGeneration)"
    }

    private func ensureTap(for key: String, group: AppGroup, gain: Float) {
        if let tap = taps[key], tap.outputDevice == outputDevice, tap.deviceGeneration == deviceGeneration {
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

        let signature = signature(of: group)
        if let failure = failures[key], failure.signature == signature, Date() < failure.retryAt {
            teardown(key)
            return
        }

        // Build the new tap before removing the old one, so the app isn't briefly heard at full volume.
        let previous = taps.removeValue(forKey: key)
        lastIOCycles[key] = nil
        do {
            taps[key] = try VolumeTap(processObjectIDs: group.objectIDs, outputDevice: outputDevice,
                                      deviceGeneration: deviceGeneration, gain: gain)
            errors[key] = nil
            failures[key] = nil
            log.notice("Started tap for \(key, privacy: .public) (processes \(group.objectIDs.sorted(), privacy: .public), gain \(gain))")
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
        pendingTeardowns.values.forEach { $0.item.cancel() }
        pendingTeardowns.removeAll()
        processListeners.values.forEach { $0.listeners.forEach { $0.remove() } }
        processListeners.removeAll()
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
            if AudioCapturePermission.status == .denied {
                log.error("System Audio Recording permission was revoked; stopping all taps")
                permission = .denied
                stopAll()
                rebuildRows()
                return
            }
        }
        for (key, tap) in taps {
            let cycles = tap.ioCycles
            log.debug("\(key, privacy: .public): \(cycles) IO cycles, input peak \(tap.inputPeak), gain \(tap.gain)")
            guard let last = lastIOCycles[key], last.cycles == cycles else {
                lastIOCycles[key] = (cycles, now)
                continue
            }
            // Two checks close together (e.g. just after waking) can see no progress without anything being wrong.
            guard now.timeIntervalSince(last.since) >= Self.stallTimeout else { continue }
            teardown(key)
            if let group = groups[key] {
                recordFailure(for: key, signature: signature(of: group), message: "Audio stopped flowing")
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
    }

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
            return AppRow(id: key,
                          name: group?.identity.name ?? setting?.name ?? (key == AppIdentity.faceTimeKey ? "FaceTime" : key),
                          status: status,
                          volume: setting?.volume ?? 1,
                          muted: setting?.muted ?? false,
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
