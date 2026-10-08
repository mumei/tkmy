import AppKit
import Foundation
import SwiftUI
import Testing
import UsageDomain
@testable import UsageUI

@Suite(.serialized)
@MainActor
struct QuotaHistorySelectionTests {
    @Test("Quota-history range and window survive refresh states and root replacement", arguments: [UsageSource.codex, .claudeCode])
    func quotaHistorySelectionSurvivesRefreshesAndParentReplacement(source: UsageSource) throws {
        let defaults = UserDefaults.standard
        let previousLanguage = defaults.object(forKey: L10n.defaultsKey)
        defer {
            if let previousLanguage {
                defaults.set(previousLanguage, forKey: L10n.defaultsKey)
            } else {
                defaults.removeObject(forKey: L10n.defaultsKey)
            }
        }
        defaults.set(AppLanguage.japanese.rawValue, forKey: L10n.defaultsKey)
        defaults.synchronize()
        _ = NSApplication.shared

        for dailyUsage in [[], quotaHistoryDailyUsageFixture(source: source)] {
            let now = Date()
            let history = quotaHistorySelectionFixture(source: source, now: now)
            let snapshot = quotaHistorySnapshot(source: source, history: history, dailyUsage: dailyUsage, refreshedAt: now)
            let viewModel = SourceUsageViewModel(source: source)
            viewModel.apply(.ready(snapshot))
            let expectedBucketID = try #require(
                UsageLimitHistoryTimeline.buckets(
                    from: history,
                    source: source,
                    range: .sixHours,
                    now: Date()
                )
                .first(where: { $0.windowMinutes == 10_080 })?
                .id,
                "The fixture must expose a distinct quota window"
            )
            let capture = QuotaHistoryChartRangeCapture()
            let rendered = QuotaHistorySelectionRender(viewModel: viewModel, capture: capture)
            defer { rendered.close() }

            for range in [.sixHours, .twelveHours] as [UsageLimitHistoryRange] {
                viewModel.selectedQuotaHistoryRange = range
                viewModel.selectedQuotaHistoryBucketID = expectedBucketID
                rendered.settle()
                assertSelectedQuotaHistory(
                    viewModel: viewModel,
                    chartCapture: capture,
                    range: range,
                    bucketID: expectedBucketID
                )

                // Replacing the parent view is the path that formerly rebuilt the child and reset its @State.
                let appearancesBeforeReplacement = rendered.replaceRootView()
                assertSelectedQuotaHistory(
                    viewModel: viewModel,
                    chartCapture: capture,
                    range: range,
                    bucketID: expectedBucketID
                )
                #expect(
                    capture.appearanceCount > appearancesBeforeReplacement,
                    "Replacing the parent should render a new quota chart"
                )

                let refreshes: [SourceUsageLoadResult] = [
                    .ready(quotaHistorySnapshot(
                        source: source,
                        history: history,
                        dailyUsage: dailyUsage,
                        refreshedAt: now.addingTimeInterval(60)
                    )),
                    .partialFailure(
                        snapshot: quotaHistorySnapshot(
                            source: source,
                            history: history,
                            dailyUsage: dailyUsage,
                            refreshedAt: now.addingTimeInterval(120)
                        ),
                        unreadableFileCount: 1
                    ),
                    .staleSource(
                        snapshot: quotaHistorySnapshot(
                            source: source,
                            history: history,
                            dailyUsage: dailyUsage,
                            refreshedAt: now.addingTimeInterval(180)
                        ),
                        warning: "fixture"
                    ),
                ]
                for refresh in refreshes {
                    let appearancesBeforeRefresh = capture.appearanceCount
                    viewModel.setLoading()
                    rendered.settle()
                    assertSelectedQuotaHistory(
                        viewModel: viewModel,
                        chartCapture: capture,
                        range: range,
                        bucketID: expectedBucketID
                    )
                    #expect(
                        capture.appearanceCount == appearancesBeforeRefresh,
                        "Loading should keep the quota chart mounted"
                    )
                    viewModel.apply(refresh)
                    rendered.settle()
                    assertSelectedQuotaHistory(
                        viewModel: viewModel,
                        chartCapture: capture,
                        range: range,
                        bucketID: expectedBucketID
                    )
                    #expect(
                        capture.appearanceCount == appearancesBeforeRefresh,
                        "A quota refresh should not recreate the chart"
                    )
                }
            }
        }
    }
}

@MainActor
private final class QuotaHistorySelectionRender {
    let viewModel: SourceUsageViewModel
    let capture: QuotaHistoryChartRangeCapture
    let hostingView: NSHostingView<AnyView>
    let window: NSWindow

    init(viewModel: SourceUsageViewModel, capture: QuotaHistoryChartRangeCapture) {
        self.viewModel = viewModel
        self.capture = capture
        hostingView = NSHostingView(rootView: AnyView(EmptyView()))
        hostingView.frame = NSRect(x: 0, y: 0, width: 640, height: 566)
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
        _ = replaceRootView()
    }

    @discardableResult
    func replaceRootView() -> Int {
        hostingView.rootView = AnyView(EmptyView())
        settle()
        capture.lastRange = nil
        let appearancesBeforeReplacement = capture.appearanceCount
        hostingView.rootView = AnyView(
            SourceUsagePopoverView(
                viewModel: viewModel,
                expectedSource: viewModel.source,
                initialPane: .quotaHistory,
                quotaHistoryChartRangeObserver: { [capture] range in
                    capture.lastRange = range
                    capture.appearanceCount += 1
                }
            )
            .environment(\.locale, Locale(identifier: AppLanguage.japanese.rawValue))
            .environment(\.colorScheme, .dark)
            .environment(\.dynamicTypeSize, .medium)
        )
        settle()
        return appearancesBeforeReplacement
    }

    func settle() {
        for _ in 0..<10 {
            hostingView.needsLayout = true
            hostingView.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }

    func close() {
        window.contentView = nil
        window.close()
    }
}

@MainActor
private final class QuotaHistoryChartRangeCapture {
    var lastRange: UsageLimitHistoryRange?
    var appearanceCount = 0
}

@MainActor
private func assertSelectedQuotaHistory(
    viewModel: SourceUsageViewModel,
    chartCapture: QuotaHistoryChartRangeCapture,
    range: UsageLimitHistoryRange,
    bucketID: String
) {
    #expect(viewModel.selectedQuotaHistoryRange == range)
    #expect(viewModel.selectedQuotaHistoryBucketID == bucketID)
    #expect(chartCapture.lastRange == range,
            "The rendered quota chart should retain the selected range")
}

private func quotaHistorySnapshot(
    source: UsageSource,
    history: [UsageLimitSnapshot],
    dailyUsage: [DailyUsage],
    refreshedAt: Date
) -> SourceUsageSnapshot {
    SourceUsageSnapshot(
        source: source,
        dailyUsage: dailyUsage,
        refreshedAt: refreshedAt,
        usageLimitHistory: history
    )
}

private func quotaHistoryDailyUsageFixture(source: UsageSource) -> [DailyUsage] {
    [DailyUsage(
        day: Calendar.current.startOfDay(for: Date()),
        source: source,
        tokens: TokenBreakdown(input: 1_000, output: 200),
        knownCostMicrosUSD: 0,
        unknownCostEventCount: 0
    )]
}

private func quotaHistorySelectionFixture(source: UsageSource, now: Date) -> [UsageLimitSnapshot] {
    let definitions: [(String, Int, Double)] = [
        (source == .codex ? "codex" : "claude-code", 300, 15),
        (source == .codex ? "codex" : "claude-code", 10_080, 36),
    ]
    return definitions.flatMap { limitID, windowMinutes, startingPercent in
        (0..<8).map { index in
            UsageLimitSnapshot(
                source: source,
                limitID: limitID,
                usedPercent: startingPercent + Double(index),
                windowMinutes: windowMinutes,
                resetsAt: now.addingTimeInterval(Double(windowMinutes) * 60),
                observedAt: now.addingTimeInterval(-Double(7 - index) * 30 * 60),
                resetEpochID: "\(limitID)-fixture"
            )
        }
    }
}
