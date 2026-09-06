import Foundation
import Testing
@testable import UsageDomain

@Test func quotaTokensUseExactOpenClosedIntervalWithoutDoubleCountingCache() throws {
    let start = Date(timeIntervalSince1970: 1_000)
    let end = start.addingTimeInterval(60)
    var accumulator = QuotaTokenSummary.Accumulator(source: .codex, endpoints: [end, start, start])
    accumulator.add(event(at: start, input: 2, cacheRead: 3, output: 5), attribution: .general)
    accumulator.add(event(at: start, input: 29, cacheRead: 31, output: 37), attribution: .general)
    accumulator.add(event(at: start.addingTimeInterval(1), input: 7, cacheRead: 11, output: 13), attribution: .general)
    accumulator.add(event(at: end, input: 17, cacheRead: 19, output: 23, reasoning: 41), attribution: .general)
    accumulator.add(event(at: end, input: 43, cacheRead: 47, output: 53), attribution: .general)
    accumulator.add(event(at: end.addingTimeInterval(1), input: 100, cacheRead: 100, output: 100), attribution: .general)

    let summary = accumulator.summary(isComplete: true)
    let tokens = try #require(summary.tokens(fromExclusive: start, through: end, limitID: "codex"))
    #expect(tokens == TokenBreakdown(input: 67, cacheRead: 77, output: 89))
    #expect(summary.tokenCount(fromExclusive: start, through: end, limitID: "codex") == 233)
    #expect(summary.points.map(\.observedAt) == [start, end])

    let beforeCoverage = QuotaTokenSummary(
        source: summary.source,
        points: summary.points,
        isComplete: true,
        coverageStartedAt: start.addingTimeInterval(1)
    )
    #expect(beforeCoverage.tokens(fromExclusive: start, through: end, limitID: "codex") == nil)
}

@Test func quotaTokensExcludeKnownSeparateModelsAndRejectUnknownAttribution() {
    let start = Date(timeIntervalSince1970: 2_000)
    let end = start.addingTimeInterval(60)
    var separate = QuotaTokenSummary.Accumulator(source: .codex, endpoints: [start, end])
    separate.add(event(at: start.addingTimeInterval(10), input: 100), attribution: .separateModelQuota)
    separate.add(event(at: start.addingTimeInterval(20), input: 9), attribution: .general)
    let separateSummary = separate.summary(isComplete: true)
    #expect(separateSummary.tokenCount(fromExclusive: start, through: end, limitID: "codex") == 9)
    #expect(separateSummary.tokens(fromExclusive: start, through: end, limitID: "codex_bengalfox") == nil)

    var unknown = QuotaTokenSummary.Accumulator(source: .codex, endpoints: [start, end])
    unknown.add(event(at: start.addingTimeInterval(10), input: 9), attribution: .general)
    unknown.add(event(at: start.addingTimeInterval(20), input: 1), attribution: .unknown)
    #expect(unknown.summary(isComplete: true).tokens(
        fromExclusive: start, through: end, limitID: "codex"
    ) == nil)
}

@Test func quotaTokensRejectMissingEmptyPartialCrossSourceAndOverflowEvidence() {
    let start = Date(timeIntervalSince1970: 3_000)
    let end = start.addingTimeInterval(60)
    var accumulator = QuotaTokenSummary.Accumulator(source: .codex, endpoints: [start, end])
    accumulator.add(event(source: .claudeCode, at: start.addingTimeInterval(5), input: 100), attribution: .general)
    let empty = accumulator.summary(isComplete: true)
    #expect(empty.tokens(fromExclusive: start, through: end, limitID: "codex") == nil)

    accumulator.add(event(at: start.addingTimeInterval(10), input: 1), attribution: .general)
    let populated = accumulator.summary(isComplete: true)
    #expect(populated.tokens(fromExclusive: start.addingTimeInterval(1), through: end, limitID: "codex") == nil)
    #expect(accumulator.summary(isComplete: false).tokens(
        fromExclusive: start, through: end, limitID: "codex"
    ) == nil)

    var overflow = QuotaTokenSummary.Accumulator(source: .codex, endpoints: [start, end])
    overflow.add(event(at: start.addingTimeInterval(1), input: .max), attribution: .general)
    overflow.add(event(at: start.addingTimeInterval(2), input: 1), attribution: .general)
    #expect(overflow.summary(isComplete: true).tokens(
        fromExclusive: start, through: end, limitID: "codex"
    ) == nil)

    var combinedOverflow = QuotaTokenSummary.Accumulator(source: .codex, endpoints: [start, end])
    combinedOverflow.add(event(at: start.addingTimeInterval(1), input: .max, cacheRead: 1), attribution: .general)
    #expect(combinedOverflow.summary(isComplete: true).tokens(
        fromExclusive: start, through: end, limitID: "codex"
    ) == nil)

    var unordered = QuotaTokenSummary.Accumulator(source: .codex, endpoints: [start, end])
    unordered.add(event(at: start.addingTimeInterval(20), input: 1), attribution: .general)
    unordered.add(event(at: start.addingTimeInterval(10), input: 1), attribution: .general)
    #expect(unordered.summary(isComplete: true).tokens(
        fromExclusive: start, through: end, limitID: "codex"
    ) == nil)
}

private func event(
    source: UsageSource = .codex,
    at date: Date,
    input: Int64,
    cacheRead: Int64 = 0,
    output: Int64 = 0,
    reasoning: Int64 = 0
) -> NormalizedUsageEvent {
    NormalizedUsageEvent(
        eventKey: "\(source.rawValue):\(date.timeIntervalSince1970):\(input):\(cacheRead):\(output)",
        source: source,
        occurredAt: date,
        tokens: TokenBreakdown(
            input: input,
            cacheRead: cacheRead,
            output: output,
            reasoningOutput: reasoning
        ),
        model: "gpt-5.6-sol",
        originPathHash: "test"
    )
}
