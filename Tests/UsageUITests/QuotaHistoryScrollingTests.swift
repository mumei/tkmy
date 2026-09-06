import AppKit
import Foundation
import SwiftUI
import Testing
import UsageDomain
@testable import UsageUI

@Suite(.serialized)
@MainActor
struct QuotaHistoryScrollingTests {
    @Test("Quota-history rows scroll independently in Japanese")
    func quotaHistoryKeepsItsControlsAndChartFixedWhileRowsScroll() throws {
        let defaults = UserDefaults.standard
        let previousLanguage = defaults.object(forKey: L10n.defaultsKey)
        defer {
            if let previousLanguage {
                defaults.set(previousLanguage, forKey: L10n.defaultsKey)
            } else {
                defaults.removeObject(forKey: L10n.defaultsKey)
            }
        }

        for language in [AppLanguage.japanese] {
            defaults.set(language.rawValue, forKey: L10n.defaultsKey)
            defaults.synchronize()
            let rendered = try renderScrollableQuotaHistory(language: language)
            defer { rendered.close() }

            let before = try #require(
                rendered.stableMetrics(),
                "Quota-history layout did not stabilize for \(language.rawValue)"
            )
            let rowScrollViews = allDescendants(of: rendered.hostingView, as: NSScrollView.self)
                .filter { scrollView in
                    guard let documentView = scrollView.documentView else { return false }
                    return documentView.bounds.height > scrollView.contentView.bounds.height + 1
                }
            #expect(
                rowScrollViews.count == 1,
                "Expected exactly one vertically scrollable quota-row viewport for \(language.rawValue)"
            )
            let rowScrollView = try #require(rowScrollViews.first)

            let viewport = frame(of: rowScrollView.contentView, in: rendered.hostingView)
            let document = try #require(rowScrollView.documentView)
            let documentFrame = frame(of: document, in: rendered.hostingView)
            let pane = rendered.hostingView.bounds

            #expect(before.rowsViewport.height >= 120,
                    "The quota-row viewport should remain useful at popover size for \(language.rawValue)")
            #expect(before.rowsViewport.minY > 200,
                    "The row viewport must begin below the fixed chart and controls for \(language.rawValue)")
            #expect(before.rowsViewport.maxY <= pane.maxY + 1,
                    "The row viewport escaped the quota-history pane for \(language.rawValue)")
            #expect(abs(viewport.minY - before.rowsViewport.minY) <= 2)
            #expect(abs(viewport.height - before.rowsViewport.height) <= 2)
            #expect(viewport.minX >= pane.minX - 1 && viewport.maxX <= pane.maxX + 1,
                    "The row viewport horizontally escaped the pane for \(language.rawValue)")
            #expect(documentFrame.width <= viewport.width + 1,
                    "Quota rows should not introduce horizontal overflow for \(language.rawValue)")
            #expect(!rowScrollView.hasHorizontalScroller)

            let beforeOrigin = rowScrollView.contentView.bounds.origin
            let maximumOffset = max(0, document.bounds.height - rowScrollView.contentView.bounds.height)
            let requestedOffset = min(maximumOffset, beforeOrigin.y + 80)
            #expect(requestedOffset > beforeOrigin.y + 1,
                    "The quota fixture must be taller than its row viewport")
            rowScrollView.contentView.scroll(to: NSPoint(x: beforeOrigin.x, y: requestedOffset))
            rowScrollView.reflectScrolledClipView(rowScrollView.contentView)
            settle(rendered.hostingView, window: rendered.window)

            let after = try #require(
                rendered.stableMetrics(),
                "Quota-history layout did not settle after scrolling for \(language.rawValue)"
            )
            #expect(rowScrollView.contentView.bounds.origin.y > beforeOrigin.y + 1,
                    "Programmatic scrolling did not advance quota-row content for \(language.rawValue)")
            #expect(sameFrame(before.rangePicker, after.rangePicker),
                    "The range selector moved when only rows scrolled for \(language.rawValue)")
            #expect(sameFrame(before.windowPicker, after.windowPicker),
                    "The quota-window selector moved when only rows scrolled for \(language.rawValue)")
            #expect(sameFrame(before.chart, after.chart),
                    "The quota chart must remain outside the row scroll view for \(language.rawValue)")
            #expect(sameFrame(before.tableHeader, after.tableHeader),
                    "The quota table header moved when rows scrolled for \(language.rawValue)")
            #expect(sameFrame(before.rowsViewport, after.rowsViewport),
                    "The row viewport moved when its content scrolled for \(language.rawValue)")
        }
    }
}

@MainActor
private final class ScrollableQuotaHistoryRender {
    let hostingView: NSHostingView<AnyView>
    let window: NSWindow
    private let capture: QuotaHistoryLayoutCapture

    init(language: AppLanguage) {
        let now = Date()
        let layoutCapture = QuotaHistoryLayoutCapture()
        capture = layoutCapture
        let history = scrollingQuotaHistoryFixture(now: now)
        let bucket = UsageLimitHistoryTimeline.preferredBucket(in:
            UsageLimitHistoryTimeline.buckets(from: history, source: .codex, range: .sevenDays, now: now)
        )
        let view = UsageLimitHistoryView(
            history: history,
            source: .codex,
            range: .constant(.sevenDays),
            selectedBucketID: .constant(bucket?.id),
            layoutObserver: { [layoutCapture] metrics in layoutCapture.metrics = metrics }
        )
        .environment(\.locale, Locale(identifier: language.rawValue))
        .environment(\.colorScheme, .dark)
        .environment(\.dynamicTypeSize, .medium)

        hostingView = NSHostingView(rootView: AnyView(view))
        hostingView.frame = NSRect(x: 0, y: 0, width: 608, height: 480)
        hostingView.appearance = NSAppearance(named: .darkAqua)
        window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderBack(nil)
        settle(hostingView, window: window)
    }

    func stableMetrics() -> QuotaHistoryLayoutMetrics? { capture.metrics }

    func close() {
        window.contentView = nil
        window.close()
    }
}

@MainActor
private final class QuotaHistoryLayoutCapture {
    var metrics: QuotaHistoryLayoutMetrics?
}

@MainActor
private func renderScrollableQuotaHistory(language: AppLanguage) throws -> ScrollableQuotaHistoryRender {
    _ = NSApplication.shared
    return ScrollableQuotaHistoryRender(language: language)
}

@MainActor
private func settle(_ hostingView: NSView, window: NSWindow) {
    for _ in 0..<12 {
        hostingView.needsLayout = true
        hostingView.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
}

@MainActor
private func allDescendants<View: NSView>(of root: NSView, as type: View.Type) -> [View] {
    root.subviews.flatMap { child in
        (child as? View).map { [$0] } ?? []
            + allDescendants(of: child, as: type)
    }
}

@MainActor
private func frame(of view: NSView, in ancestor: NSView) -> CGRect {
    view.convert(view.bounds, to: ancestor)
}

private func sameFrame(_ lhs: CGRect, _ rhs: CGRect, tolerance: CGFloat = 1) -> Bool {
    abs(lhs.minX - rhs.minX) <= tolerance
        && abs(lhs.minY - rhs.minY) <= tolerance
        && abs(lhs.width - rhs.width) <= tolerance
        && abs(lhs.height - rhs.height) <= tolerance
}

private func scrollingQuotaHistoryFixture(now: Date) -> [UsageLimitSnapshot] {
    (0..<180).map { index in
        let observedAt = now.addingTimeInterval(-Double(179 - index) * 60)
        return UsageLimitSnapshot(
            source: .codex,
            limitID: "codex",
            usedPercent: min(95, 8 + Double(index) * 0.45),
            windowMinutes: 300,
            resetsAt: now.addingTimeInterval(4 * 60 * 60),
            observedAt: observedAt,
            resetEpochID: "scrolling-fixture"
        )
    }
}
