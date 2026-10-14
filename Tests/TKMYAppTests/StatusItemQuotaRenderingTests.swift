import AppKit
import XCTest
import UsageDomain
import UsageUI
import UpdateSupport
@testable import TKMYApp

final class StatusItemQuotaRenderingTests: XCTestCase {
    @MainActor
    func testNativeStatusButtonShowsVerifiedQuotaAndUnknownIsNotZero() throws {
        _ = NSApplication.shared
        let suite = "TKMYQuotaRenderingTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.showsRemainingPercentage = true
        settings.showsMenuLabel = true
        settings.menuMeterStyle = .coloredSegments
        let model = SourceUsageViewModel(source: .codex)
        let controller = StatusItemController(
            viewModel: model, updateController: UpdateController(), settings: settings,
            openSettings: { _ in }, statusItemsDidChange: {}, closeOtherPopovers: { _ in }
        )
        defer { controller.close() }
        let button = try XCTUnwrap(controller.statusItem.button)
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/ui-snapshots", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let account = QuotaAccount(source: .codex, email: "synthetic@example.com")
        var images: [String: Data] = [:]
        for (name, usedPercent) in [("available", 4.0 as Double?), ("zero", 100.0), ("unknown", nil)] {
            let limit = usedPercent.map {
                UsageLimitSnapshot(source: .codex, limitID: account.limitID, usedPercent: $0,
                                   windowMinutes: 10080, resetsAt: nil, observedAt: Date())
            }
            // An anonymous history value must never supply the current meter.
            let anonymous = UsageLimitSnapshot(source: .codex, limitID: "codex", usedPercent: 3,
                                               windowMinutes: 10080, resetsAt: nil, observedAt: Date())
            model.apply(.ready(SourceUsageSnapshot(
                source: .codex, dailyUsage: [], usageLimit: limit, usageLimitHistory: [anonymous],
                quotaAccounts: [account], activeQuotaAccountID: account.id
            )))
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
            let expected = limit.map { "\(Int($0.remainingPercent))%" } ?? "—"
            XCTAssertTrue(button.title.contains(expected), button.title)
            XCTAssertFalse(button.title.contains("97%"))
            XCTAssertEqual(controller.statusItem.length, NSStatusItem.variableLength)
            let image = try XCTUnwrap(button.image)
            let data = try XCTUnwrap(image.tiffRepresentation)
            images[name] = data
            button.layoutSubtreeIfNeeded()
            // A deterministic preview of the content verified above on the real
            // NSStatusBarButton; this is not a screenshot of the installed app.
            let title = NSAttributedString(string: button.title, attributes: [
                .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.black,
            ])
            let meter = NSImage(size: image.size, flipped: false) { rect in
                image.draw(in: rect)
                if image.isTemplate {
                    NSColor.black.setFill()
                    rect.fill(using: .sourceIn)
                }
                return true
            }
            let rendered = NSImage(size: NSSize(width: title.size().width + 54, height: 24), flipped: false) { rect in
                NSColor.white.setFill()
                rect.fill()
                NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
                    meter.draw(in: NSRect(x: 8, y: 6, width: 30, height: 12))
                    title.draw(at: NSPoint(x: 44, y: (rect.height - title.size().height) / 2))
                }
                return true
            }
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(rendered.tiffRepresentation)))
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: directory.appendingPathComponent("statusbar-presentation-\(name).png"))
        }
        XCTAssertNotEqual(images["unknown"], images["zero"])
        XCTAssertNotEqual(images["available"], images["zero"])
    }
}
