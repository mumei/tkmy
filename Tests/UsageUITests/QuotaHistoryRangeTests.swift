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

@Test func chartIncludesOnlyAContinuousOutsideRangePredecessor() {
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

@Test func chartRejectsDisconnectedResetRecoveryAndMismatchedSourcePredecessors() {
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
        outside(-40 * 60, 90, "epoch-a", .codex), // >30-minute confirmation gap
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
