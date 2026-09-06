import Foundation

/// Compact token evidence at exact quota-observation timestamps.
///
/// Points are cumulative so an observed interval `(start, end]` can be derived
/// without retaining or copying raw usage events. Only Codex's general quota is
/// currently attributable: model-specific quota identifiers do not have a
/// documented mapping to local event model names.
public struct QuotaTokenSummary: Equatable, Sendable {
    public struct Point: Equatable, Sendable {
        public let observedAt: Date
        public let tokens: TokenBreakdown
        public let unattributedEventCount: Int64

        public init(
            observedAt: Date,
            tokens: TokenBreakdown,
            unattributedEventCount: Int64 = 0
        ) {
            self.observedAt = observedAt
            self.tokens = tokens
            self.unattributedEventCount = max(0, unattributedEventCount)
        }
    }

    public enum CodexEventAttribution: Sendable {
        /// The event is known to consume the general Codex quota.
        case general
        /// The event is known to use a separate, model-specific quota.
        case separateModelQuota
        /// The local model identity cannot be mapped to a quota bucket.
        case unknown
    }

    public let source: UsageSource
    public let points: [Point]
    public let isComplete: Bool
    /// Earliest time after which local ingestion completeness is tracked.
    /// Nil is retained for explicit fixtures and callers with external proof.
    public let coverageStartedAt: Date?

    public init(
        source: UsageSource,
        points: [Point],
        isComplete: Bool,
        coverageStartedAt: Date? = nil
    ) {
        self.source = source
        self.points = points
        self.isComplete = isComplete
        self.coverageStartedAt = coverageStartedAt
    }

    /// Returns tokens observed in `(start, end]` only when both exact endpoints
    /// exist and every event in the interval can be attributed safely.
    public func tokens(
        fromExclusive start: Date,
        through end: Date,
        limitID: String
    ) -> TokenBreakdown? {
        guard source == .codex,
              limitID.lowercased() == "codex",
              isComplete,
              start < end,
              coverageStartedAt.map({ start >= $0 }) ?? true,
              let startPoint = points.first(where: { $0.observedAt == start }),
              let endPoint = points.first(where: { $0.observedAt == end }),
              startPoint.unattributedEventCount == endPoint.unattributedEventCount,
              let difference = Self.subtract(endPoint.tokens, startPoint.tokens),
              Self.safeTotal(difference).map({ $0 > 0 }) == true
        else { return nil }
        return difference
    }

    public func tokenCount(
        fromExclusive start: Date,
        through end: Date,
        limitID: String
    ) -> Int64? {
        guard let tokens = tokens(fromExclusive: start, through: end, limitID: limitID) else {
            return nil
        }
        return Self.safeTotal(tokens)
    }

    public struct Accumulator: Sendable {
        private let source: UsageSource
        private let endpoints: [Date]
        private var nextEndpointIndex = 0
        private var runningTokens = TokenBreakdown.zero
        private var unattributedEventCount: Int64 = 0
        private var points: [Point] = []
        private var overflowed = false
        private var lastEventDate: Date?

        public init(source: UsageSource, endpoints: [Date]) {
            self.source = source
            self.endpoints = Array(Set(endpoints.filter {
                $0.timeIntervalSinceReferenceDate.isFinite
            })).sorted()
        }

        /// Adds one already de-duplicated normalized event. Events from another
        /// source are ignored, which prevents cross-provider attribution.
        public mutating func add(
            _ event: NormalizedUsageEvent,
            attribution: CodexEventAttribution
        ) {
            guard event.source == source, !overflowed else { return }
            guard lastEventDate.map({ event.occurredAt >= $0 }) ?? true else {
                // SQLiteUsageStore guarantees chronological reduction. Reject
                // unordered input here so public callers cannot get a partial
                // cumulative series from a different event source.
                overflowed = true
                return
            }
            lastEventDate = event.occurredAt
            emitEndpoints(before: event.occurredAt)
            guard nextEndpointIndex < endpoints.count,
                  event.occurredAt <= endpoints[endpoints.count - 1]
            else { return }

            switch attribution {
            case .general:
                guard event.tokens.input >= 0,
                      event.tokens.cacheRead >= 0,
                      event.tokens.output >= 0,
                      let input = QuotaTokenSummary.checkedAdd(runningTokens.input, event.tokens.input),
                      let cacheRead = QuotaTokenSummary.checkedAdd(runningTokens.cacheRead, event.tokens.cacheRead),
                      let output = QuotaTokenSummary.checkedAdd(runningTokens.output, event.tokens.output)
                else {
                    overflowed = true
                    return
                }
                runningTokens = TokenBreakdown(input: input, cacheRead: cacheRead, output: output)
            case .separateModelQuota:
                break
            case .unknown:
                guard let count = QuotaTokenSummary.checkedAdd(unattributedEventCount, 1) else {
                    overflowed = true
                    return
                }
                unattributedEventCount = count
            }
        }

        public func summary(
            isComplete: Bool,
            coverageStartedAt: Date? = nil
        ) -> QuotaTokenSummary {
            var finalized = self
            finalized.emitRemainingEndpoints()
            return QuotaTokenSummary(
                source: source,
                points: finalized.points,
                isComplete: isComplete && !finalized.overflowed,
                coverageStartedAt: coverageStartedAt
            )
        }

        private mutating func emitEndpoints(before date: Date) {
            while nextEndpointIndex < endpoints.count, endpoints[nextEndpointIndex] < date {
                emitNextEndpoint()
            }
        }

        private mutating func emitRemainingEndpoints() {
            while nextEndpointIndex < endpoints.count { emitNextEndpoint() }
        }

        private mutating func emitNextEndpoint() {
            points.append(Point(
                observedAt: endpoints[nextEndpointIndex],
                tokens: runningTokens,
                unattributedEventCount: unattributedEventCount
            ))
            nextEndpointIndex += 1
        }

    }

    private static func subtract(_ end: TokenBreakdown, _ start: TokenBreakdown) -> TokenBreakdown? {
        func checked(_ end: Int64, _ start: Int64) -> Int64? {
            let (difference, overflow) = end.subtractingReportingOverflow(start)
            return !overflow && difference >= 0 ? difference : nil
        }
        guard let input = checked(end.input, start.input),
              let cacheRead = checked(end.cacheRead, start.cacheRead),
              let output = checked(end.output, start.output)
        else { return nil }
        return TokenBreakdown(input: input, cacheRead: cacheRead, output: output)
    }

    private static func safeTotal(_ tokens: TokenBreakdown) -> Int64? {
        guard let inputAndCache = checkedAdd(tokens.input, tokens.cacheRead) else { return nil }
        return checkedAdd(inputAndCache, tokens.output)
    }

    private static func checkedAdd(_ lhs: Int64, _ rhs: Int64) -> Int64? {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? nil : sum
    }
}
