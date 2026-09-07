import Foundation
import UsageDomain

/// The time range selected in the remaining-quota history pane.
enum UsageLimitHistoryRange: String, CaseIterable, Identifiable, Hashable {
    case oneHour = "1h"
    case sixHours = "6h"
    case twelveHours = "12h"
    case oneDay = "1d"
    case sevenDays = "7d"
    case thirtyDays = "30d"

    var id: String { rawValue }

    var localizationKey: String { "quota_range_\(rawValue)" }

    /// These are elapsed seconds, rather than calendar periods. A 24-hour
    /// range therefore stays 24 hours long across a daylight-saving change.
    var interval: TimeInterval {
        switch self {
        case .oneHour: 60 * 60
        case .sixHours: 6 * 60 * 60
        case .twelveHours: 12 * 60 * 60
        case .oneDay: 24 * 60 * 60
        case .sevenDays: 7 * 24 * 60 * 60
        case .thirtyDays: 30 * 24 * 60 * 60
        }
    }
}

struct UsageLimitHistoryBucket: Hashable, Identifiable {
    let limitID: String
    let windowMinutes: Int

    init(_ observation: UsageLimitSnapshot) {
        limitID = observation.limitID
        windowMinutes = observation.windowMinutes
    }

    var id: String { "\(limitID)|\(windowMinutes)" }
}

enum UsageLimitHistoryTimeline {
    /// Gaps beyond 30 minutes break measured continuity. Chart-only reference
    /// connections do not change this limit for consumption calculations.
    static let maximumConnectedGap = UsageLimitHistoryPolicy.maximumContinuousGap

    static func observations(
        from history: [UsageLimitSnapshot],
        source: UsageSource,
        bucket: UsageLimitHistoryBucket,
        range: UsageLimitHistoryRange,
        now: Date
    ) -> [UsageLimitSnapshot] {
        return history
            .filter {
                $0.source == source
                    && UsageLimitHistoryBucket($0) == bucket
                    && intersectsDisplayedRange($0, range: range, now: now)
            }
            .sorted { $0.observedAt < $1.observedAt }
    }

    /// Returns the chart's in-range observations and a compatible real sample
    /// immediately before the selected range, including across a missing span.
    /// The table deliberately uses `observations` instead, so this predecessor
    /// is never presented as an in-range row.
    static func chartObservations(
        from history: [UsageLimitSnapshot],
        source: UsageSource,
        bucket: UsageLimitHistoryBucket,
        range: UsageLimitHistoryRange,
        now: Date
    ) -> [UsageLimitSnapshot] {
        let visible = observations(
            from: history,
            source: source,
            bucket: bucket,
            range: range,
            now: now
        )
        let cutoff = now.addingTimeInterval(-range.interval)
        let relevant = history
            .filter {
                $0.source == source
                    && UsageLimitHistoryBucket($0) == bucket
                    && isFiniteConfirmedRun($0, through: now)
            }
            .sorted { lhs, rhs in
                if lhs.observedAt != rhs.observedAt { return lhs.observedAt < rhs.observedAt }
                return lhs.lastObservedAt < rhs.lastObservedAt
            }
        guard let firstVisible = visible.first else {
            guard let latest = relevant.last,
                  !UsageLimitHistoryChartSeries.make(
                      observations: [latest], range: range, now: now
                  ).strokes.isEmpty else { return [] }
            return [latest]
        }
        guard let firstVisibleIndex = relevant.firstIndex(of: firstVisible), firstVisibleIndex > 0 else {
            return visible
        }

        let predecessor = relevant[firstVisibleIndex - 1]
        guard predecessor.lastObservedAt < cutoff,
              canConnect(predecessor, to: firstVisible, maximumGap: .infinity) else {
            return visible
        }
        return [predecessor] + visible
    }

    static func buckets(
        from history: [UsageLimitSnapshot],
        source: UsageSource,
        range: UsageLimitHistoryRange,
        now: Date
    ) -> [UsageLimitHistoryBucket] {
        let candidates = Set(history.compactMap { observation -> UsageLimitHistoryBucket? in
            guard observation.source == source,
                  isFiniteConfirmedRun(observation, through: now) else { return nil }
            return UsageLimitHistoryBucket(observation)
        })
        return candidates.filter {
            !chartObservations(from: history, source: source, bucket: $0, range: range, now: now).isEmpty
        }
        .sorted { lhs, rhs in
            if lhs.windowMinutes != rhs.windowMinutes { return lhs.windowMinutes < rhs.windowMinutes }
            return lhs.limitID.localizedStandardCompare(rhs.limitID) == .orderedAscending
        }
    }

    static func displayedInterval(
        for observation: UsageLimitSnapshot,
        range: UsageLimitHistoryRange,
        now: Date
    ) -> ClosedRange<Date>? {
        guard isFiniteConfirmedRun(observation, through: now) else { return nil }
        let cutoff = now.addingTimeInterval(-range.interval)
        let start = max(observation.observedAt, cutoff)
        let end = observation.lastObservedAt
        guard start <= end else { return nil }
        return start...end
    }

    static func preferredBucket(in buckets: [UsageLimitHistoryBucket]) -> UsageLimitHistoryBucket? {
        // The existing menu meter reports Codex's general (usually weekly) limit.
        // Prefer that familiar window before exposing more specific model limits.
        buckets
            .filter { $0.limitID.lowercased() == "codex" }
            .max { $0.windowMinutes < $1.windowMinutes }
            ?? buckets.max { $0.windowMinutes < $1.windowMinutes }
    }

    static func segments(
        _ observations: [UsageLimitSnapshot],
        maximumGap: TimeInterval = maximumConnectedGap
    ) -> [[UsageLimitSnapshot]] {
        var result: [[UsageLimitSnapshot]] = []
        var resetState: SegmentResetState?

        for observation in observations.sorted(by: { $0.observedAt < $1.observedAt }) {
            guard let previous = result.last?.last,
                  canConnectIgnoringLegacyEpochHistory(previous, to: observation, maximumGap: maximumGap),
                  resetState?.canContinue(with: observation) == true,
                  observation.remainingPercent <= previous.remainingPercent else {
                result.append([observation])
                resetState = SegmentResetState(observation)
                continue
            }
            result[result.count - 1].append(observation)
            resetState?.append(observation)
        }
        return result
    }

    private static func intersectsDisplayedRange(
        _ observation: UsageLimitSnapshot,
        range: UsageLimitHistoryRange,
        now: Date
    ) -> Bool {
        displayedInterval(for: observation, range: range, now: now) != nil
    }

    private static func isFiniteConfirmedRun(_ observation: UsageLimitSnapshot, through now: Date) -> Bool {
        observation.observedAt.timeIntervalSinceReferenceDate.isFinite
            && observation.lastObservedAt.timeIntervalSinceReferenceDate.isFinite
            && observation.observedAt <= observation.lastObservedAt
            && observation.lastObservedAt <= now
    }

    private static func canConnect(
        _ previous: UsageLimitSnapshot,
        to candidate: UsageLimitSnapshot,
        maximumGap: TimeInterval = maximumConnectedGap
    ) -> Bool {
        guard canConnectIgnoringLegacyEpochHistory(previous, to: candidate, maximumGap: maximumGap),
              candidate.remainingPercent <= previous.remainingPercent else { return false }

        if let epochID = previous.resetEpochID { return candidate.resetEpochID == epochID }
        guard candidate.resetEpochID == nil else { return false }
        switch (previous.resetsAt, candidate.resetsAt) {
        case (.none, .none): return true
        case let (.some(previousReset), .some(candidateReset)):
            return abs(candidateReset.timeIntervalSince(previousReset)) <= UsageLimitHistoryPolicy.resetJitterTolerance
        default: return false
        }
    }

    private static func canConnectIgnoringLegacyEpochHistory(
        _ previous: UsageLimitSnapshot,
        to candidate: UsageLimitSnapshot,
        maximumGap: TimeInterval
    ) -> Bool {
        candidate.observedAt.timeIntervalSince(previous.lastObservedAt) <= maximumGap
            && candidate.observedAt >= previous.lastObservedAt
            && candidate.source == previous.source
            && UsageLimitHistoryBucket(candidate) == UsageLimitHistoryBucket(previous)
    }

    private struct SegmentResetState {
        let epochID: String?
        var earliestLegacyReset: Date?
        var latestLegacyReset: Date?

        init(_ observation: UsageLimitSnapshot) {
            epochID = observation.resetEpochID
            earliestLegacyReset = observation.resetEpochID == nil ? observation.resetsAt : nil
            latestLegacyReset = earliestLegacyReset
        }

        func canContinue(with candidate: UsageLimitSnapshot) -> Bool {
            if let epochID { return candidate.resetEpochID == epochID }
            guard candidate.resetEpochID == nil else { return false }
            switch (earliestLegacyReset, latestLegacyReset, candidate.resetsAt) {
            case (.none, .none, .none): return true
            case let (.some(earliest), .some(latest), .some(reset)):
                return max(latest, reset).timeIntervalSince(min(earliest, reset)) <= UsageLimitHistoryPolicy.resetJitterTolerance
            default: return false
            }
        }

        mutating func append(_ observation: UsageLimitSnapshot) {
            guard epochID == nil, let reset = observation.resetsAt else { return }
            earliestLegacyReset = earliestLegacyReset.map { min($0, reset) } ?? reset
            latestLegacyReset = latestLegacyReset.map { max($0, reset) } ?? reset
        }
    }
}
