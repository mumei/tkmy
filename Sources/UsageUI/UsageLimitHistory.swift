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
    static let maximumConnectedGap: TimeInterval = 30 * 60

    static func observations(
        from history: [UsageLimitSnapshot],
        source: UsageSource,
        bucket: UsageLimitHistoryBucket,
        range: UsageLimitHistoryRange,
        now: Date
    ) -> [UsageLimitSnapshot] {
        let cutoff = now.addingTimeInterval(-range.interval)
        return history
            .filter {
                $0.source == source
                    && UsageLimitHistoryBucket($0) == bucket
                    && $0.observedAt >= cutoff
                    && $0.observedAt <= now
            }
            .sorted { $0.observedAt < $1.observedAt }
    }

    static func buckets(
        from history: [UsageLimitSnapshot],
        source: UsageSource,
        range: UsageLimitHistoryRange,
        now: Date
    ) -> [UsageLimitHistoryBucket] {
        let cutoff = now.addingTimeInterval(-range.interval)
        return Array(Set(history.compactMap { observation in
            guard observation.source == source,
                  observation.observedAt >= cutoff,
                  observation.observedAt <= now else { return nil }
            return UsageLimitHistoryBucket(observation)
        }))
        .sorted { lhs, rhs in
            if lhs.windowMinutes != rhs.windowMinutes { return lhs.windowMinutes < rhs.windowMinutes }
            return lhs.limitID.localizedStandardCompare(rhs.limitID) == .orderedAscending
        }
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
        observations.sorted { $0.observedAt < $1.observedAt }.reduce(into: []) { result, observation in
            guard let previous = result.last?.last,
                  observation.observedAt.timeIntervalSince(previous.observedAt) <= maximumConnectedGap,
                  observation.source == previous.source,
                  UsageLimitHistoryBucket(observation) == UsageLimitHistoryBucket(previous),
                  observation.resetsAt == previous.resetsAt,
                  observation.remainingPercent <= previous.remainingPercent else {
                result.append([observation])
                return
            }
            result[result.count - 1].append(observation)
        }
    }
}
