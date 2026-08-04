import AppKit
import Foundation

enum Canvas {
    static let width = 720
    static let height = 460
}

func centeredText(
    _ text: String,
    font: NSFont,
    color: NSColor,
    y: CGFloat,
    height: CGFloat
) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    paragraph.lineBreakMode = .byTruncatingTail
    text.draw(
        in: NSRect(x: 48, y: y, width: CGFloat(Canvas.width) - 96, height: height),
        withAttributes: [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ]
    )
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("Usage: create-dmg-background.swift OUTPUT_PNG\n".utf8))
    exit(64)
}

let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])
guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Canvas.width,
    pixelsHigh: Canvas.height,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bitmapFormat: [],
    bytesPerRow: 0,
    bitsPerPixel: 0
), let graphicsContext = NSGraphicsContext(bitmapImageRep: bitmap) else {
    FileHandle.standardError.write(Data("Could not create the DMG background canvas.\n".utf8))
    exit(1)
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = graphicsContext

NSColor(calibratedWhite: 0.97, alpha: 1).setFill()
NSRect(x: 0, y: 0, width: Canvas.width, height: Canvas.height).fill()

centeredText(
    "Drag TKMY to Applications",
    font: .systemFont(ofSize: 25, weight: .semibold),
    color: .labelColor,
    y: 350,
    height: 38
)
centeredText(
    "TKMY を Applications にドラッグ",
    font: .systemFont(ofSize: 14),
    color: .secondaryLabelColor,
    y: 322,
    height: 24
)

let context = graphicsContext.cgContext
context.setStrokeColor(NSColor.systemBlue.cgColor)
context.setFillColor(NSColor.systemBlue.cgColor)
context.setLineWidth(5)
context.setLineCap(.round)
context.move(to: CGPoint(x: 300, y: 210))
context.addLine(to: CGPoint(x: 421, y: 210))
context.strokePath()
context.move(to: CGPoint(x: 445, y: 210))
context.addLine(to: CGPoint(x: 414, y: 228))
context.addLine(to: CGPoint(x: 414, y: 192))
context.closePath()
context.fillPath()

centeredText(
    "INSTALL",
    font: .monospacedSystemFont(ofSize: 11, weight: .medium),
    color: .secondaryLabelColor,
    y: 72,
    height: 18
)

NSGraphicsContext.restoreGraphicsState()

guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("Could not encode the DMG background as PNG.\n".utf8))
    exit(1)
}
try FileManager.default.createDirectory(
    at: outputURL.deletingLastPathComponent(),
    withIntermediateDirectories: true
)
try pngData.write(to: outputURL, options: .atomic)
