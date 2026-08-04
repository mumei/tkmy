/* Hallmark · component: menu meter · genre: modern-minimal · theme: macOS-native
 * states: available · unavailable · low · medium · high · light · dark · source-accent
 * contrast: system semantic colors
 * Hallmark · pre-emit critique: P5 H5 E5 S5 R5 V5
 */
import AppKit
import UsageDomain

enum MenuMeterStyle: String, CaseIterable, Identifiable {
    case coloredBar
    case monochromeBar
    case monochromeSegments
    case coloredSegments
    case dots
    case ring
    case gauge
    case battery
    case verticalBars
    case percentageOnly

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .coloredBar: "カラーバー"
        case .monochromeBar: "モノクロバー"
        case .monochromeSegments: "分割"
        case .coloredSegments: "カラー分割"
        case .dots: "ドット"
        case .ring: "リング"
        case .gauge: "ゲージ"
        case .battery: "バッテリー"
        case .verticalBars: "縦バー"
        case .percentageOnly: "数字のみ"
        }
    }
}

enum MenuMeterRenderer {
    static func image(style: MenuMeterStyle, percentage: Double, source: UsageSource) -> NSImage? {
        guard style != .percentageOnly else { return nil }
        let progress = min(1, max(0, percentage / 100))
        let size = NSSize(width: 30, height: 12)
        let image = NSImage(size: size, flipped: false) { rect in
            switch style {
            case .coloredBar:
                drawBar(in: rect, progress: progress, color: accent(for: source))
            case .monochromeBar:
                drawBar(in: rect, progress: progress, color: .labelColor)
            case .monochromeSegments:
                drawSegments(in: rect, progress: progress, color: .labelColor)
            case .coloredSegments:
                drawSegments(in: rect, progress: progress, color: accent(for: source))
            case .dots:
                drawDots(in: rect, progress: progress, color: accent(for: source))
            case .ring:
                drawRing(in: rect, progress: progress, color: accent(for: source))
            case .gauge:
                drawGauge(in: rect, progress: progress, color: accent(for: source))
            case .battery:
                drawBattery(in: rect, progress: progress, color: accent(for: source))
            case .verticalBars:
                drawVerticalBars(in: rect, progress: progress, color: accent(for: source))
            case .percentageOnly:
                break
            }
            return true
        }
        image.isTemplate = style == .monochromeBar || style == .monochromeSegments
        return image
    }

    private static func drawBar(in rect: NSRect, progress: Double, color: NSColor) {
        let track = NSRect(x: rect.minX, y: rect.midY - 3, width: rect.width, height: 6)
        let path = NSBezierPath(roundedRect: track, xRadius: 3, yRadius: 3)
        trackColor.setFill()
        path.fill()
        guard progress > 0 else { return }

        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        color.setFill()
        NSRect(x: track.minX, y: track.minY, width: max(2, track.width * progress), height: track.height).fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func drawSegments(in rect: NSRect, progress: Double, color: NSColor) {
        let count = 5
        let gap: CGFloat = 2
        let width = (rect.width - gap * CGFloat(count - 1)) / CGFloat(count)
        let filled = filledCount(progress: progress, count: count)
        for index in 0..<count {
            let segment = NSRect(
                x: rect.minX + CGFloat(index) * (width + gap),
                y: rect.midY - 3,
                width: width,
                height: 6
            )
            (index < filled ? color : trackColor).setFill()
            NSBezierPath(roundedRect: segment, xRadius: 1.5, yRadius: 1.5).fill()
        }
    }

    private static func drawDots(in rect: NSRect, progress: Double, color: NSColor) {
        let count = 5
        let diameter: CGFloat = 4
        let gap = (rect.width - diameter * CGFloat(count)) / CGFloat(count - 1)
        let filled = filledCount(progress: progress, count: count)
        for index in 0..<count {
            let dot = NSRect(
                x: rect.minX + CGFloat(index) * (diameter + gap),
                y: rect.midY - diameter / 2,
                width: diameter,
                height: diameter
            )
            (index < filled ? color : trackColor).setFill()
            NSBezierPath(ovalIn: dot).fill()
        }
    }

    private static func drawRing(in rect: NSRect, progress: Double, color: NSColor) {
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let radius: CGFloat = 4.5
        let background = NSBezierPath()
        background.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        background.lineWidth = 2.5
        trackColor.setStroke()
        background.stroke()

        guard progress > 0 else { return }
        let foreground = NSBezierPath()
        foreground.appendArc(
            withCenter: center,
            radius: radius,
            startAngle: 90,
            endAngle: 90 - CGFloat(progress * 360),
            clockwise: true
        )
        foreground.lineWidth = 2.5
        foreground.lineCapStyle = .round
        color.setStroke()
        foreground.stroke()
    }

    private static func drawGauge(in rect: NSRect, progress: Double, color: NSColor) {
        let center = NSPoint(x: rect.midX, y: rect.minY + 2)
        let radius: CGFloat = 9
        let background = NSBezierPath()
        background.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 180)
        background.lineWidth = 3
        background.lineCapStyle = .round
        trackColor.setStroke()
        background.stroke()

        guard progress > 0 else { return }
        let foreground = NSBezierPath()
        foreground.appendArc(
            withCenter: center,
            radius: radius,
            startAngle: 180,
            endAngle: 180 - CGFloat(progress * 180),
            clockwise: true
        )
        foreground.lineWidth = 3
        foreground.lineCapStyle = .round
        color.setStroke()
        foreground.stroke()
    }

    private static func drawBattery(in rect: NSRect, progress: Double, color: NSColor) {
        let body = NSRect(x: rect.minX + 1, y: rect.midY - 4, width: 25, height: 8)
        let outline = NSBezierPath(roundedRect: body, xRadius: 2, yRadius: 2)
        outline.lineWidth = 1.25
        NSColor.secondaryLabelColor.setStroke()
        outline.stroke()
        NSColor.secondaryLabelColor.setFill()
        NSBezierPath(roundedRect: NSRect(x: body.maxX + 1, y: rect.midY - 2, width: 2, height: 4), xRadius: 1, yRadius: 1).fill()

        guard progress > 0 else { return }
        color.setFill()
        let interior = NSRect(
            x: body.minX + 2,
            y: body.minY + 2,
            width: max(1.5, (body.width - 4) * progress),
            height: body.height - 4
        )
        NSBezierPath(roundedRect: interior, xRadius: 1, yRadius: 1).fill()
    }

    private static func drawVerticalBars(in rect: NSRect, progress: Double, color: NSColor) {
        let count = 5
        let width: CGFloat = 4
        let gap: CGFloat = 2
        let contentWidth = width * CGFloat(count) + gap * CGFloat(count - 1)
        let originX = rect.midX - contentWidth / 2
        let filled = filledCount(progress: progress, count: count)
        for index in 0..<count {
            let height = CGFloat(index + 1) * 2
            let bar = NSRect(
                x: originX + CGFloat(index) * (width + gap),
                y: rect.minY + 1,
                width: width,
                height: height
            )
            (index < filled ? color : trackColor).setFill()
            NSBezierPath(roundedRect: bar, xRadius: 1, yRadius: 1).fill()
        }
    }

    private static func filledCount(progress: Double, count: Int) -> Int {
        progress > 0 ? min(count, max(1, Int(ceil(progress * Double(count))))) : 0
    }

    private static var trackColor: NSColor {
        NSColor.tertiaryLabelColor.withAlphaComponent(0.32)
    }

    private static func accent(for source: UsageSource) -> NSColor {
        source == .codex ? .systemBlue : .systemOrange
    }
}
