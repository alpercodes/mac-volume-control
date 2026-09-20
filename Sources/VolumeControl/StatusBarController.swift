import AppKit
import Combine
import SwiftUI

/// The menu bar icon and the glass panel that drops down from it, styled like the system's own menu bar panels
/// (Control Center, Sound, Wi-Fi). A custom panel rather than `MenuBarExtra` so the shape, material and size are
/// under our control.
@MainActor
final class StatusBarController: NSObject {
    private let model: VolumeModel
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private var panel: MenuPanel!
    private var enabledObservation: AnyCancellable?
    private var clickMonitor: Any?
    private var lastCloseTime = Date.distantPast

    /// Gap between the menu bar and the panel.
    private static let menuBarGap: CGFloat = 6
    /// Keeps the panel this far from the screen edges.
    private static let screenMargin: CGFloat = 8

    init(model: VolumeModel) {
        self.model = model
        super.init()

        panel = MenuPanel(rootView: MenuView(model: model))
        panel.onClose = { [weak self] in self?.panelDidClose() }

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePanel)
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
        }
        if #available(macOS 27.0, *) {
            // macOS 27 tracks a panel opened from the menu bar: it highlights the icon while the panel is open and
            // closes it on the next click, like its own menu bar items. It drives the panel through the delegate
            // methods below instead of the button's action.
            statusItem.expandedInterfaceDelegate = self
        }
        panel.setAccessibilityLabel("Volume Control")
        enabledObservation = model.$isEnabled.sink { [weak self] enabled in
            self?.statusItem.button?.image = enabled ? MenuBarIcon.on : MenuBarIcon.off
            self?.statusItem.button?.setAccessibilityLabel(enabled ? "Volume Control" : "Volume Control, off")
        }
        // Close like a menu when the user moves on: switching Spaces or apps (e.g. with Command-Tab).
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(closePanel), name: name, object: nil)
        }
    }

    /// The button's action still fires on macOS 27, where the menu bar opens the panel itself. The session can
    /// begin either side of this call, so decide once the click has been handled, and only step in if the menu bar
    /// didn't (on macOS 26 and earlier, and if the session ever fails to start).
    @objc private func togglePanel() {
        if #available(macOS 27.0, *) {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.statusItem.expandedInterfaceSession == nil else { return }
                self.toggle()
            }
        } else {
            toggle()
        }
    }

    private func toggle() {
        if panel.isVisible { return closePanel() }
        // Clicking the icon takes keyboard focus off the panel, which closes it (see MenuPanel.resignKey), and the
        // same click then arrives here. Without this, the panel would reopen instead of closing.
        guard Date().timeIntervalSince(lastCloseTime) > 0.3 else { return }
        showPanel()
    }

    private func showPanel() {
        guard !panel.isVisible else { return }
        removeClickMonitor()  // In case the panel was hidden behind our back, e.g. by Hide Others.
        model.refreshPermission()
        if let screen = statusItem.button?.window?.screen ?? NSScreen.main {
            // Leave room for the header and footer so the panel never reaches under the Dock.
            model.maxListHeight = max(150, min(420, screen.visibleFrame.height - 180))
        }
        guard let frame = panelFrame(for: panel.idealContentSize()) else { return }
        panel.setFrame(frame, display: false)
        panel.alphaValue = 0
        panel.shownAt = Date()
        panel.makeKeyAndOrderFront(nil)
        panel.scheduleFit()  // Controls can measure slightly differently once they're on screen.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }
        setHighlighted(true)

        // Close on any click outside the panel (clicks in other apps don't reach our own event handlers).
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.closePanel() }
        }
    }

    @objc private func closePanel() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        panelDidClose()
    }

    /// Called however the panel was dismissed: by a click on the icon, a click outside, Escape, or Quit.
    private func panelDidClose() {
        lastCloseTime = Date()
        setHighlighted(false)
        removeClickMonitor()
        if #available(macOS 27.0, *) {
            // Ends the menu bar's tracking, which unhighlights the icon. Does nothing if the menu bar ended the
            // session itself; `statusItemDidEndExpandedInterfaceSession` gets it back to nil first.
            statusItem.expandedInterfaceSession?.cancel()
        }
    }

    private func removeClickMonitor() {
        guard let clickMonitor else { return }
        NSEvent.removeMonitor(clickMonitor)
        self.clickMonitor = nil
    }

    /// Up to macOS 26 the app lights the icon itself. From 27 on, the status item is drawn by the system, where
    /// this has no effect and the menu bar highlights the icon for as long as the session lasts.
    private func setHighlighted(_ highlighted: Bool) {
        if #available(macOS 27.0, *) { return }
        guard let button = statusItem.button, button.isHighlighted != highlighted else { return }
        button.isHighlighted = highlighted
    }

    /// Centered under the menu bar icon, kept on screen.
    private func panelFrame(for size: CGSize) -> NSRect? {
        guard let button = statusItem.button, let buttonWindow = button.window,
              let screen = buttonWindow.screen ?? NSScreen.main else { return nil }
        let buttonFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let visible = screen.visibleFrame
        var x = buttonFrame.midX - size.width / 2
        x = min(max(x, visible.minX + Self.screenMargin), visible.maxX - size.width - Self.screenMargin)
        let y = min(buttonFrame.minY, visible.maxY) - Self.menuBarGap - size.height
        return NSRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
    }
}

/// macOS 27 opens and closes the panel itself, so that the icon is highlighted while the panel is open and the
/// panel takes part in menu bar keyboard navigation, the way the system's own menu bar panels do.
@available(macOS 27.0, *)
extension StatusBarController: @MainActor NSStatusItemExpandedInterfaceDelegate {
    func statusItem(_ statusItem: NSStatusItem, didBegin session: NSStatusItemExpandedInterfaceSession) {
        showPanel()
    }

    func statusItemDidEndExpandedInterfaceSession(_ statusItem: NSStatusItem, animated: Bool) {
        // Same grace as `MenuPanel.resignKey`: just after opening, the panel taking the keyboard can look like a
        // dismissal. Then leave it open, and let the button's action close it on the next click.
        guard Date().timeIntervalSince(panel.shownAt) > 0.3 else { return }
        closePanel()
    }
}

/// A borderless, non-activating panel with a rounded glass background: Liquid Glass on macOS 26 and later, the
/// classic blurred popover material before that. It resizes itself to its SwiftUI content, keeping its top edge
/// under the menu bar.
final class MenuPanel: NSPanel {
    /// Matches the rounder corners of the system's menu bar panels.
    static let cornerRadius: CGFloat = 18

    var onClose: (() -> Void)?
    private let hostingController: NSHostingController<AnyView>
    private var fitScheduled = false

    init<Content: View>(rootView: Content) {
        hostingController = NSHostingController(rootView: AnyView(EmptyView()))
        // The panel sets its own frame from `idealContentSize()`; don't let the hosting view resize the window.
        hostingController.sizingOptions = []
        let hostingView = hostingController.view
        super.init(contentRect: NSRect(x: 0, y: 0, width: 320, height: 300),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        // The glass draws its own edge. A window shadow would be computed from a different shape and show up as a
        // dark outline with the wrong corner radius.
        hasShadow = false
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        hidesOnDeactivate = false
        isMovable = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = false

        hostingController.rootView = AnyView(rootView.onGeometryChange(for: CGSize.self) { $0.size } action: {
            [weak self] _ in
            self?.scheduleFit()
        })
        hostingView.autoresizingMask = [.width, .height]
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = Self.cornerRadius
            glass.contentView = hostingView
            // The glass draws a soft shadow around its rounded shape, which the window's rectangular edges would cut
            // off into a faint dark rectangle. Clip to exactly the glass's shape (same radius, same continuous curve).
            let clip = NSView()
            clip.wantsLayer = true
            clip.clipsToBounds = true
            clip.layer?.cornerRadius = Self.cornerRadius
            clip.layer?.cornerCurve = .continuous
            clip.layer?.masksToBounds = true
            glass.autoresizingMask = [.width, .height]
            clip.addSubview(glass)
            contentView = clip
            glass.frame = clip.bounds
        } else {
            let effect = NSVisualEffectView()
            effect.material = .popover
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.maskImage = Self.roundedMask(radius: Self.cornerRadius)
            hostingView.frame = effect.bounds
            effect.addSubview(hostingView)
            contentView = effect
        }
    }

    override var canBecomeKey: Bool { true }

    var shownAt = Date.distantPast

    /// Close like a menu when something else takes the keyboard without a click or an app switch (Spotlight,
    /// Notification Center). Ignored right after opening, while key status can still bounce.
    override func resignKey() {
        super.resignKey()
        guard isVisible, Date().timeIntervalSince(shownAt) > 0.3 else { return }
        orderOut(nil)
        onClose?()
    }

    /// Escape closes the panel, like a menu.
    override func cancelOperation(_ sender: Any?) {
        orderOut(nil)
        onClose?()
    }

    /// The size the SwiftUI content wants, independent of the panel's current frame.
    func idealContentSize() -> CGSize {
        hostingController.sizeThatFits(in: CGSize(width: 10_000, height: 10_000))
    }

    /// Resizes the panel to its content, keeping the top edge in place.
    func fitToContent() {
        let size = idealContentSize()
        let current = frame
        guard size.width > 0, size.height > 0,
              abs(current.height - size.height) > 0.5 || abs(current.width - size.width) > 0.5 else { return }
        setFrame(NSRect(x: current.minX, y: current.maxY - size.height, width: size.width, height: size.height),
                 display: true)
        contentView?.layoutSubtreeIfNeeded()
    }

    /// Fits outside of SwiftUI's layout pass, and once more after any animation has settled, so the panel never
    /// stops at an in-between size.
    func scheduleFit() {
        guard isVisible, !fitScheduled else { return }
        fitScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.fitScheduled = false
            self?.fitToContent()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.fitToContent()
        }
    }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}
