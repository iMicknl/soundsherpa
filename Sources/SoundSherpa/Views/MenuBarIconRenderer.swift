import AppKit
import SoundSherpaCore

/// Composites the menu bar glyph into a single `NSImage` at fixed internal
/// proportions. This is the workaround for `MenuBarExtra` scaling a custom
/// `label:` view to the status-bar height — a `.font()` on a text+icon stack is
/// a no-op because the whole stack gets scaled up. By baking the layout (tiny
/// number inside the battery, beside the headphones) into one image, the
/// system's scale-to-height preserves those proportions.
///
/// Rendered as a template (monochrome, adapts to light/dark) at normal charge;
/// rendered in the tier color (amber/red) when low, since template images can't
/// carry color.
enum MenuBarIconRenderer {
    // Point geometry; the image is scaled to the bar height by the system, so
    // only the aspect ratio and relative sizes matter here.
    private static let height: CGFloat = 18
    private static let headphonesSize: CGFloat = 18
    private static let spacing: CGFloat = 3
    private static let batteryBodyWidth: CGFloat = 24
    private static let batteryBodyHeight: CGFloat = 12
    private static let batteryNubWidth: CGFloat = 2
    private static let batteryNubHeight: CGFloat = 6

    /// Build the menu bar image for the given state. When battery is not shown
    /// or no level is available, returns just the headphones glyph.
    static func image(content: MenuBarContent, isConnected: Bool, batteryLevel: Int?) -> NSImage {
        let symbolName = content.connectionSymbolName(isConnected: isConnected)

        guard content.showsBattery, let level = batteryLevel else {
            return symbolImage(named: symbolName)
        }

        let tier = DeviceDisplay.menuBarBatteryTier(forLevel: level)
        let color = tierColor(for: tier)
        let isTemplate = (tier == .normal)

        let totalWidth = headphonesSize + spacing + batteryBodyWidth + batteryNubWidth
        let image = NSImage(size: NSSize(width: totalWidth, height: height), flipped: false) { _ in
            drawHeadphones(named: symbolName, color: color)
            drawBattery(level: level, color: color)
            return true
        }
        image.isTemplate = isTemplate
        return image
    }

    // MARK: - Drawing

    private static func drawHeadphones(named symbolName: String, color: NSColor) {
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
            .applying(.init(paletteColors: [color]))
        guard let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return }
        let size = symbol.size
        let rect = NSRect(x: (headphonesSize - size.width) / 2,
                          y: (height - size.height) / 2,
                          width: size.width, height: size.height)
        symbol.draw(in: rect)
    }

    private static func drawBattery(level: Int, color: NSColor) {
        let bodyX = headphonesSize + spacing
        let bodyY = (height - batteryBodyHeight) / 2
        let body = NSRect(x: bodyX, y: bodyY, width: batteryBodyWidth, height: batteryBodyHeight)

        color.set()

        // Outline
        let outline = NSBezierPath(roundedRect: body, xRadius: 2.5, yRadius: 2.5)
        outline.lineWidth = 1.4
        outline.stroke()

        // Positive terminal nub
        let nub = NSRect(x: body.maxX, y: (height - batteryNubHeight) / 2,
                         width: batteryNubWidth, height: batteryNubHeight)
        NSBezierPath(roundedRect: nub, xRadius: 1, yRadius: 1).fill()

        // Percentage number, small, centered inside the battery body.
        let text = "\(level)"
        let font = NSFont.systemFont(ofSize: 8, weight: .bold)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let size = (text as NSString).size(withAttributes: attrs)
        let origin = NSPoint(x: body.midX - size.width / 2, y: body.midY - size.height / 2)
        (text as NSString).draw(at: origin, withAttributes: attrs)
    }

    /// A single SF Symbol as a template image at the standard menu bar size.
    private static func symbolImage(named symbolName: String) -> NSImage {
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "SoundSherpa")
            ?? NSImage()
        image.isTemplate = true
        return image
    }

    private static func tierColor(for tier: BatteryTier) -> NSColor {
        switch tier {
        case .critical: return .systemRed
        case .low:      return .systemOrange
        case .normal:   return .labelColor
        }
    }
}
