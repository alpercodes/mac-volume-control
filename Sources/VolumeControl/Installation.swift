import AppKit

/// Keeps one copy of the app running and installed. Two running copies would both route the same apps' audio, and an
/// update installed next to the old version (e.g. "Volume Control 2") would otherwise leave the old one behind.
@MainActor
enum Installation {
    /// Set per build by build.sh (a timestamp), so copies can be compared.
    static let buildNumber = buildNumber(of: Bundle.main.bundleURL)

    private static let bundleID = Bundle.main.bundleIdentifier ?? "dev.alper.VolumeControl"
    private static let keptCopiesKey = "keptOldCopies"

    static func buildNumber(of app: URL) -> Int {
        // Read the file directly: Bundle(url:) caches, and the copy may have been replaced since.
        let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        return Int(info?["CFBundleVersion"] as? String ?? "") ?? 0
    }

    /// Quits any other running copy, then calls `start`. If another running copy is newer, quits this one instead.
    static func takeOverFromOtherCopies(then start: @escaping () -> Void) {
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != getpid() }
        guard !others.isEmpty else { return start() }

        if others.contains(where: { ($0.bundleURL.map(buildNumber(of:)) ?? 0) > buildNumber }) {
            log.notice("A newer copy is already running; quitting this one")
            NSApp.terminate(nil)
            return
        }
        log.notice("Quitting \(others.count, privacy: .public) other running copies")
        others.forEach { $0.terminate() }
        waitForExit(others, until: Date().addingTimeInterval(3), then: start)
    }

    private static func waitForExit(_ apps: [NSRunningApplication], until deadline: Date, then start: @escaping () -> Void) {
        let running = apps.filter { !$0.isTerminated }
        if running.isEmpty { return start() }
        if Date() > deadline {
            running.forEach { $0.forceTerminate() }
            return start()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            MainActor.assumeIsolated { waitForExit(apps, until: deadline, then: start) }
        }
    }

    /// Offers to move older copies in an Applications folder to the Trash.
    static func offerToRemoveOlderCopies() {
        let own = normalized(Bundle.main.bundleURL)
        // Running from the disk image or Downloads: the installed copy is the one to keep.
        guard isInApplicationsFolder(own) else { return }

        let kept = Set(UserDefaults.standard.stringArray(forKey: keptCopiesKey) ?? [])
        let older = NSWorkspace.shared.urlsForApplications(withBundleIdentifier: bundleID)
            .map(normalized)
            .filter { url in
                url != own && isInApplicationsFolder(url) && !kept.contains(url.path)
                    && FileManager.default.fileExists(atPath: url.path) && buildNumber(of: url) <= buildNumber
            }
        guard !older.isEmpty else { return }

        let alert = NSAlert()
        alert.messageText = older.count == 1 ? "Remove the old copy of Volume Control?" : "Remove the old copies of Volume Control?"
        let list = older.map { "• " + $0.path.replacingOccurrences(of: NSHomeDirectory(), with: "~") }.joined(separator: "\n")
        alert.informativeText = "This version replaces:\n\(list)\n\nIt will be moved to the Trash."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Keep")
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else {
            UserDefaults.standard.set(Array(kept.union(older.map(\.path))), forKey: keptCopiesKey)
            return
        }
        NSWorkspace.shared.recycle(older) { _, error in
            if let error { log.error("Couldn't move old copies to the Trash: \(error, privacy: .public)") }
        }
    }

    private static func normalized(_ url: URL) -> URL {
        url.resolvingSymlinksInPath().standardizedFileURL
    }

    private static func isInApplicationsFolder(_ url: URL) -> Bool {
        let folder = url.deletingLastPathComponent().path
        return folder == "/Applications" || folder == NSHomeDirectory() + "/Applications"
    }
}
