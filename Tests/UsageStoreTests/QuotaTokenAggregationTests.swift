import Foundation
import Testing
import UsageDomain
@testable import UsageStore

@Test func storedQuotaTokenAggregationIsDeduplicatedExactAndCodexOnly() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("TKMYQuotaTokenTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let store = try SQLiteUsageStore(
        databaseURL: directory.appendingPathComponent("usage.sqlite3")
    )
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let end = start.addingTimeInterval(60)
    let atStart = usageEvent(
        key: "start", source: .codex, at: start,
        tokens: TokenBreakdown(input: 10, cacheRead: 2, output: 3, reasoningOutput: 2)
    )
    let duplicate = usageEvent(
        key: "duplicate", source: .codex, at: start.addingTimeInterval(30),
        tokens: TokenBreakdown(input: 5, cacheRead: 7, output: 11, reasoningOutput: 100)
    )
    let atEnd = usageEvent(
        key: "end", source: .codex, at: end,
        tokens: TokenBreakdown(input: 13, cacheRead: 17, output: 19, reasoningOutput: 100)
    )
    let claude = usageEvent(
        key: "claude", source: .claudeCode, at: start.addingTimeInterval(40),
        tokens: TokenBreakdown(input: 1_000)
    )
    try await store.upsert([atStart, duplicate, duplicate, atEnd, claude])

    let accumulator = try await store.reduceEvents(
        source: .codex,
        from: start.addingTimeInterval(-1),
        through: end.addingTimeInterval(1),
        initial: QuotaTokenSummary.Accumulator(source: .codex, endpoints: [start, end])
    ) { summary, event in
        summary.add(event, attribution: .general)
    }
    let summary = accumulator.summary(isComplete: true)

    #expect(summary.tokens(fromExclusive: start, through: end, limitID: "codex") ==
        TokenBreakdown(input: 18, cacheRead: 24, output: 30))
    #expect(summary.tokenCount(fromExclusive: start, through: end, limitID: "codex") == 72)
}

private func usageEvent(
    key: String,
    source: UsageSource,
    at date: Date,
    tokens: TokenBreakdown
) -> NormalizedUsageEvent {
    NormalizedUsageEvent(
        eventKey: key,
        source: source,
        occurredAt: date,
        tokens: tokens,
        model: source == .codex ? "gpt-5.6-sol" : "claude-sonnet-4-6",
        originPathHash: "test"
    )
}
