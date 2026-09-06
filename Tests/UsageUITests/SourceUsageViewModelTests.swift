import Foundation
import Testing
import UsageDomain
@testable import UsageUI

@MainActor
@Test func recentCostSummaryIncludesExactlyThirtyDaysAcrossMonthBoundary() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let through = calendar.date(from: DateComponents(year: 2026, month: 8, day: 15))!
    let viewModel = SourceUsageViewModel(source: .codex, calendar: calendar)

    viewModel.apply(.ready(SourceUsageSnapshot(
        source: .codex,
        dailyUsage: [
            usage(year: 2026, month: 7, day: 16, cost: 900_000, calendar: calendar),
            usage(year: 2026, month: 7, day: 17, cost: 1_250_000, calendar: calendar),
            usage(year: 2026, month: 8, day: 15, cost: 2_500_000, unknown: 2, calendar: calendar),
            usage(year: 2026, month: 8, day: 16, cost: 8_000_000, calendar: calendar),
        ]
    )))

    let summary = viewModel.costSummary(lastDays: 30, through: through)
    #expect(summary.knownCostMicrosUSD == 3_750_000)
    #expect(summary.unknownCostEventCount == 2)
}

@MainActor
@Test func codexModelUsageUsesStableCapabilityOrderInsteadOfTokenCount() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let day = calendar.date(from: DateComponents(year: 2026, month: 8, day: 15))!
    let viewModel = SourceUsageViewModel(source: .codex, calendar: calendar)
    viewModel.apply(.ready(SourceUsageSnapshot(
        source: .codex,
        dailyUsage: [],
        dailyModelUsage: [
            DailyModelUsage(day: day, source: .codex, model: nil, tokens: .init(input: 999)),
            DailyModelUsage(day: day, source: .codex, model: "gpt-5.6-luna", tokens: .init(input: 900)),
            DailyModelUsage(day: day, source: .codex, model: "gpt-5.6-terra", tokens: .init(input: 800)),
            DailyModelUsage(day: day, source: .codex, model: "gpt-5.5", tokens: .init(input: 1)),
            DailyModelUsage(day: day, source: .codex, model: "gpt-5.6-sol", tokens: .init(input: 2)),
            DailyModelUsage(day: day, source: .codex, model: "codex-auto-review", tokens: .init(input: 700)),
            DailyModelUsage(day: day, source: .claudeCode, model: "other", tokens: .init(input: 99)),
        ]
    )))

    #expect(viewModel.modelUsage(on: day).map(\.model) == [
        "gpt-5.6-sol",
        "gpt-5.5",
        "gpt-5.6-terra",
        "gpt-5.6-luna",
        "codex-auto-review",
        nil,
    ])
}

@MainActor
@Test func claudeModelUsageOrdersOpusThenSonnetThenHaikuAndNewestFirst() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let day = calendar.date(from: DateComponents(year: 2026, month: 8, day: 15))!
    let viewModel = SourceUsageViewModel(source: .claudeCode, calendar: calendar)
    viewModel.apply(.ready(SourceUsageSnapshot(
        source: .claudeCode,
        dailyUsage: [],
        dailyModelUsage: [
            DailyModelUsage(day: day, source: .claudeCode, model: "claude-haiku-4-5-20251001", tokens: .init(input: 100)),
            DailyModelUsage(day: day, source: .claudeCode, model: "claude-sonnet-4-5-20250929", tokens: .init(input: 90)),
            DailyModelUsage(day: day, source: .claudeCode, model: "claude-opus-4-5-20251101", tokens: .init(input: 1)),
            DailyModelUsage(day: day, source: .claudeCode, model: "claude-sonnet-4-6", tokens: .init(input: 2)),
            DailyModelUsage(day: day, source: .claudeCode, model: "claude-opus-4-6", tokens: .init(input: 3)),
        ]
    )))

    #expect(viewModel.modelUsage(on: day).compactMap(\.model) == [
        "claude-opus-4-6",
        "claude-opus-4-5-20251101",
        "claude-sonnet-4-6",
        "claude-sonnet-4-5-20250929",
        "claude-haiku-4-5-20251001",
    ])
}

@Test func popoverHeightExpandsForAdditionalModelRows() {
    let day = Date(timeIntervalSince1970: 1_700_000_000)
    let makeUsage: (Int) -> DailyModelUsage = { index in
        DailyModelUsage(
            day: day,
            source: .codex,
            model: "model-\(index)",
            tokens: .init(input: 1)
        )
    }

    #expect(SourceUsagePopoverSizing.contentHeight(for: []) == 566)
    #expect(SourceUsagePopoverSizing.contentHeight(for: (0..<4).map(makeUsage)) == 566)
    #expect(SourceUsagePopoverSizing.contentHeight(for: (0..<5).map(makeUsage)) == 604)
    #expect(SourceUsagePopoverSizing.modelSectionHeight(for: (0..<5).map(makeUsage)) == 89)
    #expect(SourceUsagePopoverSizing.contentHeight(for: (0..<9).map(makeUsage)) == 642)
}

@MainActor
@Test func latestQuotaHistoryReplacesPriorHistoryAfterRefresh() async {
    let initial = Date(timeIntervalSince1970: 1_760_000_000)
    let latest = initial.addingTimeInterval(60)
    let viewModel = SourceUsageViewModel(source: .codex, loader: {
        .ready(SourceUsageSnapshot(
            source: .codex,
            dailyUsage: [],
            usageLimitHistory: [quota(observedAt: latest, remaining: 72)]
        ))
    })

    viewModel.apply(.ready(SourceUsageSnapshot(
        source: .codex,
        dailyUsage: [],
        usageLimitHistory: [quota(observedAt: initial, remaining: 81)]
    )))
    await viewModel.refresh()

    #expect(viewModel.usageLimitHistory == [quota(observedAt: latest, remaining: 72)])
}

@MainActor
@Test func quotaHistoryIsClearedForMismatchedSnapshotSource() {
    let viewModel = SourceUsageViewModel(source: .codex)
    viewModel.apply(.ready(SourceUsageSnapshot(
        source: .claudeCode,
        dailyUsage: [],
        usageLimitHistory: [quota(source: .claudeCode)]
    )))

    #expect(viewModel.usageLimitHistory.isEmpty)
    #expect(viewModel.phase == .unavailable(reason: L10n.text("source_mismatch")))
}

@Test func quotaHistoryFiltersActualDateRangeAndNeverFutureObservations() throws {
    let now = Date(timeIntervalSince1970: 1_760_000_000)
    let bucket = UsageLimitHistoryBucket(quota(observedAt: now))
    let history = [
        quota(observedAt: now.addingTimeInterval(-(7 * 24 * 60 * 60))),
        quota(observedAt: now.addingTimeInterval(-(7 * 24 * 60 * 60) - 1)),
        quota(observedAt: now.addingTimeInterval(-60)),
        quota(observedAt: now.addingTimeInterval(1)),
    ]
    let crossingRun = quota(
        observedAt: now.addingTimeInterval(-(7 * 24 * 60 * 60) - 60),
        lastObservedAt: now.addingTimeInterval(-(7 * 24 * 60 * 60) + 60)
    )
    let futureConfirmation = quota(
        observedAt: now.addingTimeInterval(-60),
        lastObservedAt: now.addingTimeInterval(1)
    )

    let filtered = UsageLimitHistoryTimeline.observations(
        from: [crossingRun] + history + [futureConfirmation],
        source: .codex,
        bucket: bucket,
        range: .sevenDays,
        now: now
    )

    #expect(filtered.map(\.observedAt) == [crossingRun.observedAt, history[0].observedAt, history[2].observedAt])
    let interval = try #require(UsageLimitHistoryTimeline.displayedInterval(for: crossingRun, range: .sevenDays, now: now))
    #expect(interval.lowerBound == now.addingTimeInterval(-(7 * 24 * 60 * 60)))
    #expect(UsageLimitHistoryTimeline.displayedInterval(for: futureConfirmation, range: .sevenDays, now: now) == nil)
}

@Test func quotaHistorySeparatesSourcesBucketsAndWindows() {
    let now = Date(timeIntervalSince1970: 1_760_000_000)
    let generalFiveHour = quota(limitID: "codex", windowMinutes: 300, observedAt: now)
    let modelFiveHour = quota(limitID: "gpt-5.6-sol", windowMinutes: 300, observedAt: now)
    let generalWeek = quota(limitID: "codex", windowMinutes: 10_080, observedAt: now)
    let claude = quota(source: .claudeCode, observedAt: now)
    let buckets = UsageLimitHistoryTimeline.buckets(
        from: [generalFiveHour, modelFiveHour, generalWeek, claude],
        source: .codex,
        range: .sevenDays,
        now: now
    )

    #expect(Set(buckets) == Set([
        UsageLimitHistoryBucket(generalFiveHour),
        UsageLimitHistoryBucket(modelFiveHour),
        UsageLimitHistoryBucket(generalWeek),
    ]))
    #expect(UsageLimitHistoryTimeline.preferredBucket(in: buckets) == UsageLimitHistoryBucket(generalWeek))
}

@Test func quotaHistoryChartBreaksForGapsResetChangesAndRecoveries() {
    let origin = Date(timeIntervalSince1970: 1_760_000_000)
    let reset = origin.addingTimeInterval(10_000)
    let observations = [
        quota(observedAt: origin, resetsAt: reset, remaining: 90),
        quota(observedAt: origin.addingTimeInterval(60), resetsAt: reset, remaining: 80),
        quota(observedAt: origin.addingTimeInterval(60 * 32), resetsAt: reset, remaining: 70),
        quota(observedAt: origin.addingTimeInterval(60 * 33), resetsAt: origin.addingTimeInterval(20_000), remaining: 65),
        quota(observedAt: origin.addingTimeInterval(60 * 34), resetsAt: origin.addingTimeInterval(20_000), remaining: 75),
    ]

    #expect(UsageLimitHistoryTimeline.segments(observations).map(\.count) == [2, 1, 1, 1])
}

@Test func quotaHistoryUsesEpochIDsAndOnlyToleratesOneSecondForLegacyResetTimes() {
    let origin = Date(timeIntervalSince1970: 1_760_000_000)
    let reset = origin.addingTimeInterval(10_000)
    let observations = [
        quota(observedAt: origin, resetsAt: reset, resetEpochID: "epoch-a"),
        quota(observedAt: origin.addingTimeInterval(60), resetsAt: reset.addingTimeInterval(10), resetEpochID: "epoch-a"),
        quota(observedAt: origin.addingTimeInterval(120), resetsAt: reset.addingTimeInterval(11), resetEpochID: "epoch-b"),
        quota(observedAt: origin.addingTimeInterval(180), resetsAt: reset.addingTimeInterval(12)),
        quota(observedAt: origin.addingTimeInterval(240), resetsAt: reset.addingTimeInterval(13)),
        quota(observedAt: origin.addingTimeInterval(300), resetsAt: reset.addingTimeInterval(15)),
    ]

    #expect(UsageLimitHistoryTimeline.segments(observations).map(\.count) == [2, 1, 2, 1])
}

@Test func legacyResetJitterCannotDriftAcrossAnEntireSegment() {
    let origin = Date(timeIntervalSince1970: 1_760_000_000)
    let observations = [
        quota(observedAt: origin, resetsAt: origin.addingTimeInterval(54)),
        quota(observedAt: origin.addingTimeInterval(60), resetsAt: origin.addingTimeInterval(55)),
        quota(observedAt: origin.addingTimeInterval(120), resetsAt: origin.addingTimeInterval(56)),
    ]

    #expect(UsageLimitHistoryTimeline.segments(observations).map(\.count) == [2, 1])
}

@Test func quotaHistoryUsesRunEndForGapDetection() {
    let origin = Date(timeIntervalSince1970: 1_760_000_000)
    let observations = [
        quota(observedAt: origin, lastObservedAt: origin.addingTimeInterval(29 * 60)),
        quota(observedAt: origin.addingTimeInterval(59 * 60)),
        quota(observedAt: origin.addingTimeInterval(89 * 60 + 1)),
    ]

    #expect(UsageLimitHistoryTimeline.segments(observations).map(\.count) == [2, 1])
}

@Test func quotaHistoryHasEmptyStateForAbsentOrOutOfPeriodObservations() {
    let now = Date(timeIntervalSince1970: 1_760_000_000)
    let old = quota(observedAt: now.addingTimeInterval(-(31 * 24 * 60 * 60)))
    #expect(UsageLimitHistoryTimeline.buckets(from: [], source: .codex, range: .sevenDays, now: now).isEmpty)
    #expect(UsageLimitHistoryTimeline.buckets(from: [old], source: .codex, range: .thirtyDays, now: now).isEmpty)
}

private func quota(
    source: UsageSource = .codex,
    limitID: String = "codex",
    windowMinutes: Int = 300,
    observedAt: Date = Date(timeIntervalSince1970: 1_760_000_000),
    lastObservedAt: Date? = nil,
    resetsAt: Date? = nil,
    resetEpochID: String? = nil,
    remaining: Double = 80
) -> UsageLimitSnapshot {
    UsageLimitSnapshot(
        source: source,
        limitID: limitID,
        usedPercent: 100 - remaining,
        windowMinutes: windowMinutes,
        resetsAt: resetsAt,
        observedAt: observedAt,
        lastObservedAt: lastObservedAt,
        resetEpochID: resetEpochID
    )
}

private func usage(
    year: Int,
    month: Int,
    day: Int,
    cost: Int64,
    unknown: Int = 0,
    calendar: Calendar
) -> DailyUsage {
    DailyUsage(
        day: calendar.date(from: DateComponents(year: year, month: month, day: day))!,
        source: .codex,
        tokens: .zero,
        knownCostMicrosUSD: cost,
        unknownCostEventCount: unknown
    )
}
