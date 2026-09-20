import SwiftUI

@main
struct VolumeControlApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Everything lives in the menu bar panel; SwiftUI needs at least one scene.
        Settings { EmptyView() }
            .commands { CommandGroup(replacing: .appSettings) {} }  // No Command-, to an empty window.
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBar: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Installation.takeOverFromOtherCopies { [weak self] in
            let model = VolumeModel()
            model.restoreLaunchAtLogin()
            self?.statusBar = StatusBarController(model: model)
            Installation.offerToRemoveOlderCopies()
        }
    }
}
