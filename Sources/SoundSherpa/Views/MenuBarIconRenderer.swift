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
    private static let headphonesPointSize: CGFloat = 15
    private static let spacing: CGFloat = 3
    private static let batteryBodyWidth: CGFloat = 14
    private static let batteryBodyHeight: CGFloat = 7
    private static let batteryNubWidth: CGFloat = 1
    private static let batteryNubHeight: CGFloat = 3.5
    private static let batteryFillInset: CGFloat = 1
    private static let numberPointSize: CGFloat = 8

    // Vertical battery glyph geometry.
    private static let vBatteryWidth: CGFloat = 7
    private static let vBatteryHeight: CGFloat = 12
    private static let vBatteryNubWidth: CGFloat = 3
    private static let vBatteryNubHeight: CGFloat = 1

    /// Build the menu bar image for the given state. When battery is not shown
    /// or no level is available, returns just the headphones glyph.
    static func image(content: MenuBarContent, isConnected: Bool, batteryLevel: Int?) -> NSImage {
        let symbolName = content.connectionSymbolName(isConnected: isConnected)

        // Only show a battery when one is configured AND a level is available.
        let style: MenuBarBatteryStyle? = batteryLevel == nil ? nil : content.batteryStyle
        let level = batteryLevel ?? 0

        // Normal charge (or no battery) → template (monochrome); low/critical → tinted.
        let tier = style == nil ? .normal : DeviceDisplay.menuBarBatteryTier(forLevel: level)
        let color = tierColor(for: tier)
        let isTemplate = (tier == .normal)

        // Width the headphones glyph plus, if shown, the battery column. Icon-only
        // and battery modes share the same canvas + drawHeadphones so the glyph is
        // identical in size across all modes.
        var totalWidth = headphonesSize
        switch style {
        case .horizontalWithNumber: totalWidth += spacing + batteryBodyWidth + batteryNubWidth
        case .verticalGlyph:        totalWidth += spacing + vBatteryWidth
        case .none:                 break
        }

        let image = NSImage(size: NSSize(width: totalWidth, height: height), flipped: false) { _ in
            drawHeadphones(named: symbolName, color: color)
            switch style {
            case .horizontalWithNumber: drawHorizontalBattery(level: level, color: color)
            case .verticalGlyph:        drawVerticalBattery(level: level, color: color)
            case .none:                 break
            }
            return true
        }
        image.isTemplate = isTemplate
        return image
    }

    // MARK: - Drawing

    private static func drawHeadphones(named symbolName: String, color: NSColor) {
        let config = NSImage.SymbolConfiguration(pointSize: headphonesPointSize, weight: .regular)
            .applying(.init(paletteColors: [color]))
        guard let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return }
        let size = symbol.size
        let rect = NSRect(x: (headphonesSize - size.width) / 2,
                          y: (height - size.height) / 2,
                          width: size.width, height: size.height)
        symbol.draw(in: rect)
    }

    /// Draws the number on the top row with the horizontal battery glyph
    /// (proportionally filled) stacked directly below it, right of the headphones.
    private static func drawHorizontalBattery(level: Int, color: NSColor) {
        let columnX = headphonesSize + spacing

        // Number on the top row.
        let text = "\(level)"
        let font = NSFont.systemFont(ofSize: numberPointSize, weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let textSize = (text as NSString).size(withAttributes: attrs)
        let textX = columnX + (batteryBodyWidth - textSize.width) / 2
        (text as NSString).draw(at: NSPoint(x: textX, y: height - textSize.height),
                                withAttributes: attrs)

        // Battery glyph on the bottom row.
        let body = NSRect(x: columnX, y: 0, width: batteryBodyWidth, height: batteryBodyHeight)

        color.set()

        // Outline
        let outline = NSBezierPath(roundedRect: body, xRadius: 2, yRadius: 2)
        outline.lineWidth = 1
        outline.stroke()

        // Positive terminal nub
        let nub = NSRect(x: body.maxX, y: body.midY - batteryNubHeight / 2,
                         width: batteryNubWidth, height: batteryNubHeight)
        NSBezierPath(roundedRect: nub, xRadius: 0.75, yRadius: 0.75).fill()

        // Proportional fill inside the body, width tracks charge (like iOS/system).
        let insetBody = body.insetBy(dx: batteryFillInset, dy: batteryFillInset)
        let fraction = CGFloat(max(0, min(100, level))) / 100
        let fill = NSRect(x: insetBody.minX, y: insetBody.minY,
                          width: insetBody.width * fraction, height: insetBody.height)
        NSBezierPath(roundedRect: fill, xRadius: 1, yRadius: 1).fill()
    }

    /// Draws a vertical battery glyph (nub on top) that fills from the bottom by
    /// charge, no number. Right of the headphones, vertically centered.
    private static func drawVerticalBattery(level: Int, color: NSColor) {
        let bodyX = headphonesSize + spacing
        // Center the full glyph (body + nub) so it sits visually centered.
        let bodyY = (height - (vBatteryHeight + vBatteryNubHeight)) / 2
        let body = NSRect(x: bodyX, y: bodyY, width: vBatteryWidth, height: vBatteryHeight)

        color.set()

        // Outline
        NSBezierPath(roundedRect: body, xRadius: 2, yRadius: 2).stroke()

        // Positive terminal nub, centered on top.
        let nub = NSRect(x: body.midX - vBatteryNubWidth / 2, y: body.maxY,
                         width: vBatteryNubWidth, height: vBatteryNubHeight)
        NSBezierPath(roundedRect: nub, xRadius: 0.5, yRadius: 0.5).fill()

        // Proportional fill from the bottom, height tracks charge.
        let insetBody = body.insetBy(dx: batteryFillInset, dy: batteryFillInset)
        let fraction = CGFloat(max(0, min(100, level))) / 100
        let fill = NSRect(x: insetBody.minX, y: insetBody.minY,
                          width: insetBody.width, height: insetBody.height * fraction)
        NSBezierPath(roundedRect: fill, xRadius: 0.75, yRadius: 0.75).fill()
    }

    private static func tierColor(for tier: BatteryTier) -> NSColor {
        switch tier {
        case .critical: return .systemRed
        case .low:      return .systemOrange
        case .normal:   return .labelColor
        }
    }
}
