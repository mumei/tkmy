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
