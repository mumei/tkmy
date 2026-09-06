import Foundation
import Testing
import UsageDomain
@testable import UsageStore

@Test func upsertIsIdempotentAndGroupsByDay() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("TKMYStoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let store = try SQLiteUsageStore(databaseURL: directory.appendingPathComponent("usage.sqlite3"))
    let event = NormalizedUsageEvent(
        eventKey: "event-1",
        source: .codex,
        occurredAt: Date(timeIntervalSince1970: 1_700_000_000),
        tokens: TokenBreakdown(input: 10, output: 5),
        model: "test-model",
        sourceCostMicrosUSD: 42,
        originPathHash: "hash"
    )
    try await store.upsert([event, event])

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let days = try await store.dailyUsage(
        source: .codex,
        from: Date(timeIntervalSince1970: 1_699_900_000),
        through: Date(timeIntervalSince1970: 1_700_100_000),
        calendar: calendar
    )
    #expect(days.count == 1)
    #expect(days.first?.tokens.total == 15)
    #expect(days.first?.knownCostMicrosUSD == 42)
}

@Test func cursorRoundTrips() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("TKMYCursor-\(UUID().uuidString).sqlite3")
    defer { try? FileManager.default.removeItem(at: url) }
    let store = try SQLiteUsageStore(databaseURL: url)
    let cursor = FileCursor(
        inode: 3,
        size: 100,
        modifiedAtMilliseconds: 4,
        byteOffset: 80,
        contentSignature: "signature",
        parserVersion: 2
    )
    try await store.saveCursor(cursor, source: .claudeCode, pathHash: "path")
    #expect(try await store.cursor(for: .claudeCode, pathHash: "path") == cursor)
}

@Test func replacingChangedFileRemovesItsPreviousEventsOnly() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("TKMYReplace-\(UUID().uuidString).sqlite3")
    defer { try? FileManager.default.removeItem(at: url) }
    let store = try SQLiteUsageStore(databaseURL: url)
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let old = NormalizedUsageEvent(
        eventKey: "old",
        source: .codex,
        occurredAt: date,
        tokens: .init(input: 10),
        originPathHash: "changed-file"
    )
    let other = NormalizedUsageEvent(
        eventKey: "other",
        source: .codex,
        occurredAt: date,
        tokens: .init(input: 20),
        originPathHash: "other-file"
    )
    try await store.upsert([old, other])
    let replacement = NormalizedUsageEvent(
        eventKey: "replacement",
        source: .codex,
        occurredAt: date,
        tokens: .init(input: 5),
        originPathHash: "changed-file"
    )
    try await store.replaceEvents(source: .codex, originPathHash: "changed-file", with: [replacement])

    let events = try await store.events(
        source: .codex,
        from: date.addingTimeInterval(-1),
        through: date.addingTimeInterval(1)
    )
    #expect(Set(events.map(\.eventKey)) == ["replacement", "other"])
}

@Test func usageLimitHistoryRetainsExact365DayBoundaryAndRejectsOldOrFutureSamples() async throws {
    let store = try makeStore()
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let cutoff = UsageLimitHistoryPolicy.cutoff(relativeTo: now)
    try await store.upsertUsageLimits([
        limit(observedAt: cutoff.addingTimeInterval(-0.001), usedPercent: 1),
        limit(observedAt: cutoff, usedPercent: 2),
        limit(observedAt: now, usedPercent: 3),
        limit(observedAt: now.addingTimeInterval(0.001), usedPercent: 4),
    ], now: now)

    let history = try await store.usageLimitHistory(
        source: .codex,
        from: cutoff.addingTimeInterval(-1),
        through: now.addingTimeInterval(1)
    )
    #expect(history.map(\.usedPercent) == [2, 3])
}

@Test func advancingClockPrunesAndRejectedOldSampleCannotResurrect() async throws {
    let store = try makeStore()
    let originalNow = Date(timeIntervalSince1970: 2_000_000_000)
    let sample = limit(observedAt: originalNow, usedPercent: 33)
    try await store.upsertUsageLimits([sample], now: originalNow)

    let advancedNow = originalNow.addingTimeInterval(UsageLimitHistoryPolicy.retentionInterval + 1)
    try await store.pruneUsageLimitHistory(now: advancedNow)
    try await store.upsertUsageLimits([sample], now: advancedNow)

    let history = try await store.usageLimitHistory(
        source: .codex,
        from: originalNow.addingTimeInterval(-1),
        through: advancedNow.addingTimeInterval(1)
    )
    #expect(history.isEmpty)
}

@Test func usageLimitHistoryDeduplicatesAndKeepsDistinctLimitWindowAndReset() async throws {
    let store = try makeStore()
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let observedAt = now.addingTimeInterval(-60)
    let base = limit(observedAt: observedAt, usedPercent: 40)
    let differentWindow = limit(observedAt: observedAt, usedPercent: 40, windowMinutes: 10_080)
    let differentLimit = limit(observedAt: observedAt, usedPercent: 40, limitID: "secondary")
    let differentReset = limit(observedAt: observedAt, usedPercent: 40, resetsAt: now.addingTimeInterval(600))
    try await store.upsertUsageLimits([base, base, differentWindow, differentLimit, differentReset], now: now)
    try await store.upsertUsageLimits([base], now: now)

    let history = try await store.usageLimitHistory(
        source: .codex,
        from: observedAt.addingTimeInterval(-1),
        through: now
    )
    #expect(history.count == 4)
    #expect(Set(history).count == 4)
}

@Test func usageLimitHistoryPersistsAcrossStoreReopenAndPruningDoesNotTouchTokenEvents() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("TKMYLimits-\(UUID().uuidString).sqlite3")
    defer { try? FileManager.default.removeItem(at: url) }
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let old = limit(observedAt: now.addingTimeInterval(-UsageLimitHistoryPolicy.retentionInterval - 1), usedPercent: 10)
    let current = limit(observedAt: now, usedPercent: 20)
    let event = NormalizedUsageEvent(
        eventKey: "token-event",
        source: .codex,
        occurredAt: old.observedAt,
        tokens: .init(input: 1),
        originPathHash: "origin"
    )

    let store = try SQLiteUsageStore(databaseURL: url)
    try await store.upsert([event])
    try await store.upsertUsageLimits([old, current], now: now)
    try await store.pruneUsageLimitHistory(now: now)
    let reopened = try SQLiteUsageStore(databaseURL: url)

    let history = try await reopened.usageLimitHistory(
        source: .codex,
        from: now.addingTimeInterval(-UsageLimitHistoryPolicy.retentionInterval - 1),
        through: now.addingTimeInterval(1)
    )
    let events = try await reopened.events(
        source: .codex,
        from: old.observedAt.addingTimeInterval(-1),
        through: old.observedAt.addingTimeInterval(1)
    )
    #expect(history == [current])
    #expect(events == [event])
}

private func makeStore() throws -> SQLiteUsageStore {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("TKMYLimits-\(UUID().uuidString).sqlite3")
    return try SQLiteUsageStore(databaseURL: url)
}

private func limit(
    observedAt: Date,
    usedPercent: Double,
    limitID: String = "codex",
    windowMinutes: Int = 300,
    resetsAt: Date? = nil
) -> UsageLimitSnapshot {
    UsageLimitSnapshot(
        source: .codex,
        limitID: limitID,
        usedPercent: usedPercent,
        windowMinutes: windowMinutes,
        resetsAt: resetsAt,
        observedAt: observedAt
    )
}
