import AppKit

/// The menu bar icon: sliders when on, and the same sliders struck through (like `speaker.slash`) when off.
enum MenuBarIcon {
    static let on = make(slashed: false)
    static let off = make(slashed: true)

    private static func make(slashed: Bool) -> NSImage {
        let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        let symbol = NSImage(systemSymbolName: "slider.vertical.3", accessibilityDescription: nil)!
            .withSymbolConfiguration(configuration)!
        let image = NSImage(size: symbol.size, flipped: false) { rect in
            symbol.draw(in: rect)
            guard slashed, let context = NSGraphicsContext.current?.cgContext else { return true }
            let start = CGPoint(x: rect.minX + 1.5, y: rect.maxY - 1)
            let end = CGPoint(x: rect.maxX - 1.5, y: rect.minY + 1)
            context.setLineCap(.round)
            // Cut a gap around the slash so it stays readable over the sliders, then draw the slash itself.
            context.setBlendMode(.clear)
            context.setLineWidth(4.5)
            context.move(to: start)
            context.addLine(to: end)
            context.strokePath()
            context.setBlendMode(.normal)
            context.setStrokeColor(NSColor.black.cgColor)
            context.setLineWidth(1.5)
            context.move(to: start)
            context.addLine(to: end)
            context.strokePath()
            return true
        }
        image.alignmentRect = symbol.alignmentRect  // Sit on the same baseline as the system's own icons.
        image.isTemplate = true
        image.accessibilityDescription = slashed ? "Volume Control (off)" : "Volume Control"
        return image
    }
}
