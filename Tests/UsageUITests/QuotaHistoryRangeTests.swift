import Foundation
import Testing
import UsageDomain
@testable import UsageUI

@Test func quotaHistoryRangesUseExactElapsedIntervals() {
    let expected: [(UsageLimitHistoryRange, TimeInterval)] = [
        (.oneHour, 60 * 60),
        (.sixHours, 6 * 60 * 60),
        (.twelveHours, 12 * 60 * 60),
        (.oneDay, 24 * 60 * 60),
        (.sevenDays, 7 * 24 * 60 * 60),
        (.thirtyDays, 30 * 24 * 60 * 60),
    ]

    #expect(UsageLimitHistoryRange.allCases.map(\.rawValue) == expected.map { $0.0.rawValue })
    for (range, interval) in expected {
        #expect(range.interval == interval)
        #expect(range.localizationKey == "quota_range_\(range.rawValue)")
    }
}

@Test func shortRangesUseTimeAxisAndLongRangesUseDateAxis() {
    #expect(UsageLimitHistoryChartAxis.labelStyle(for: .oneHour) == .time)
    #expect(UsageLimitHistoryChartAxis.labelStyle(for: .sixHours) == .time)
    #expect(UsageLimitHistoryChartAxis.labelStyle(for: .twelveHours) == .time)
    #expect(UsageLimitHistoryChartAxis.labelStyle(for: .oneDay) == .dateAndTime)
    #expect(UsageLimitHistoryChartAxis.labelStyle(for: .sevenDays) == .date)
    #expect(UsageLimitHistoryChartAxis.labelStyle(for: .thirtyDays) == .date)

    let date = Date(timeIntervalSince1970: 1_760_000_000)
    let locale = Locale(identifier: "en_US")
    #expect(UsageLimitHistoryChartAxis.label(for: date, range: .sixHours, locale: locale).contains(":"))
    #expect(!UsageLimitHistoryChartAxis.label(for: date, range: .sevenDays, locale: locale).contains(":"))
}

@Test func chartTicksCoverTheExactSelectedElapsedRange() {
    let now = Date(timeIntervalSince1970: 1_760_000_000)
    for range in UsageLimitHistoryRange.allCases {
        let ticks = UsageLimitHistoryChartAxis.tickDates(for: range, now: now)
        #expect(ticks.first == now.addingTimeInterval(-range.interval))
        #expect(ticks.last == now)
        #expect(ticks == ticks.sorted())
    }
    #expect(UsageLimitHistoryChartAxis.tickDates(for: .oneHour, now: now).count == 3)
    #expect(UsageLimitHistoryChartAxis.tickDates(for: .thirtyDays, now: now).count == 5)
}

@Test func chartIncludesARealOutsideRangePredecessor() {
    let now = Date(timeIntervalSince1970: 1_760_000_000)
    let cutoff = now.addingTimeInterval(-UsageLimitHistoryRange.oneHour.interval)
    let predecessor = quotaRangeObservation(
        observedAt: cutoff.addingTimeInterval(-10 * 60),
        lastObservedAt: cutoff.addingTimeInterval(-5 * 60),
        remaining: 90,
        epoch: "epoch-a"
    )
    let visible = quotaRangeObservation(
        observedAt: cutoff.addingTimeInterval(5 * 60),
        remaining: 80,
        epoch: "epoch-a"
    )
    let bucket = UsageLimitHistoryBucket(visible)

    let table = UsageLimitHistoryTimeline.observations(
        from: [predecessor, visible], source: .codex, bucket: bucket, range: .oneHour, now: now
    )
    let chart = UsageLimitHistoryTimeline.chartObservations(
        from: [predecessor, visible], source: .codex, bucket: bucket, range: .oneHour, now: now
    )

    #expect(table == [visible])
    #expect(chart == [predecessor, visible])
}

@Test func chartRejectsResetRecoveryAndMismatchedSourcePredecessors() {
    let now = Date(timeIntervalSince1970: 1_760_000_000)
    let cutoff = now.addingTimeInterval(-UsageLimitHistoryRange.oneHour.interval)
    let visible = quotaRangeObservation(
        observedAt: cutoff.addingTimeInterval(5 * 60), remaining: 80, epoch: "epoch-a"
    )
    let bucket = UsageLimitHistoryBucket(visible)
    let outside: (TimeInterval, Double, String?, UsageSource) -> UsageLimitSnapshot = { offset, remaining, epoch, source in
        quotaRangeObservation(
            source: source,
            observedAt: cutoff.addingTimeInterval(offset),
            lastObservedAt: cutoff.addingTimeInterval(offset + 60),
            remaining: remaining,
            epoch: epoch
        )
    }
    let cases = [
        outside(-10 * 60, 90, "epoch-b", .codex), // reset epoch changed
        outside(-10 * 60, 70, "epoch-a", .codex), // remaining quota recovered
        outside(-10 * 60, 90, "epoch-a", .claudeCode),
    ]

    for predecessor in cases {
        let chart = UsageLimitHistoryTimeline.chartObservations(
            from: [predecessor, visible], source: .codex, bucket: bucket, range: .oneHour, now: now
        )
        #expect(chart == [visible])
    }
}

@Test func chartIncludesOutsidePredecessorAcrossLongGapWithoutAddingTableRows() {
    let now = Date(timeIntervalSince1970: 1_760_000_000)
    let cutoff = now.addingTimeInterval(-UsageLimitHistoryRange.oneHour.interval)
    let predecessor = quotaRangeObservation(
        observedAt: cutoff.addingTimeInterval(-40 * 60), remaining: 90, epoch: "same"
    )
    let visible = quotaRangeObservation(
        observedAt: cutoff.addingTimeInterval(10 * 60), remaining: 80, epoch: "same"
    )
    let bucket = UsageLimitHistoryBucket(visible)
    let history = [predecessor, visible]
    #expect(UsageLimitHistoryTimeline.chartObservations(
        from: history, source: .codex, bucket: bucket, range: .oneHour, now: now
    ) == history)
    #expect(UsageLimitHistoryTimeline.observations(
        from: history, source: .codex, bucket: bucket, range: .oneHour, now: now
    ) == [visible])
    // Display interpolation must not redefine measured continuity.
    #expect(UsageLimitHistoryTimeline.segments(history).count == 2)
}

@Test func chartCanShowLatestValueReferenceWithNoObservationInsideRange() {
    let now = Date(timeIntervalSince1970: 1_760_000_000)
    let previous = quotaRangeObservation(
        observedAt: now.addingTimeInterval(-90 * 60), remaining: 80
    )
    let bucket = UsageLimitHistoryBucket(previous)
    #expect(UsageLimitHistoryTimeline.chartObservations(
        from: [previous], source: .codex, bucket: bucket, range: .oneHour, now: now
    ) == [previous])
    #expect(UsageLimitHistoryTimeline.buckets(
        from: [previous], source: .codex, range: .oneHour, now: now
    ) == [bucket])
    #expect(UsageLimitHistoryTimeline.observations(
        from: [previous], source: .codex, bucket: bucket, range: .oneHour, now: now
    ).isEmpty)
}

@Test func chartIncludesSameResetPredecessorWithGapGeneratedEpochID() {
    let now = Date(timeIntervalSince1970: 1_760_000_000)
    let reset = now.addingTimeInterval(6 * 24 * 60 * 60)
    let history = [(-100 * 60.0, "before-gap"), (-10 * 60.0, "after-gap")].map { offset, epoch in
        UsageLimitSnapshot(
            source: .codex, limitID: "codex", usedPercent: 44, windowMinutes: 10_080,
            resetsAt: reset, observedAt: now.addingTimeInterval(offset), resetEpochID: epoch
        )
    }
    let bucket = UsageLimitHistoryBucket(history[0])
    #expect(UsageLimitHistoryTimeline.chartObservations(
        from: history, source: .codex, bucket: bucket, range: .oneHour, now: now
    ) == history)
    #expect(UsageLimitHistoryTimeline.observations(
        from: history, source: .codex, bucket: bucket, range: .oneHour, now: now
    ) == [history[1]])
}

@Test func chartKeepsRealBoundaryEndpointsAndDoesNotExtrapolateToNow() throws {
    let now = Date(timeIntervalSince1970: 1_760_000_000)
    let cutoff = now.addingTimeInterval(-UsageLimitHistoryRange.oneHour.interval)
    let crossing = quotaRangeObservation(
        observedAt: cutoff.addingTimeInterval(-10 * 60),
        lastObservedAt: cutoff.addingTimeInterval(10 * 60),
        remaining: 80
    )
    let bucket = UsageLimitHistoryBucket(crossing)
    let chart = UsageLimitHistoryTimeline.chartObservations(
        from: [crossing], source: .codex, bucket: bucket, range: .oneHour, now: now
    )
    let displayed = try #require(
        UsageLimitHistoryTimeline.displayedInterval(for: crossing, range: .oneHour, now: now)
    )

    #expect(chart == [crossing])
    #expect(chart[0].observedAt == cutoff.addingTimeInterval(-10 * 60))
    #expect(displayed.lowerBound == cutoff)
    #expect(chart[0].lastObservedAt == cutoff.addingTimeInterval(10 * 60))
    #expect(chart[0].lastObservedAt < now)
}

private func quotaRangeObservation(
    source: UsageSource = .codex,
    observedAt: Date,
    lastObservedAt: Date? = nil,
    remaining: Double,
    epoch: String? = nil
) -> UsageLimitSnapshot {
    UsageLimitSnapshot(
        source: source,
        limitID: "codex",
        usedPercent: 100 - remaining,
        windowMinutes: 300,
        resetsAt: nil,
        observedAt: observedAt,
        lastObservedAt: lastObservedAt,
        resetEpochID: epoch
    )
}
