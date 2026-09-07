import Foundation
import Testing
import UsageDomain
@testable import UsageUI

@Test func quotaHistorySeriesShowsConfirmedRunsAndDots() {
    let now = Date(timeIntervalSince1970: 1_760_000_000)
    let run = seriesQuota(
        observedAt: now.addingTimeInterval(-20 * 60),
        lastObservedAt: now.addingTimeInterval(-10 * 60),
        remaining: 80
    )

    let series = UsageLimitHistoryChartSeries.make(observations: [run], range: .oneHour, now: now)

    #expect(series.strokes == [
        seriesStroke(run.observedAt, run.lastObservedAt, 80, 80, .observed),
        seriesStroke(run.lastObservedAt, now, 80, 80, .extended),
    ])
    #expect(series.observations == [
        UsageLimitHistoryChartSeries.Point(date: run.observedAt, remainingPercent: 80),
        UsageLimitHistoryChartSeries.Point(date: run.lastObservedAt, remainingPercent: 80),
    ])
}

@Test func quotaHistorySeriesInterpolatesLongConfirmedGap() {
    let now = Date(timeIntervalSince1970: 1_760_000_000)
    let first = seriesQuota(observedAt: now.addingTimeInterval(-50 * 60), remaining: 90, epoch: "epoch-a")
    let second = seriesQuota(observedAt: now.addingTimeInterval(-5 * 60), remaining: 70, epoch: "epoch-a")

    let series = UsageLimitHistoryChartSeries.make(observations: [first, second], range: .oneHour, now: now)

    #expect(series.strokes == [
        seriesStroke(first.lastObservedAt, second.observedAt, 90, 70, .interpolated),
        seriesStroke(second.lastObservedAt, now, 70, 70, .extended),
    ])
}

@Test func quotaHistorySeriesBridgesEpochIDsCreatedByReportingGaps() {
    let now = Date(timeIntervalSince1970: 1_760_000_000)
    let reset = now.addingTimeInterval(6 * 24 * 60 * 60)
    let history = [
        seriesQuota(observedAt: now.addingTimeInterval(-4 * 60 * 60 - 240),
                    lastObservedAt: now.addingTimeInterval(-4 * 60 * 60),
                    remaining: 56, reset: reset, epoch: "before-gap"),
        seriesQuota(observedAt: now.addingTimeInterval(-100 * 60),
                    lastObservedAt: now.addingTimeInterval(-97 * 60),
                    remaining: 56, reset: reset, epoch: "after-first-gap"),
        seriesQuota(observedAt: now.addingTimeInterval(-10 * 60),
                    lastObservedAt: now.addingTimeInterval(-2 * 60),
                    remaining: 56, reset: reset, epoch: "after-second-gap"),
    ]
    let series = UsageLimitHistoryChartSeries.make(observations: history, range: .sixHours, now: now)
    for (previous, next) in zip(history, history.dropFirst()) {
        #expect(series.strokes.contains(seriesStroke(
            previous.lastObservedAt, next.observedAt, 56, 56, .interpolated
        )))
    }
    // Storage epoch breaks still define measured continuity for token pace.
    #expect(UsageLimitHistoryTimeline.segments(history).count == 3)
}

@Test func storageGapBridgeRequiresMatchingKnownResetWithoutRecovery() {
    let now = Date(timeIntervalSince1970: 1_760_000_000)
    let reset = now.addingTimeInterval(6 * 24 * 60 * 60)
    let previous = seriesQuota(observedAt: now.addingTimeInterval(-50 * 60), remaining: 56,
                               reset: reset, epoch: "before-gap")
    let changedReset = seriesQuota(observedAt: now.addingTimeInterval(-5 * 60), remaining: 56,
                                   reset: reset.addingTimeInterval(15), epoch: "real-reset-change")
    let recovered = seriesQuota(observedAt: now.addingTimeInterval(-5 * 60), remaining: 57,
                                reset: reset, epoch: "recovered")
    let unknownReset = seriesQuota(observedAt: now.addingTimeInterval(-5 * 60), remaining: 56,
                                   epoch: "unknown-reset")
    for next in [changedReset, recovered, unknownReset] {
        let series = UsageLimitHistoryChartSeries.make(observations: [previous, next], range: .oneHour, now: now)
        #expect(!series.strokes.contains { $0.style == .interpolated })
    }
}

@Test func quotaHistorySeriesDoesNotJoinDiscontinuousRuns() {
    let now = Date(timeIntervalSince1970: 1_760_000_000)
    let base = now.addingTimeInterval(-50 * 60)
    let sameEpochReset = base.addingTimeInterval(15 * 60)
    let resetWithinGap = [
        seriesQuota(observedAt: base, remaining: 90, reset: sameEpochReset, epoch: "epoch-a"),
        seriesQuota(observedAt: base.addingTimeInterval(30 * 60), remaining: 70, reset: sameEpochReset, epoch: "epoch-a"),
    ]
    let recovery = [
        seriesQuota(observedAt: base, remaining: 70, epoch: "epoch-a"),
        seriesQuota(observedAt: base.addingTimeInterval(10 * 60), remaining: 90, epoch: "epoch-a"),
    ]
    let resetAtEndpoint = [
        seriesQuota(observedAt: base, remaining: 90, reset: base.addingTimeInterval(30 * 60), epoch: "epoch-a"),
        seriesQuota(observedAt: base.addingTimeInterval(30 * 60), remaining: 70, reset: base.addingTimeInterval(30 * 60), epoch: "epoch-a"),
    ]
    let changedEpoch = [
        seriesQuota(observedAt: base, remaining: 90, epoch: "epoch-a"),
        seriesQuota(observedAt: base.addingTimeInterval(30 * 60), remaining: 70, epoch: "epoch-b"),
    ]
    let changedSource = [
        seriesQuota(observedAt: base, remaining: 90, epoch: "epoch-a"),
        seriesQuota(source: .claudeCode, observedAt: base.addingTimeInterval(10 * 60), remaining: 70, epoch: "epoch-a"),
    ]
    let changedBucket = [
        seriesQuota(observedAt: base, remaining: 90, epoch: "epoch-a"),
        seriesQuota(windowMinutes: 60, observedAt: base.addingTimeInterval(10 * 60), remaining: 70, epoch: "epoch-a"),
    ]
    let legacyDrift = [
        seriesQuota(observedAt: base, remaining: 90, reset: base.addingTimeInterval(40 * 60)),
        seriesQuota(observedAt: base.addingTimeInterval(5 * 60), remaining: 80, reset: base.addingTimeInterval(40 * 60 + 1)),
        seriesQuota(observedAt: base.addingTimeInterval(10 * 60), remaining: 70, reset: base.addingTimeInterval(40 * 60 + 2)),
    ]

    for observations in [resetWithinGap, resetAtEndpoint, changedEpoch, recovery, changedSource, changedBucket] {
        let styles = UsageLimitHistoryChartSeries.make(observations: observations, range: .oneHour, now: now)
            .strokes.map(\.style)
        #expect(!styles.contains(.interpolated))
    }

    let legacy = UsageLimitHistoryChartSeries.make(observations: legacyDrift, range: .oneHour, now: now)
    #expect(legacy.strokes.contains(seriesStroke(
        legacyDrift[0].lastObservedAt, legacyDrift[1].observedAt, 90, 80, .interpolated
    )))
    #expect(!legacy.strokes.contains(seriesStroke(
        legacyDrift[1].lastObservedAt, legacyDrift[2].observedAt, 80, 70, .interpolated
    )))
}

@Test func quotaHistorySeriesKeepsRealLeftEndpointsWithoutBoundaryDots() {
    let now = Date(timeIntervalSince1970: 1_760_000_000)
    let cutoff = now.addingTimeInterval(-60 * 60)
    let before = seriesQuota(observedAt: cutoff.addingTimeInterval(-10 * 60), remaining: 90, epoch: "epoch-a")
    let inside = seriesQuota(observedAt: cutoff.addingTimeInterval(5 * 60), remaining: 70, epoch: "epoch-a")

    let series = UsageLimitHistoryChartSeries.make(observations: [before, inside], range: .oneHour, now: now)

    #expect(series.strokes == [
        seriesStroke(before.lastObservedAt, inside.observedAt, 90, 70, .interpolated),
        seriesStroke(inside.lastObservedAt, now, 70, 70, .extended),
    ])
    #expect(!series.observations.contains { $0.date == cutoff })
    #expect(series.observations == [UsageLimitHistoryChartSeries.Point(date: inside.observedAt, remainingPercent: 70)])

    let solePredecessor = UsageLimitHistoryChartSeries.make(
        observations: [before], range: .oneHour, now: now
    )
    #expect(solePredecessor.strokes == [seriesStroke(before.lastObservedAt, now, 90, 90, .extended)])
    #expect(solePredecessor.observations.isEmpty)
}

@Test func quotaHistorySeriesExtendsLatestPointOnlyForwardUntilReset() {
    let now = Date(timeIntervalSince1970: 1_760_000_000)
    let point = seriesQuota(observedAt: now.addingTimeInterval(-20 * 60), remaining: 80, reset: now.addingTimeInterval(-5 * 60))
    let expired = seriesQuota(observedAt: now.addingTimeInterval(-10 * 60), remaining: 60, reset: now.addingTimeInterval(-15 * 60))
    let invalidReset = seriesQuota(
        observedAt: now.addingTimeInterval(-10 * 60),
        remaining: 60,
        reset: Date(timeIntervalSinceReferenceDate: .infinity)
    )

    let extending = UsageLimitHistoryChartSeries.make(observations: [point], range: .oneHour, now: now)
    let expiredReset = UsageLimitHistoryChartSeries.make(observations: [expired], range: .oneHour, now: now)
    let nonFiniteReset = UsageLimitHistoryChartSeries.make(observations: [invalidReset], range: .oneHour, now: now)

    #expect(extending.strokes == [seriesStroke(point.lastObservedAt, now.addingTimeInterval(-5 * 60), 80, 80, .extended)])
    #expect(expiredReset.strokes.isEmpty)
    #expect(nonFiniteReset.strokes.isEmpty)
    #expect(!extending.strokes.contains { $0.start.date < point.observedAt })
}

@Test func quotaHistorySeriesExcludesInvalidAndFutureSamples() {
    let now = Date(timeIntervalSince1970: 1_760_000_000)
    let valid = seriesQuota(observedAt: now.addingTimeInterval(-10 * 60), remaining: 80)
    let future = seriesQuota(observedAt: now.addingTimeInterval(1), remaining: 50)
    let nonFinite = seriesQuota(observedAt: Date(timeIntervalSinceReferenceDate: .infinity), remaining: 60)
    let futureConfirmation = seriesQuota(
        observedAt: now.addingTimeInterval(-5 * 60),
        lastObservedAt: now.addingTimeInterval(1),
        remaining: 60
    )

    let series = UsageLimitHistoryChartSeries.make(
        observations: [valid, future, nonFinite, futureConfirmation], range: .oneHour, now: now
    )

    #expect(series.observations == [UsageLimitHistoryChartSeries.Point(date: valid.observedAt, remainingPercent: 80)])
    #expect(series.strokes == [seriesStroke(valid.lastObservedAt, now, 80, 80, .extended)])
}

private func seriesQuota(
    source: UsageSource = .codex,
    windowMinutes: Int = 300,
    observedAt: Date,
    lastObservedAt: Date? = nil,
    remaining: Double,
    reset: Date? = nil,
    epoch: String? = nil
) -> UsageLimitSnapshot {
    UsageLimitSnapshot(
        source: source,
        limitID: "codex",
        usedPercent: 100 - remaining,
        windowMinutes: windowMinutes,
        resetsAt: reset,
        observedAt: observedAt,
        lastObservedAt: lastObservedAt,
        resetEpochID: epoch
    )
}

private func seriesStroke(
    _ start: Date,
    _ end: Date,
    _ startRemaining: Double,
    _ endRemaining: Double,
    _ style: UsageLimitHistoryChartSeries.Style
) -> UsageLimitHistoryChartSeries.Stroke {
    UsageLimitHistoryChartSeries.Stroke(
        start: .init(date: start, remainingPercent: startRemaining),
        end: .init(date: end, remainingPercent: endRemaining),
        style: style
    )
}
