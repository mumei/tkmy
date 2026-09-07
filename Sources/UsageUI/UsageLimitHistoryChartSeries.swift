import Foundation
import UsageDomain

/// Display-only primitives for the quota history chart. The chart clips these
/// real dates to its visible rectangle; this type never invents boundary data.
struct UsageLimitHistoryChartSeries {
    enum Style: Equatable {
        case observed
        case interpolated
        case extended
    }

    struct Point: Hashable {
        let date: Date
        let remainingPercent: Double
    }

    struct Stroke: Equatable {
        let start: Point
        let end: Point
        let style: Style
    }

    let strokes: [Stroke]
    let observations: [Point]

    static func make(
        observations input: [UsageLimitSnapshot],
        range: UsageLimitHistoryRange,
        now: Date
    ) -> Self {
        let cutoff = now.addingTimeInterval(-range.interval)
        let valid = input
            .filter { isValid($0, through: now) }
            .sorted { lhs, rhs in
                if lhs.observedAt != rhs.observedAt { return lhs.observedAt < rhs.observedAt }
                return lhs.lastObservedAt < rhs.lastObservedAt
            }

        var allStrokes: [Stroke] = []
        for observation in valid where observation.observedAt < observation.lastObservedAt {
            allStrokes.append(Stroke(
                start: Point(date: observation.observedAt, remainingPercent: observation.remainingPercent),
                end: Point(date: observation.lastObservedAt, remainingPercent: observation.remainingPercent),
                style: .observed
            ))
        }

        for segment in UsageLimitHistoryTimeline.segments(valid, maximumGap: .infinity) {
            for (previous, candidate) in zip(segment, segment.dropFirst())
                where previous.lastObservedAt < candidate.observedAt
                    && !hasKnownReset(between: previous.lastObservedAt, and: candidate.observedAt, observations: [previous, candidate]) {
                allStrokes.append(Stroke(
                    start: Point(date: previous.lastObservedAt, remainingPercent: previous.remainingPercent),
                    end: Point(date: candidate.observedAt, remainingPercent: candidate.remainingPercent),
                    style: .interpolated
                ))
            }
        }

        if let latest = valid.max(by: { lhs, rhs in
            if lhs.lastObservedAt != rhs.lastObservedAt { return lhs.lastObservedAt < rhs.lastObservedAt }
            return lhs.observedAt < rhs.observedAt
        }), let extensionEnd = extensionEnd(for: latest, now: now), latest.lastObservedAt < extensionEnd {
            allStrokes.append(Stroke(
                start: Point(date: latest.lastObservedAt, remainingPercent: latest.remainingPercent),
                end: Point(date: extensionEnd, remainingPercent: latest.remainingPercent),
                style: .extended
            ))
        }

        let displayedObservations = Array(Set(valid.flatMap { observation in
            [
                Point(date: observation.observedAt, remainingPercent: observation.remainingPercent),
                Point(date: observation.lastObservedAt, remainingPercent: observation.remainingPercent),
            ].filter { $0.date >= cutoff && $0.date <= now }
        }))
        .sorted { lhs, rhs in
            if lhs.date != rhs.date { return lhs.date < rhs.date }
            return lhs.remainingPercent < rhs.remainingPercent
        }

        return Self(
            strokes: allStrokes.filter { intersectsDisplayedRange($0, cutoff: cutoff, now: now) },
            observations: displayedObservations
        )
    }

    private static func isValid(_ observation: UsageLimitSnapshot, through now: Date) -> Bool {
        observation.observedAt.timeIntervalSinceReferenceDate.isFinite
            && observation.lastObservedAt.timeIntervalSinceReferenceDate.isFinite
            && observation.remainingPercent.isFinite
            && observation.observedAt <= observation.lastObservedAt
            && observation.lastObservedAt <= now
    }

    private static func extensionEnd(for observation: UsageLimitSnapshot, now: Date) -> Date? {
        guard let resetsAt = observation.resetsAt else { return now }
        guard resetsAt.timeIntervalSinceReferenceDate.isFinite, resetsAt > observation.lastObservedAt else {
            return nil
        }
        return min(now, resetsAt)
    }

    private static func hasKnownReset(
        between start: Date,
        and end: Date,
        observations: [UsageLimitSnapshot]
    ) -> Bool {
        observations.contains { observation in
            guard let reset = observation.resetsAt else { return false }
            guard reset.timeIntervalSinceReferenceDate.isFinite else { return true }
            return reset >= start && reset <= end
        }
    }

    private static func intersectsDisplayedRange(_ stroke: Stroke, cutoff: Date, now: Date) -> Bool {
        stroke.start.date < now && stroke.end.date > cutoff
    }
}
