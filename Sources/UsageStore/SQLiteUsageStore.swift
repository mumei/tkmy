import Foundation
import SQLite3
import UsageDomain

public enum UsageStoreError: Error, LocalizedError, Sendable {
    case open(String)
    case sqlite(String)

    public var errorDescription: String? {
        switch self {
        case let .open(message): "データベースを開けませんでした: \(message)"
        case let .sqlite(message): "データベース処理に失敗しました: \(message)"
        }
    }
}

public actor SQLiteUsageStore: UsageEventStore {
    private let connection: SQLiteConnection
    private var database: OpaquePointer? { connection.handle }
    public let databaseURL: URL

    public init(databaseURL: URL? = nil) throws {
        let resolvedURL = try databaseURL ?? Self.defaultDatabaseURL()
        self.databaseURL = resolvedURL

        try FileManager.default.createDirectory(
            at: resolvedURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var handle: OpaquePointer?
        guard sqlite3_open_v2(
            resolvedURL.path,
            &handle,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            if let handle { sqlite3_close(handle) }
            throw UsageStoreError.open(message)
        }
        guard let handle else { throw UsageStoreError.open("missing database handle") }
        connection = SQLiteConnection(handle: handle)
        try Self.configureAndMigrate(database: handle)
    }

    public static func defaultDatabaseURL() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return base
            .appendingPathComponent("TKMY", isDirectory: true)
            .appendingPathComponent("usage.sqlite3")
    }

    public func upsert(_ events: [NormalizedUsageEvent]) async throws {
        guard !events.isEmpty else { return }
        try execute("BEGIN IMMEDIATE")
        do {
            try insert(events)
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    public func replaceEvents(
        source: UsageSource,
        originPathHash: String,
        with events: [NormalizedUsageEvent]
    ) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            let delete = try prepare("DELETE FROM usage_events WHERE source = ? AND origin_path_hash = ?")
            defer { sqlite3_finalize(delete) }
            bind(source.rawValue, at: 1, to: delete)
            bind(originPathHash, at: 2, to: delete)
            try stepDone(delete)
            try insert(events)
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    public func deleteEvents(source: UsageSource, originPathHash: String) throws {
        let statement = try prepare("DELETE FROM usage_events WHERE source = ? AND origin_path_hash = ?")
        defer { sqlite3_finalize(statement) }
        bind(source.rawValue, at: 1, to: statement)
        bind(originPathHash, at: 2, to: statement)
        try stepDone(statement)
    }

    public func knownPathHashes(source: UsageSource) throws -> Set<String> {
        let statement = try prepare("SELECT DISTINCT origin_path_hash FROM usage_events WHERE source = ?")
        defer { sqlite3_finalize(statement) }
        bind(source.rawValue, at: 1, to: statement)
        var hashes = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            if let value = text(statement, 0) { hashes.insert(value) }
        }
        return hashes
    }

    public func events(source: UsageSource, from: Date, through: Date) async throws -> [NormalizedUsageEvent] {
        let sql = """
        SELECT event_key, session_id, occurred_at_ms,
               input_tokens, cache_create_5m_tokens, cache_create_1h_tokens,
               cache_read_tokens, output_tokens, reasoning_output_tokens,
               model, source_cost_micros_usd, origin_path_hash
        FROM usage_events
        WHERE source = ? AND occurred_at_ms >= ? AND occurred_at_ms < ?
        ORDER BY occurred_at_ms ASC
        """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        bind(source.rawValue, at: 1, to: statement)
        bind(Int64((from.timeIntervalSince1970 * 1_000).rounded()), at: 2, to: statement)
        bind(Int64((through.timeIntervalSince1970 * 1_000).rounded()), at: 3, to: statement)

        var result: [NormalizedUsageEvent] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let event = NormalizedUsageEvent(
                eventKey: text(statement, 0) ?? "",
                source: source,
                sessionID: text(statement, 1),
                occurredAt: Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, 2)) / 1_000),
                tokens: TokenBreakdown(
                    input: sqlite3_column_int64(statement, 3),
                    cacheCreate5m: sqlite3_column_int64(statement, 4),
                    cacheCreate1h: sqlite3_column_int64(statement, 5),
                    cacheRead: sqlite3_column_int64(statement, 6),
                    output: sqlite3_column_int64(statement, 7),
                    reasoningOutput: sqlite3_column_int64(statement, 8)
                ),
                model: text(statement, 9),
                sourceCostMicrosUSD: optionalInt64(statement, 10),
                originPathHash: text(statement, 11) ?? ""
            )
            result.append(event)
        }
        return result
    }

    /// Reduces matching rows one at a time so callers can build reports without
    /// materializing a potentially multi-gigabyte history in memory.
    public func reduceEvents<Result: Sendable>(
        source: UsageSource,
        from: Date,
        through: Date,
        initial: Result,
        _ update: @Sendable (inout Result, NormalizedUsageEvent) throws -> Void
    ) throws -> Result {
        let sql = """
        SELECT event_key, session_id, occurred_at_ms,
               input_tokens, cache_create_5m_tokens, cache_create_1h_tokens,
               cache_read_tokens, output_tokens, reasoning_output_tokens,
               model, source_cost_micros_usd, origin_path_hash
        FROM usage_events
        WHERE source = ? AND occurred_at_ms >= ? AND occurred_at_ms < ?
        ORDER BY occurred_at_ms ASC
        """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        bind(source.rawValue, at: 1, to: statement)
        bind(Int64((from.timeIntervalSince1970 * 1_000).rounded()), at: 2, to: statement)
        bind(Int64((through.timeIntervalSince1970 * 1_000).rounded()), at: 3, to: statement)

        var result = initial
        while sqlite3_step(statement) == SQLITE_ROW {
            let event = event(from: statement, source: source)
            try update(&result, event)
        }
        return result
    }

    public func dailyUsage(
        source: UsageSource,
        from: Date,
        through: Date,
        calendar: Calendar
    ) async throws -> [DailyUsage] {
        let storedEvents = try await events(source: source, from: from, through: through)
        let groups = Dictionary(grouping: storedEvents) { calendar.startOfDay(for: $0.occurredAt) }
        return groups.map { day, events in
            let tokens = events.reduce(into: TokenBreakdown()) { total, event in
                total.input += event.tokens.input
                total.cacheCreate5m += event.tokens.cacheCreate5m
                total.cacheCreate1h += event.tokens.cacheCreate1h
                total.cacheRead += event.tokens.cacheRead
                total.output += event.tokens.output
                total.reasoningOutput += event.tokens.reasoningOutput
            }
            return DailyUsage(
                day: day,
                source: source,
                tokens: tokens,
                knownCostMicrosUSD: events.compactMap(\.sourceCostMicrosUSD).reduce(0, +),
                unknownCostEventCount: events.filter { $0.sourceCostMicrosUSD == nil }.count
            )
        }.sorted { $0.day < $1.day }
    }

    /// Saves only observations in the current retention window. Pruning and
    /// insertion share one transaction so expired observations cannot reappear
    /// due to a partial update.
    public func upsertUsageLimits(_ samples: [UsageLimitSnapshot], now: Date) throws {
        let cutoff = UsageLimitHistoryPolicy.cutoff(relativeTo: now)
        let accepted = samples.filter {
            UsageLimitHistoryPolicy.contains($0.observedAt, relativeTo: now)
                && $0.usedPercent.isFinite && $0.windowMinutes > 0 && !$0.limitID.isEmpty
                && Int64(exactly: ($0.observedAt.timeIntervalSince1970 * 1_000).rounded()) != nil
                && ($0.resetsAt == nil || Int64(exactly: ($0.resetsAt!.timeIntervalSince1970 * 1_000).rounded()) != nil)
        }
        try execute("BEGIN IMMEDIATE")
        do {
            try deleteUsageLimitSamples(before: cutoff)
            try insertUsageLimitSamples(accepted)
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    public func usageLimitHistory(
        source: UsageSource,
        from: Date,
        through: Date
    ) throws -> [UsageLimitSnapshot] {
        let statement = try prepare("""
        SELECT limit_id, used_percent, window_minutes, resets_at_ms, observed_at_ms
        FROM usage_limit_samples
        WHERE source = ? AND observed_at_ms >= ? AND observed_at_ms < ?
        ORDER BY observed_at_ms ASC, limit_id ASC, window_minutes ASC, resets_at_ms ASC, used_percent ASC
        """)
        defer { sqlite3_finalize(statement) }
        bind(source.rawValue, at: 1, to: statement)
        bind(milliseconds(from), at: 2, to: statement)
        bind(milliseconds(through), at: 3, to: statement)

        var samples: [UsageLimitSnapshot] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let resetMilliseconds = sqlite3_column_int64(statement, 3)
            samples.append(UsageLimitSnapshot(
                source: source,
                limitID: text(statement, 0) ?? "",
                usedPercent: sqlite3_column_double(statement, 1),
                windowMinutes: Int(sqlite3_column_int64(statement, 2)),
                resetsAt: resetMilliseconds == Self.noResetMilliseconds
                    ? nil
                    : Date(timeIntervalSince1970: Double(resetMilliseconds) / 1_000),
                observedAt: Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, 4)) / 1_000)
            ))
        }
        return samples
    }

    public func pruneUsageLimitHistory(now: Date) throws {
        try deleteUsageLimitSamples(before: UsageLimitHistoryPolicy.cutoff(relativeTo: now))
    }

    public func deleteHistory() async throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try execute("DELETE FROM usage_events")
            try execute("DELETE FROM source_cursors")
            try execute("DELETE FROM usage_limit_samples")
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    public func cursor(for source: UsageSource, pathHash: String) throws -> FileCursor? {
        let statement = try prepare("""
        SELECT inode, size, mtime_ms, byte_offset, content_signature, parser_version
        FROM source_cursors WHERE source = ? AND path_hash = ?
        """)
        defer { sqlite3_finalize(statement) }
        bind(source.rawValue, at: 1, to: statement)
        bind(pathHash, at: 2, to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return FileCursor(
            inode: UInt64(bitPattern: sqlite3_column_int64(statement, 0)),
            size: UInt64(bitPattern: sqlite3_column_int64(statement, 1)),
            modifiedAtMilliseconds: sqlite3_column_int64(statement, 2),
            byteOffset: UInt64(bitPattern: sqlite3_column_int64(statement, 3)),
            contentSignature: text(statement, 4) ?? "",
            parserVersion: Int(sqlite3_column_int64(statement, 5))
        )
    }

    public func saveCursor(_ cursor: FileCursor, source: UsageSource, pathHash: String) throws {
        let statement = try prepare("""
        INSERT INTO source_cursors(source, path_hash, inode, size, mtime_ms, byte_offset, content_signature, parser_version)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(source, path_hash) DO UPDATE SET
          inode = excluded.inode, size = excluded.size,
          mtime_ms = excluded.mtime_ms, byte_offset = excluded.byte_offset,
          content_signature = excluded.content_signature, parser_version = excluded.parser_version
        """)
        defer { sqlite3_finalize(statement) }
        bind(source.rawValue, at: 1, to: statement)
        bind(pathHash, at: 2, to: statement)
        bind(Int64(bitPattern: cursor.inode), at: 3, to: statement)
        bind(Int64(bitPattern: cursor.size), at: 4, to: statement)
        bind(cursor.modifiedAtMilliseconds, at: 5, to: statement)
        bind(Int64(bitPattern: cursor.byteOffset), at: 6, to: statement)
        bind(cursor.contentSignature, at: 7, to: statement)
        bind(Int64(cursor.parserVersion), at: 8, to: statement)
        try stepDone(statement)
    }

    private static func configureAndMigrate(database: OpaquePointer?) throws {
        try execute("PRAGMA journal_mode = WAL", database: database)
        try execute("PRAGMA foreign_keys = ON", database: database)
        try execute("PRAGMA busy_timeout = 3000", database: database)
        try execute("""
        CREATE TABLE IF NOT EXISTS usage_events(
          event_key TEXT PRIMARY KEY,
          source TEXT NOT NULL,
          session_id TEXT,
          occurred_at_ms INTEGER NOT NULL,
          input_tokens INTEGER NOT NULL,
          cache_create_5m_tokens INTEGER NOT NULL,
          cache_create_1h_tokens INTEGER NOT NULL,
          cache_read_tokens INTEGER NOT NULL,
          output_tokens INTEGER NOT NULL,
          reasoning_output_tokens INTEGER NOT NULL,
          model TEXT,
          source_cost_micros_usd INTEGER,
          origin_path_hash TEXT NOT NULL
        )
        """, database: database)
        try execute("CREATE INDEX IF NOT EXISTS idx_usage_source_time ON usage_events(source, occurred_at_ms)", database: database)
        try execute("CREATE INDEX IF NOT EXISTS idx_usage_origin ON usage_events(source, origin_path_hash)", database: database)
        try execute("""
        CREATE TABLE IF NOT EXISTS usage_limit_samples(
          source TEXT NOT NULL,
          limit_id TEXT NOT NULL,
          used_percent REAL NOT NULL,
          window_minutes INTEGER NOT NULL,
          resets_at_ms INTEGER NOT NULL,
          observed_at_ms INTEGER NOT NULL,
          PRIMARY KEY(source, limit_id, window_minutes, resets_at_ms, observed_at_ms, used_percent)
        )
        """, database: database)
        try execute("CREATE INDEX IF NOT EXISTS idx_usage_limit_source_observed ON usage_limit_samples(source, observed_at_ms)", database: database)
        try execute("CREATE INDEX IF NOT EXISTS idx_usage_limit_observed ON usage_limit_samples(observed_at_ms)", database: database)
        try execute("""
        CREATE TABLE IF NOT EXISTS source_cursors(
          source TEXT NOT NULL,
          path_hash TEXT NOT NULL,
          inode INTEGER NOT NULL,
          size INTEGER NOT NULL,
          mtime_ms INTEGER NOT NULL,
          byte_offset INTEGER NOT NULL,
          content_signature TEXT NOT NULL DEFAULT '',
          parser_version INTEGER NOT NULL DEFAULT 1,
          PRIMARY KEY(source, path_hash)
        )
        """, database: database)
        try? execute("ALTER TABLE source_cursors ADD COLUMN content_signature TEXT NOT NULL DEFAULT ''", database: database)
        try? execute("ALTER TABLE source_cursors ADD COLUMN parser_version INTEGER NOT NULL DEFAULT 1", database: database)
        try execute("PRAGMA user_version = 3", database: database)
    }

    private static func execute(_ sql: String, database: OpaquePointer?) throws {
        guard let database else { throw UsageStoreError.sqlite("database closed") }
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(errorMessage)
            throw UsageStoreError.sqlite(message)
        }
    }

    private func execute(_ sql: String) throws {
        guard let database else { throw UsageStoreError.sqlite("database closed") }
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(errorMessage)
            throw UsageStoreError.sqlite(message)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        guard let database else { throw UsageStoreError.sqlite("database closed") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw UsageStoreError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
        return statement
    }

    private func stepDone(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "statement failed"
            throw UsageStoreError.sqlite(message)
        }
    }

    private func insert(_ events: [NormalizedUsageEvent]) throws {
        guard !events.isEmpty else { return }
        let statement = try prepare("""
        INSERT OR IGNORE INTO usage_events(
          event_key, source, session_id, occurred_at_ms,
          input_tokens, cache_create_5m_tokens, cache_create_1h_tokens,
          cache_read_tokens, output_tokens, reasoning_output_tokens,
          model, source_cost_micros_usd, origin_path_hash
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """)
        defer { sqlite3_finalize(statement) }
        for event in events {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            bind(event.eventKey, at: 1, to: statement)
            bind(event.source.rawValue, at: 2, to: statement)
            bind(event.sessionID, at: 3, to: statement)
            bind(Int64((event.occurredAt.timeIntervalSince1970 * 1_000).rounded()), at: 4, to: statement)
            bind(event.tokens.input, at: 5, to: statement)
            bind(event.tokens.cacheCreate5m, at: 6, to: statement)
            bind(event.tokens.cacheCreate1h, at: 7, to: statement)
            bind(event.tokens.cacheRead, at: 8, to: statement)
            bind(event.tokens.output, at: 9, to: statement)
            bind(event.tokens.reasoningOutput, at: 10, to: statement)
            bind(event.model, at: 11, to: statement)
            bind(event.sourceCostMicrosUSD, at: 12, to: statement)
            bind(event.originPathHash, at: 13, to: statement)
            try stepDone(statement)
        }
    }

    private static let noResetMilliseconds = Int64.min

    private func deleteUsageLimitSamples(before cutoff: Date) throws {
        let statement = try prepare("DELETE FROM usage_limit_samples WHERE observed_at_ms < ?")
        defer { sqlite3_finalize(statement) }
        bind(milliseconds(cutoff), at: 1, to: statement)
        try stepDone(statement)
    }

    private func insertUsageLimitSamples(_ samples: [UsageLimitSnapshot]) throws {
        guard !samples.isEmpty else { return }
        let statement = try prepare("""
        INSERT OR IGNORE INTO usage_limit_samples(
          source, limit_id, used_percent, window_minutes, resets_at_ms, observed_at_ms
        ) VALUES (?, ?, ?, ?, ?, ?)
        """)
        defer { sqlite3_finalize(statement) }
        for sample in samples {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            bind(sample.source.rawValue, at: 1, to: statement)
            bind(sample.limitID, at: 2, to: statement)
            sqlite3_bind_double(statement, 3, sample.usedPercent)
            bind(Int64(sample.windowMinutes), at: 4, to: statement)
            bind(sample.resetsAt.map(milliseconds) ?? Self.noResetMilliseconds, at: 5, to: statement)
            bind(milliseconds(sample.observedAt), at: 6, to: statement)
            try stepDone(statement)
        }
    }

    private func event(from statement: OpaquePointer, source: UsageSource) -> NormalizedUsageEvent {
        NormalizedUsageEvent(
            eventKey: text(statement, 0) ?? "",
            source: source,
            sessionID: text(statement, 1),
            occurredAt: Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, 2)) / 1_000),
            tokens: TokenBreakdown(
                input: sqlite3_column_int64(statement, 3),
                cacheCreate5m: sqlite3_column_int64(statement, 4),
                cacheCreate1h: sqlite3_column_int64(statement, 5),
                cacheRead: sqlite3_column_int64(statement, 6),
                output: sqlite3_column_int64(statement, 7),
                reasoningOutput: sqlite3_column_int64(statement, 8)
            ),
            model: text(statement, 9),
            sourceCostMicrosUSD: optionalInt64(statement, 10),
            originPathHash: text(statement, 11) ?? ""
        )
    }
}

private final class SQLiteConnection: @unchecked Sendable {
    let handle: OpaquePointer

    init(handle: OpaquePointer) {
        self.handle = handle
    }

    deinit {
        sqlite3_close(handle)
    }
}

public struct FileCursor: Equatable, Sendable {
    public let inode: UInt64
    public let size: UInt64
    public let modifiedAtMilliseconds: Int64
    public let byteOffset: UInt64
    public let contentSignature: String
    public let parserVersion: Int

    public init(
        inode: UInt64,
        size: UInt64,
        modifiedAtMilliseconds: Int64,
        byteOffset: UInt64,
        contentSignature: String = "",
        parserVersion: Int = 1
    ) {
        self.inode = inode
        self.size = size
        self.modifiedAtMilliseconds = modifiedAtMilliseconds
        self.byteOffset = byteOffset
        self.contentSignature = contentSignature
        self.parserVersion = parserVersion
    }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private func bind(_ value: String?, at index: Int32, to statement: OpaquePointer) {
    guard let value else {
        sqlite3_bind_null(statement, index)
        return
    }
    sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
}

private func bind(_ value: Int64?, at index: Int32, to statement: OpaquePointer) {
    guard let value else {
        sqlite3_bind_null(statement, index)
        return
    }
    sqlite3_bind_int64(statement, index, value)
}

private func text(_ statement: OpaquePointer, _ index: Int32) -> String? {
    guard sqlite3_column_type(statement, index) != SQLITE_NULL,
          let value = sqlite3_column_text(statement, index) else { return nil }
    return String(cString: value)
}

private func optionalInt64(_ statement: OpaquePointer, _ index: Int32) -> Int64? {
    sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, index)
}

private func milliseconds(_ date: Date) -> Int64 {
    Int64((date.timeIntervalSince1970 * 1_000).rounded())
}
