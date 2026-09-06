import Foundation
import UsageDomain

/// The time range selected in the remaining-quota history pane.
enum UsageLimitHistoryRange: Int, CaseIterable, Identifiable, Hashable {
    case sevenDays = 7
    case thirtyDays = 30

    var id: Int { rawValue }
    var localizationKey: String { self == .sevenDays ? "quota_range_7d" : "quota_range_30d" }
    var interval: TimeInterval { TimeInterval(rawValue * 24 * 60 * 60) }
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
    /// A provider sample gap beyond 30 minutes means its intervening values are
    /// unknown, so the chart deliberately leaves a visible break.
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

    static func buckets(
        from history: [UsageLimitSnapshot],
        source: UsageSource,
        range: UsageLimitHistoryRange,
        now: Date
    ) -> [UsageLimitHistoryBucket] {
        return Array(Set(history.compactMap { observation in
            guard observation.source == source,
                  intersectsDisplayedRange(observation, range: range, now: now) else { return nil }
            return UsageLimitHistoryBucket(observation)
        }))
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
        guard observation.lastObservedAt <= now else { return nil }
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

    static func segments(_ observations: [UsageLimitSnapshot]) -> [[UsageLimitSnapshot]] {
        var result: [[UsageLimitSnapshot]] = []
        var resetState: SegmentResetState?

        for observation in observations.sorted(by: { $0.observedAt < $1.observedAt }) {
            guard let previous = result.last?.last,
                  observation.observedAt.timeIntervalSince(previous.lastObservedAt) <= maximumConnectedGap,
                  observation.source == previous.source,
                  UsageLimitHistoryBucket(observation) == UsageLimitHistoryBucket(previous),
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
