import AppKit
import CoreAudio

/// A process that Core Audio knows about (anything that has opened an audio client).
struct AudioProcess: Hashable {
    let objectID: AudioObjectID
    let pid: pid_t
    let bundleID: String?
    let isRunningOutput: Bool
    let isRunningInput: Bool
    /// The devices it plays to (only read while it's playing).
    let outputDevices: [AudioDeviceID]

    /// Every process but this one and `excluded` (our own helpers).
    static func all(excluding excluded: Set<pid_t> = []) -> [AudioProcess] {
        let ownPID = getpid()
        return ((try? AudioObjectID.processObjects()) ?? []).compactMap { id in
            guard let pid: pid_t = try? id.read(kAudioProcessPropertyPID, default: -1), pid > 0, pid != ownPID,
                  !excluded.contains(pid) else {
                return nil
            }
            let bundleID = (try? id.readString(kAudioProcessPropertyBundleID)).flatMap { $0?.isEmpty == false ? $0 : nil }
            let running: UInt32 = (try? id.read(kAudioProcessPropertyIsRunningOutput, default: 0)) ?? 0
            let recording: UInt32 = (try? id.read(kAudioProcessPropertyIsRunningInput, default: 0)) ?? 0
            let devices = running == 0 ? [] : (try? id.readArray(kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeOutput,
                                                                   element: AudioDeviceID.unknown)) ?? []
            return AudioProcess(objectID: id, pid: pid, bundleID: bundleID, isRunningOutput: running != 0,
                                isRunningInput: recording != 0, outputDevices: devices)
        }
    }
}

/// Identifies the user-facing app a process's audio belongs to. Volume settings are stored per key.
struct AppIdentity: Hashable {
    let key: String
    let name: String
    /// Whether this is a regular app (shown even when silent) rather than a background process.
    var isApp = false

    static let faceTimeKey = "com.apple.FaceTime"

    /// FaceTime call audio is played by the `avconferenced` daemon, and the ringtone by the FaceTime app or
    /// `callservicesd`, so all of them are controlled by the one FaceTime slider.
    private static let faceTimeBundleIDs: Set<String> = [
        "com.apple.FaceTime",
        "com.apple.avconferenced",
        "com.apple.TelephonyUtilities",
    ]

    private static let friendlyProcessNames = [
        "systemsoundserverd": "System Sounds",
    ]

    static func of(_ process: AudioProcess) -> AppIdentity {
        if let bundleID = process.bundleID, faceTimeBundleIDs.contains(bundleID) {
            return AppIdentity(key: faceTimeKey, name: "FaceTime", isApp: true)
        }

        // Helper processes (e.g. Safari's WebKit GPU process) play audio on behalf of the app responsible for them.
        let responsiblePID = responsiblePID(for: process.pid)
        let responsibleApp = NSRunningApplication(processIdentifier: responsiblePID)
        if let app = responsibleApp, app.activationPolicy == .regular, let bundleID = app.bundleIdentifier {
            return AppIdentity(key: bundleID, name: app.localizedName ?? bundleID, isApp: true)
        }

        // Helpers macOS doesn't attribute to their app (e.g. a browser's audio helper, "Google Chrome Helper") belong
        // to the running app whose bundle ID theirs extends: com.google.Chrome.helper → com.google.Chrome.
        if let helperID = process.bundleID ?? responsibleApp?.bundleIdentifier, let app = owningApp(ofHelper: helperID),
           let bundleID = app.bundleIdentifier {
            return AppIdentity(key: bundleID, name: app.localizedName ?? bundleID, isApp: true)
        }

        if let app = responsibleApp, let bundleID = app.bundleIdentifier {
            return AppIdentity(key: bundleID, name: app.localizedName ?? bundleID)
        }

        let processName = name(of: process.pid)
        if let bundleID = process.bundleID {
            return AppIdentity(key: bundleID, name: friendlyProcessNames[processName] ?? processName)
        }
        return AppIdentity(key: "process:\(processName)", name: friendlyProcessNames[processName] ?? processName)
    }

    private static func owningApp(ofHelper helperID: String) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications
            .filter { app in
                guard app.activationPolicy == .regular, let appID = app.bundleIdentifier else { return false }
                return helperID.hasPrefix(appID + ".")
            }
            .max { ($0.bundleIdentifier?.count ?? 0) < ($1.bundleIdentifier?.count ?? 0) }
    }

    private static func name(of pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        proc_name(pid, &buffer, UInt32(buffer.count))
        let name = String(cString: buffer)
        return name.isEmpty ? "Process \(pid)" : name
    }

    private typealias ResponsibilityFunction = @convention(c) (pid_t) -> pid_t

    private static let responsibilityFunction: ResponsibilityFunction? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else {
            return nil
        }
        return unsafeBitCast(symbol, to: ResponsibilityFunction.self)
    }()

    private static func responsiblePID(for pid: pid_t) -> pid_t {
        guard let function = responsibilityFunction else { return pid }
        let responsible = function(pid)
        return responsible > 0 ? responsible : pid
    }
}

enum AppIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(for key: String) -> NSImage {
        if let cached = cache[key] { return cached }
        let icon: NSImage
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: key) {
            icon = NSWorkspace.shared.icon(forFile: url.path)
        } else if key == "process:systemsoundserverd" {
            icon = NSImage(systemSymbolName: "bell.fill", accessibilityDescription: nil) ?? NSImage()
        } else {
            icon = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil) ?? NSImage()
        }
        cache[key] = icon
        return icon
    }
}
