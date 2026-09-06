import Foundation
import SQLite3
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
    #expect(history.count == 1)
    #expect(history.first?.source == current.source)
    #expect(history.first?.limitID == current.limitID)
    #expect(history.first?.usedPercent == current.usedPercent)
    #expect(history.first?.observedAt == current.observedAt)
    #expect(history.first?.lastObservedAt == current.observedAt)
    #expect(history.first?.resetEpochID != nil)
    #expect(events == [event])
}

@Test func unchangedQuotaObservationsCompressIntoFirstAndLastWitnesses() async throws {
    let store = try makeStore()
    let start = Date(timeIntervalSince1970: 2_000_000_000)
    let observations = [0.0, 300, 600].map {
        limit(observedAt: start.addingTimeInterval($0), usedPercent: 12)
    }
    try await store.upsertUsageLimits(observations, now: start.addingTimeInterval(600))

    let history = try await store.usageLimitHistory(
        source: .codex,
        from: start.addingTimeInterval(-1),
        through: start.addingTimeInterval(601)
    )
    #expect(history.count == 1)
    #expect(history.first?.observedAt == start)
    #expect(history.first?.lastObservedAt == start.addingTimeInterval(600))
}

@Test func lateInteriorChangeSplitsAnAlreadyCompressedRunWithoutLosingTheReturnValue() async throws {
    let store = try makeStore()
    let start = Date(timeIntervalSince1970: 2_000_000_000)
    try await store.upsertUsageLimits([
        limit(observedAt: start, usedPercent: 10),
        limit(observedAt: start.addingTimeInterval(600), usedPercent: 10),
    ], now: start.addingTimeInterval(600))
    try await store.upsertUsageLimits([
        limit(observedAt: start.addingTimeInterval(300), usedPercent: 20),
    ], now: start.addingTimeInterval(600))

    let history = try await store.usageLimitHistory(
        source: .codex,
        from: start.addingTimeInterval(-1),
        through: start.addingTimeInterval(601)
    )
    #expect(history.map(\.usedPercent) == [10, 20, 10])
    #expect(history.map(\.observedAt) == [
        start,
        start.addingTimeInterval(300),
        start.addingTimeInterval(600),
    ])
}

@Test func reversedInterleavedAndChunkedBackfillProducesTheSameHistory() async throws {
    let chronological = try makeStore()
    let reversed = try makeStore()
    let start = Date(timeIntervalSince1970: 2_000_000_000)
    let reset = start.addingTimeInterval(3_600)
    let evidence = [
        limit(observedAt: start, usedPercent: 10, resetsAt: reset),
        limit(observedAt: start.addingTimeInterval(60), usedPercent: 10, resetsAt: reset.addingTimeInterval(0.5)),
        limit(observedAt: start.addingTimeInterval(120), usedPercent: 20, resetsAt: reset.addingTimeInterval(1)),
        limit(observedAt: start.addingTimeInterval(180), usedPercent: 20, resetsAt: reset.addingTimeInterval(2)),
        limit(observedAt: start.addingTimeInterval(240), usedPercent: 30, resetsAt: reset.addingTimeInterval(2.5)),
    ]
    let now = start.addingTimeInterval(300)
    try await chronological.upsertUsageLimits(evidence, now: now)
    for chunk in [[evidence[4], evidence[2]], [evidence[3]], [evidence[1], evidence[0]]] {
        try await reversed.upsertUsageLimits(chunk, now: now)
    }
    try await reversed.upsertUsageLimits(Array(evidence.reversed()), now: now)

    let range = start.addingTimeInterval(-1)..<start.addingTimeInterval(301)
    let expected = try await chronological.usageLimitHistory(source: .codex, from: range.lowerBound, through: range.upperBound)
    let actual = try await reversed.usageLimitHistory(source: .codex, from: range.lowerBound, through: range.upperBound)
    #expect(actual == expected)
}

@Test func sameTimeConflictsHaveDeterministicValueOrderAndDuplicateReplayIsIdempotent() async throws {
    let store = try makeStore()
    let observedAt = Date(timeIntervalSince1970: 2_000_000_000)
    let values = [30.0, 10, 20].map { limit(observedAt: observedAt, usedPercent: $0) }
    try await store.upsertUsageLimits(values, now: observedAt)
    try await store.upsertUsageLimits(Array(values.reversed()), now: observedAt)

    let history = try await store.usageLimitHistory(
        source: .codex,
        from: observedAt.addingTimeInterval(-1),
        through: observedAt.addingTimeInterval(1)
    )
    #expect(history.map(\.usedPercent) == [10, 20, 30])
    #expect(history.allSatisfy { $0.observedAt == observedAt && $0.lastObservedAt == observedAt })
}

@Test func resetJitterUsesBoundedEpochWidthRatherThanAdjacentChaining() async throws {
    let store = try makeStore()
    let start = Date(timeIntervalSince1970: 2_000_000_000)
    let reset = start.addingTimeInterval(3_600)
    try await store.upsertUsageLimits([
        limit(observedAt: start, usedPercent: 25, resetsAt: reset),
        limit(observedAt: start.addingTimeInterval(60), usedPercent: 25, resetsAt: reset.addingTimeInterval(1)),
        limit(observedAt: start.addingTimeInterval(120), usedPercent: 25, resetsAt: reset.addingTimeInterval(2)),
    ], now: start.addingTimeInterval(120))

    let history = try await store.usageLimitHistory(
        source: .codex,
        from: start.addingTimeInterval(-1),
        through: start.addingTimeInterval(121)
    )
    #expect(history.count == 2)
    #expect(history[0].lastObservedAt == start.addingTimeInterval(60))
    #expect(history[0].resetEpochID != history[1].resetEpochID)
}

@Test func resetEpochSurvivesUsedPercentChangesAndMeaningfulResetChangeIsNeverSwallowed() async throws {
    let store = try makeStore()
    let start = Date(timeIntervalSince1970: 2_000_000_000)
    let reset = start.addingTimeInterval(3_600)
    try await store.upsertUsageLimits([
        limit(observedAt: start, usedPercent: 10, resetsAt: reset),
        limit(observedAt: start.addingTimeInterval(60), usedPercent: 20, resetsAt: reset.addingTimeInterval(1)),
        limit(observedAt: start.addingTimeInterval(120), usedPercent: 20, resetsAt: reset.addingTimeInterval(1.001)),
    ], now: start.addingTimeInterval(120))

    let history = try await store.usageLimitHistory(
        source: .codex,
        from: start.addingTimeInterval(-1),
        through: start.addingTimeInterval(121)
    )
    #expect(history.count == 3)
    #expect(history[0].resetEpochID == history[1].resetEpochID)
    #expect(history[1].resetEpochID != history[2].resetEpochID)
}

@Test func thirtyMinuteBoundaryStaysContinuousAndLaterWitnessStartsANewRun() async throws {
    let store = try makeStore()
    let start = Date(timeIntervalSince1970: 2_000_000_000)
    try await store.upsertUsageLimits([
        limit(observedAt: start, usedPercent: 25),
        limit(observedAt: start.addingTimeInterval(1_800), usedPercent: 25),
        limit(observedAt: start.addingTimeInterval(3_600.001), usedPercent: 25),
    ], now: start.addingTimeInterval(3_600.001))

    let history = try await store.usageLimitHistory(
        source: .codex,
        from: start.addingTimeInterval(-1),
        through: start.addingTimeInterval(3_601)
    )
    #expect(history.count == 2)
    #expect(history[0].lastObservedAt == start.addingTimeInterval(1_800))
    #expect(abs(history[1].observedAt.timeIntervalSince(start.addingTimeInterval(3_600.001))) < 0.000_1)
}

@Test func retentionCrossingOngoingRunStartsAtFirstRetainedWitnessAndExpiredReplayCannotRestoreIt() async throws {
    let store = try makeStore()
    let start = Date(timeIntervalSince1970: 2_000_000_000)
    let retained = start.addingTimeInterval(1_200)
    try await store.upsertUsageLimits([
        limit(observedAt: start, usedPercent: 25),
        limit(observedAt: retained, usedPercent: 25),
    ], now: retained)
    let advancedNow = start.addingTimeInterval(UsageLimitHistoryPolicy.retentionInterval + 600)
    try await store.pruneUsageLimitHistory(now: advancedNow)
    try await store.upsertUsageLimits([limit(observedAt: start, usedPercent: 50)], now: advancedNow)

    let history = try await store.usageLimitHistory(
        source: .codex,
        from: start,
        through: advancedNow.addingTimeInterval(1)
    )
    #expect(history.count == 1)
    #expect(history.first?.usedPercent == 25)
    #expect(history.first?.observedAt == retained)
    #expect(history.first?.lastObservedAt == retained)
}

@Test func historyQueryReturnsOverlappingRunAndClipsToLastActualConfirmationBeforeEnd() async throws {
    let store = try makeStore()
    let start = Date(timeIntervalSince1970: 2_000_000_000)
    try await store.upsertUsageLimits([
        limit(observedAt: start, usedPercent: 25),
        limit(observedAt: start.addingTimeInterval(600), usedPercent: 25),
        limit(observedAt: start.addingTimeInterval(1_200), usedPercent: 25),
    ], now: start.addingTimeInterval(1_200))

    let history = try await store.usageLimitHistory(
        source: .codex,
        from: start.addingTimeInterval(300),
        through: start.addingTimeInterval(900)
    )
    #expect(history.count == 1)
    #expect(history.first?.observedAt == start)
    #expect(history.first?.lastObservedAt == start.addingTimeInterval(600))
}

@Test func schema3MigrationBacksUpRawRowsAndPreservesUnrelatedData() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("TKMYSchema3-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("usage.sqlite3")
    let nowSeconds = Int64(Date().timeIntervalSince1970.rounded(.down))
    let nowMS = nowSeconds * 1_000
    let resetMS = nowMS + 3_600_000
    let expiredMS = nowMS - Int64(UsageLimitHistoryPolicy.retentionInterval * 1_000) - 60_000
    let futureMS = nowMS + 3_600_000
    try createSchema3Database(at: url, rows: [
        ("codex", "codex", 10, 300, resetMS, nowMS - 600_000),
        ("codex", "codex", 10, 300, resetMS + 1_000, nowMS - 540_000),
        ("codex", "codex", 20, 300, resetMS + 500, nowMS - 480_000),
        ("codex", "codex", 10, 300, resetMS + 800, nowMS - 420_000),
        ("codex", "codex", 5, 300, resetMS, expiredMS),
        ("codex", "codex", 99, 300, resetMS, futureMS),
    ], includeUnrelatedRowsAt: nowMS)

    let store = try SQLiteUsageStore(databaseURL: url)
    let history = try await store.usageLimitHistory(
        source: .codex,
        from: .distantPast,
        through: Date(timeIntervalSince1970: Double(nowSeconds + 7_200))
    )
    #expect(history.map(\.usedPercent) == [10, 20, 10])
    #expect(history.map { historyMilliseconds($0.observedAt) } == [nowMS - 600_000, nowMS - 480_000, nowMS - 420_000])
    #expect(history.first.map { historyMilliseconds($0.lastObservedAt) } == nowMS - 540_000)
    #expect(history[0].resetEpochID == history[1].resetEpochID)
    #expect(history[1].resetEpochID == history[2].resetEpochID)

    let event = try await store.events(
        source: .codex,
        from: Date(timeIntervalSince1970: Double(nowSeconds - 1_000)),
        through: Date(timeIntervalSince1970: Double(nowSeconds + 1))
    )
    #expect(event.map(\.eventKey) == ["preserved-event"])
    #expect(try await store.cursor(for: .codex, pathHash: "preserved-path") == FileCursor(
        inode: 7,
        size: 11,
        modifiedAtMilliseconds: nowMS,
        byteOffset: 9,
        contentSignature: "preserved-signature",
        parserVersion: 4
    ))
    #expect(try sqliteInteger(at: url, sql: "PRAGMA user_version") == 4)

    let backups = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        .filter { $0.lastPathComponent.contains(".schema3-backup-") && $0.pathExtension == "sqlite3" }
    #expect(backups.count == 1)
    #expect(try sqliteInteger(at: backups[0], sql: "SELECT COUNT(*) FROM usage_limit_samples") == 6)
    #expect(try sqliteInteger(at: backups[0], sql: "PRAGMA user_version") == 3)
}

@Test func invalidSchema3MigrationRollsBackAndLeavesLegacyRowsAndVersionIntact() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("TKMYInvalidSchema3-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("usage.sqlite3")
    let nowMS = Int64(Date().timeIntervalSince1970.rounded(.down)) * 1_000
    try createSchema3Database(at: url, rows: [
        ("codex", "codex", 10, 300, nowMS + 3_600_000, nowMS - 60_000),
        ("invalid-source", "codex", 20, 300, nowMS + 3_600_000, nowMS - 30_000),
    ])

    #expect(throws: UsageStoreError.self) {
        _ = try SQLiteUsageStore(databaseURL: url)
    }
    #expect(try sqliteInteger(at: url, sql: "PRAGMA user_version") == 3)
    #expect(try sqliteInteger(at: url, sql: "SELECT COUNT(*) FROM usage_limit_samples") == 2)
    #expect(try sqliteInteger(
        at: url,
        sql: "SELECT COUNT(*) FROM pragma_table_info('usage_limit_samples') WHERE name = 'last_observed_at_ms'"
    ) == 0)
    #expect(try sqliteInteger(at: url, sql: "SELECT COUNT(*) FROM usage_limit_samples WHERE source = 'codex'") == 1)
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

private typealias LegacyLimitRow = (
    source: String,
    limitID: String,
    usedPercent: Double,
    windowMinutes: Int64,
    resetsAtMS: Int64,
    observedAtMS: Int64
)

private func createSchema3Database(
    at url: URL,
    rows: [LegacyLimitRow],
    includeUnrelatedRowsAt unrelatedTimestampMS: Int64? = nil
) throws {
    try withSQLiteDatabase(at: url) { database in
        try sqliteExecute(database, sql: """
        CREATE TABLE usage_events(
          event_key TEXT PRIMARY KEY, source TEXT NOT NULL, session_id TEXT,
          occurred_at_ms INTEGER NOT NULL, input_tokens INTEGER NOT NULL,
          cache_create_5m_tokens INTEGER NOT NULL, cache_create_1h_tokens INTEGER NOT NULL,
          cache_read_tokens INTEGER NOT NULL, output_tokens INTEGER NOT NULL,
          reasoning_output_tokens INTEGER NOT NULL, model TEXT,
          source_cost_micros_usd INTEGER, origin_path_hash TEXT NOT NULL
        );
        CREATE TABLE source_cursors(
          source TEXT NOT NULL, path_hash TEXT NOT NULL, inode INTEGER NOT NULL,
          size INTEGER NOT NULL, mtime_ms INTEGER NOT NULL, byte_offset INTEGER NOT NULL,
          content_signature TEXT NOT NULL DEFAULT '', parser_version INTEGER NOT NULL DEFAULT 1,
          PRIMARY KEY(source, path_hash)
        );
        CREATE TABLE usage_limit_samples(
          source TEXT NOT NULL, limit_id TEXT NOT NULL, used_percent REAL NOT NULL,
          window_minutes INTEGER NOT NULL, resets_at_ms INTEGER NOT NULL,
          observed_at_ms INTEGER NOT NULL,
          PRIMARY KEY(source, limit_id, window_minutes, resets_at_ms, observed_at_ms, used_percent)
        );
        PRAGMA user_version = 3;
        """)
        var statement: OpaquePointer?
        let insert = "INSERT INTO usage_limit_samples VALUES (?, ?, ?, ?, ?, ?)"
        guard sqlite3_prepare_v2(database, insert, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw UsageStoreError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        for row in rows {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            sqlite3_bind_text(statement, 1, row.source, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 2, row.limitID, -1, SQLITE_TRANSIENT)
            sqlite3_bind_double(statement, 3, row.usedPercent)
            sqlite3_bind_int64(statement, 4, row.windowMinutes)
            sqlite3_bind_int64(statement, 5, row.resetsAtMS)
            sqlite3_bind_int64(statement, 6, row.observedAtMS)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw UsageStoreError.sqlite(String(cString: sqlite3_errmsg(database)))
            }
        }
        if let unrelatedTimestampMS {
            try sqliteExecute(database, sql: """
            INSERT INTO usage_events VALUES(
              'preserved-event', 'codex', NULL, \(unrelatedTimestampMS - 100_000),
              1, 2, 3, 4, 5, 6, 'preserved-model', 7, 'preserved-origin'
            );
            INSERT INTO source_cursors VALUES(
              'codex', 'preserved-path', 7, 11, \(unrelatedTimestampMS), 9, 'preserved-signature', 4
            );
            """)
        }
    }
}

private func sqliteInteger(at url: URL, sql: String) throws -> Int64 {
    try withSQLiteDatabase(at: url, flags: SQLITE_OPEN_READONLY) { database in
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw UsageStoreError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw UsageStoreError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
        return sqlite3_column_int64(statement, 0)
    }
}

private func withSQLiteDatabase<Result>(
    at url: URL,
    flags: Int32 = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE,
    _ body: (OpaquePointer) throws -> Result
) throws -> Result {
    var database: OpaquePointer?
    guard sqlite3_open_v2(url.path, &database, flags, nil) == SQLITE_OK, let database else {
        let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown SQLite error"
        if let database { sqlite3_close(database) }
        throw UsageStoreError.open(message)
    }
    defer { sqlite3_close(database) }
    return try body(database)
}

private func sqliteExecute(_ database: OpaquePointer, sql: String) throws {
    var error: UnsafeMutablePointer<CChar>?
    guard sqlite3_exec(database, sql, nil, nil, &error) == SQLITE_OK else {
        let message = error.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(database))
        sqlite3_free(error)
        throw UsageStoreError.sqlite(message)
    }
}

private func historyMilliseconds(_ date: Date) -> Int64 {
    Int64((date.timeIntervalSince1970 * 1_000).rounded())
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
