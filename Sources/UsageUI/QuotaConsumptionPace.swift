import Foundation
import UsageDomain

/// An observed wall-clock average for the latest continuous quota segment.
/// Endpoints are actual changes, never the end of a constant run or the clock.
struct QuotaConsumptionPace: Equatable {
    let startedAt: Date
    let endedAt: Date
    let percentagePointDrop: Double

    var elapsed: TimeInterval { endedAt.timeIntervalSince(startedAt) }
    var secondsPerPercentagePoint: TimeInterval { elapsed / percentagePointDrop }

    static func latest(
        in observations: [UsageLimitSnapshot],
        range: UsageLimitHistoryRange,
        now: Date,
        minimumStartedAt: Date? = nil
    ) -> QuotaConsumptionPace? {
        guard now.timeIntervalSinceReferenceDate.isFinite,
              observations.allSatisfy({
                  $0.observedAt.timeIntervalSinceReferenceDate.isFinite
                      && $0.lastObservedAt.timeIntervalSinceReferenceDate.isFinite
                      && $0.observedAt <= $0.lastObservedAt
                      && $0.lastObservedAt <= now
                      && $0.usedPercent.isFinite
                      && (0...100).contains($0.usedPercent)
              }),
              zip(observations, observations.dropFirst()).allSatisfy({
                  $0.observedAt < $1.observedAt && $0.lastObservedAt <= $1.observedAt
              }) else { return nil }

        // Never invent an observation at a range boundary. A run that began
        // before the range can appear on the chart but cannot start this rate.
        let cutoff = max(now.addingTimeInterval(-range.interval), minimumStartedAt ?? .distantPast)
        let inRange = observations.filter { $0.observedAt >= cutoff }
        guard let segment = UsageLimitHistoryTimeline.segments(inRange).last,
              let first = segment.first, let last = segment.last,
              first.resetEpochID != nil || first.resetsAt != nil,
              first.observedAt < last.observedAt else { return nil }

        let drop = first.remainingPercent - last.remainingPercent
        guard drop.isFinite, drop > 0 else { return nil }
        let result = QuotaConsumptionPace(
            startedAt: first.observedAt,
            endedAt: last.observedAt,
            percentagePointDrop: drop
        )
        guard result.secondsPerPercentagePoint.isFinite,
              result.secondsPerPercentagePoint > 0 else { return nil }
        return result
    }
}
