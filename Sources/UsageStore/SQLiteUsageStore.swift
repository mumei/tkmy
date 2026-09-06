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
        try Self.configureAndMigrate(database: handle, databaseURL: resolvedURL)
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
        let accepted = samples.compactMap { sample -> UsageLimitEvidence? in
            guard
                UsageLimitHistoryPolicy.contains(sample.observedAt, relativeTo: now)
                && sample.usedPercent.isFinite && sample.windowMinutes > 0 && !sample.limitID.isEmpty,
                let observedAtMS = exactMilliseconds(sample.observedAt),
                sample.resetsAt == nil || (
                    exactMilliseconds(sample.resetsAt!) != nil
                        && exactMilliseconds(sample.resetsAt!) != Self.noResetMilliseconds
                )
            else { return nil }
            return UsageLimitEvidence(
                key: UsageLimitSeriesKey(sample),
                usedPercent: sample.usedPercent,
                resetsAtMS: sample.resetsAt.flatMap(exactMilliseconds),
                observedAtMS: observedAtMS
            )
        }
        try execute("BEGIN IMMEDIATE")
        do {
            var rebuildKeys = try pruneUsageLimitEvidence(before: milliseconds(cutoff))
            let grouped = Dictionary(grouping: Set(accepted), by: \.key)
            for (key, candidateEvidenceSet) in grouped {
                let priorLast = try lastUsageLimitEvidence(for: key)
                let newEvidence = try mergeUsageLimitEvidence(candidateEvidenceSet.sorted(), for: key)
                guard !newEvidence.isEmpty else { continue }
                if rebuildKeys.contains(key)
                    || priorLast == nil
                    || newEvidence.contains(where: { $0.observedAtMS <= priorLast!.observedAtMS }) {
                    rebuildKeys.insert(key)
                } else {
                    try appendUsageLimitChangePoints(newEvidence, for: key)
                }
            }
            for key in rebuildKeys {
                try rebuildUsageLimitChangePoints(for: key)
            }
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
        SELECT limit_id, used_percent, window_minutes, resets_at_ms,
               observed_at_ms, last_observed_at_ms, reset_epoch_id,
               reset_min_ms, reset_max_ms, change_ordinal
        FROM usage_limit_samples
        WHERE source = ? AND last_observed_at_ms >= ? AND observed_at_ms < ?
        ORDER BY observed_at_ms ASC, limit_id ASC, window_minutes ASC, change_ordinal ASC
        """)
        defer { sqlite3_finalize(statement) }
        bind(source.rawValue, at: 1, to: statement)
        bind(milliseconds(from), at: 2, to: statement)
        bind(milliseconds(through), at: 3, to: statement)

        var samples: [UsageLimitSnapshot] = []
        var resultCode = sqlite3_step(statement)
        while resultCode == SQLITE_ROW {
            let resetMilliseconds = sqlite3_column_int64(statement, 3)
            let observedAtMS = sqlite3_column_int64(statement, 4)
            let storedLastObservedAtMS = sqlite3_column_int64(statement, 5)
            let resetMin = sqlite3_column_int64(statement, 7)
            let resetMax = sqlite3_column_int64(statement, 8)
            let key = UsageLimitSeriesKey(
                source: source,
                limitID: text(statement, 0) ?? "",
                windowMinutes: Int(sqlite3_column_int64(statement, 2))
            )
            let queryEndMS = milliseconds(through)
            let lastObservedAtMS = storedLastObservedAtMS < queryEndMS
                ? storedLastObservedAtMS
                : try latestConfirmation(
                    for: key,
                    usedPercent: sqlite3_column_double(statement, 1),
                    resetMinimum: resetMin == Self.noResetMilliseconds ? nil : resetMin,
                    resetMaximum: resetMax == Self.noResetMilliseconds ? nil : resetMax,
                    from: observedAtMS,
                    through: queryEndMS,
                    noLaterThan: storedLastObservedAtMS
                ) ?? observedAtMS
            samples.append(UsageLimitSnapshot(
                source: source,
                limitID: key.limitID,
                usedPercent: sqlite3_column_double(statement, 1),
                windowMinutes: key.windowMinutes,
                resetsAt: resetMilliseconds == Self.noResetMilliseconds
                    ? nil
                    : Date(timeIntervalSince1970: Double(resetMilliseconds) / 1_000),
                observedAt: Date(timeIntervalSince1970: Double(observedAtMS) / 1_000),
                lastObservedAt: Date(timeIntervalSince1970: Double(lastObservedAtMS) / 1_000),
                resetEpochID: text(statement, 6)
            ))
            resultCode = sqlite3_step(statement)
        }
        try ensureQueryCompleted(resultCode)
        return samples
    }

    public func pruneUsageLimitHistory(now: Date) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            let keys = try pruneUsageLimitEvidence(before: milliseconds(UsageLimitHistoryPolicy.cutoff(relativeTo: now)))
            for key in keys { try rebuildUsageLimitChangePoints(for: key) }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    public func deleteHistory() async throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try execute("DELETE FROM usage_events")
            try execute("DELETE FROM source_cursors")
            try execute("DELETE FROM usage_limit_samples")
            try execute("DELETE FROM usage_limit_evidence_pages")
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

    private static func configureAndMigrate(database: OpaquePointer?, databaseURL: URL) throws {
        try execute("PRAGMA journal_mode = WAL", database: database)
        try execute("PRAGMA foreign_keys = ON", database: database)
        try execute("PRAGMA busy_timeout = 3000", database: database)
        let version = try integerQuery("PRAGMA user_version", database: database)
        guard version <= 4 else {
            throw UsageStoreError.sqlite("unsupported database schema version \(version)")
        }
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

        if try isSchema3UsageLimitTable(database: database) {
            try backupBeforeQuotaMigration(database: database, databaseURL: databaseURL)
            try migrateSchema3UsageLimits(database: database)
        } else {
            try createUsageLimitSchema(database: database)
        }
        try execute("PRAGMA user_version = 4", database: database)
    }

    private static func createUsageLimitSchema(database: OpaquePointer?, tableSuffix: String = "") throws {
        let points = "usage_limit_samples\(tableSuffix)"
        let evidence = "usage_limit_evidence_pages\(tableSuffix)"
        try execute("""
        CREATE TABLE IF NOT EXISTS \(points)(
          source TEXT NOT NULL,
          limit_id TEXT NOT NULL,
          window_minutes INTEGER NOT NULL,
          change_ordinal INTEGER NOT NULL,
          used_percent REAL NOT NULL,
          resets_at_ms INTEGER NOT NULL,
          observed_at_ms INTEGER NOT NULL,
          last_observed_at_ms INTEGER NOT NULL,
          reset_epoch_id TEXT NOT NULL,
          reset_min_ms INTEGER NOT NULL,
          reset_max_ms INTEGER NOT NULL,
          PRIMARY KEY(source, limit_id, window_minutes, change_ordinal)
        ) WITHOUT ROWID
        """, database: database)
        try execute("""
        CREATE TABLE IF NOT EXISTS \(evidence)(
          source TEXT NOT NULL,
          limit_id TEXT NOT NULL,
          window_minutes INTEGER NOT NULL,
          day_start_ms INTEGER NOT NULL,
          evidence BLOB NOT NULL,
          PRIMARY KEY(source, limit_id, window_minutes, day_start_ms)
        ) WITHOUT ROWID
        """, database: database)
        if tableSuffix.isEmpty {
            try execute("CREATE INDEX IF NOT EXISTS idx_usage_limit_source_observed ON usage_limit_samples(source, observed_at_ms)", database: database)
            try execute("CREATE INDEX IF NOT EXISTS idx_usage_limit_last_observed ON usage_limit_samples(last_observed_at_ms)", database: database)
        }
    }

    private static func integerQuery(_ sql: String, database: OpaquePointer?) throws -> Int64 {
        guard let database else { throw UsageStoreError.sqlite("database closed") }
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

    private static func isSchema3UsageLimitTable(database: OpaquePointer?) throws -> Bool {
        guard let database else { throw UsageStoreError.sqlite("database closed") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA table_info(usage_limit_samples)", -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw UsageStoreError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        var columns = Set<String>()
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            if let name = text(statement, 1) { columns.insert(name) }
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else {
            throw UsageStoreError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
        return columns.contains("resets_at_ms")
            && columns.contains("observed_at_ms")
            && !columns.contains("last_observed_at_ms")
    }

    private static func backupBeforeQuotaMigration(database: OpaquePointer?, databaseURL: URL) throws {
        guard let database else { throw UsageStoreError.sqlite("database closed") }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmssSSS'Z'"
        let backupURL = databaseURL.deletingPathExtension().appendingPathExtension(
            "sqlite3.schema3-backup-\(formatter.string(from: Date()))-\(UUID().uuidString).sqlite3"
        )
        var destination: OpaquePointer?
        guard sqlite3_open_v2(
            backupURL.path,
            &destination,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK, let destination else {
            let message = destination.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            if let destination { sqlite3_close(destination) }
            throw UsageStoreError.sqlite("quota migration backup failed: \(message)")
        }
        var backupSucceeded = false
        defer {
            sqlite3_close(destination)
            if !backupSucceeded { try? FileManager.default.removeItem(at: backupURL) }
        }
        guard let backup = sqlite3_backup_init(destination, "main", database, "main") else {
            throw UsageStoreError.sqlite("quota migration backup failed: \(String(cString: sqlite3_errmsg(destination)))")
        }
        let result = sqlite3_backup_step(backup, -1)
        let finishResult = sqlite3_backup_finish(backup)
        guard result == SQLITE_DONE, finishResult == SQLITE_OK else {
            throw UsageStoreError.sqlite("quota migration backup failed: \(String(cString: sqlite3_errmsg(destination)))")
        }
        // Make the backup self-contained before allowing a destructive schema
        // change. The source database keeps its existing WAL configuration.
        var journalMode: OpaquePointer?
        guard sqlite3_prepare_v2(destination, "PRAGMA journal_mode = DELETE", -1, &journalMode, nil) == SQLITE_OK,
              let journalMode else {
            throw UsageStoreError.sqlite("quota migration backup checkpoint failed")
        }
        defer { sqlite3_finalize(journalMode) }
        guard sqlite3_step(journalMode) == SQLITE_ROW, text(journalMode, 0) == "delete",
              sqlite3_step(journalMode) == SQLITE_DONE else {
            throw UsageStoreError.sqlite("quota migration backup checkpoint failed")
        }
        var check: OpaquePointer?
        guard sqlite3_prepare_v2(destination, "PRAGMA quick_check", -1, &check, nil) == SQLITE_OK, let check else {
            throw UsageStoreError.sqlite("quota migration backup verification failed")
        }
        defer { sqlite3_finalize(check) }
        guard sqlite3_step(check) == SQLITE_ROW, text(check, 0) == "ok",
              sqlite3_step(check) == SQLITE_DONE else {
            throw UsageStoreError.sqlite("quota migration backup verification failed")
        }
        backupSucceeded = true
    }

    private static func migrateSchema3UsageLimits(database: OpaquePointer?) throws {
        guard let database else { throw UsageStoreError.sqlite("database closed") }
        let migrationNow = Date()
        let cutoffMS = milliseconds(UsageLimitHistoryPolicy.cutoff(relativeTo: migrationNow))
        let nowMS = milliseconds(migrationNow)
        try execute("BEGIN IMMEDIATE", database: database)
        do {
            try execute("DROP TABLE IF EXISTS usage_limit_samples_v4", database: database)
            try execute("DROP TABLE IF EXISTS usage_limit_evidence_pages_v4", database: database)
            try createUsageLimitSchema(database: database, tableSuffix: "_v4")

            var read: OpaquePointer?
            let sql = """
            SELECT source, limit_id, window_minutes, used_percent, resets_at_ms, observed_at_ms
            FROM usage_limit_samples
            WHERE observed_at_ms >= ? AND observed_at_ms <= ?
            ORDER BY source, limit_id, window_minutes, observed_at_ms, used_percent, resets_at_ms
            """
            guard sqlite3_prepare_v2(database, sql, -1, &read, nil) == SQLITE_OK, let read else {
                throw UsageStoreError.sqlite(String(cString: sqlite3_errmsg(database)))
            }
            defer { sqlite3_finalize(read) }
            bind(cutoffMS, at: 1, to: read)
            bind(nowMS, at: 2, to: read)

            var currentKey: UsageLimitSeriesKey?
            var seriesEvidence: [UsageLimitEvidence] = []
            func flushSeries() throws {
                guard let key = currentKey else { return }
                let unique = Array(Set(seriesEvidence)).sorted()
                for (dayStart, page) in Dictionary(grouping: unique, by: {
                    UsageLimitEvidenceCodec.dayStart(for: $0.observedAtMS)
                }) {
                    try insertMigrationEvidencePage(page, key: key, dayStartMS: dayStart, database: database)
                }
                try insertMigrationChangePoints(buildUsageLimitChangePoints(unique, key: key), database: database)
                seriesEvidence.removeAll(keepingCapacity: true)
            }

            var readResult = sqlite3_step(read)
            while readResult == SQLITE_ROW {
                guard let sourceText = text(read, 0), let source = UsageSource(rawValue: sourceText),
                      let limitID = text(read, 1), !limitID.isEmpty else {
                    throw UsageStoreError.sqlite("quota migration found an invalid series key")
                }
                let windowMinutes = Int(sqlite3_column_int64(read, 2))
                let usedPercent = sqlite3_column_double(read, 3)
                guard windowMinutes > 0, usedPercent.isFinite else {
                    throw UsageStoreError.sqlite("quota migration found an invalid observation")
                }
                let key = UsageLimitSeriesKey(
                    source: source,
                    limitID: limitID,
                    windowMinutes: windowMinutes
                )
                if let currentKey, currentKey != key { try flushSeries() }
                currentKey = key
                let rawReset = sqlite3_column_int64(read, 4)
                seriesEvidence.append(UsageLimitEvidence(
                    key: key,
                    usedPercent: usedPercent,
                    resetsAtMS: rawReset == noResetMilliseconds ? nil : rawReset,
                    observedAtMS: sqlite3_column_int64(read, 5)
                ))
                readResult = sqlite3_step(read)
            }
            guard readResult == SQLITE_DONE else {
                throw UsageStoreError.sqlite("quota migration read failed: \(String(cString: sqlite3_errmsg(database)))")
            }
            try flushSeries()

            try execute("DROP TABLE usage_limit_samples", database: database)
            try execute("ALTER TABLE usage_limit_samples_v4 RENAME TO usage_limit_samples", database: database)
            try execute("ALTER TABLE usage_limit_evidence_pages_v4 RENAME TO usage_limit_evidence_pages", database: database)
            try execute("CREATE INDEX idx_usage_limit_source_observed ON usage_limit_samples(source, observed_at_ms)", database: database)
            try execute("CREATE INDEX idx_usage_limit_last_observed ON usage_limit_samples(last_observed_at_ms)", database: database)
            try execute("COMMIT", database: database)
        } catch {
            try? execute("ROLLBACK", database: database)
            throw error
        }
    }

    private static func insertMigrationEvidencePage(
        _ evidence: [UsageLimitEvidence],
        key: UsageLimitSeriesKey,
        dayStartMS: Int64,
        database: OpaquePointer
    ) throws {
        var statement: OpaquePointer?
        let sql = """
        INSERT INTO usage_limit_evidence_pages_v4(source, limit_id, window_minutes, day_start_ms, evidence)
        VALUES (?, ?, ?, ?, ?)
        """
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw UsageStoreError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        bind(key.source.rawValue, at: 1, to: statement)
        bind(key.limitID, at: 2, to: statement)
        bind(Int64(key.windowMinutes), at: 3, to: statement)
        bind(dayStartMS, at: 4, to: statement)
        bind(UsageLimitEvidenceCodec.encode(evidence, dayStartMS: dayStartMS), at: 5, to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw UsageStoreError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
    }

    private static func insertMigrationChangePoints(
        _ points: [UsageLimitChangePoint],
        database: OpaquePointer
    ) throws {
        guard !points.isEmpty else { return }
        var statement: OpaquePointer?
        let sql = """
        INSERT INTO usage_limit_samples_v4(
          source, limit_id, window_minutes, change_ordinal, used_percent,
          resets_at_ms, observed_at_ms, last_observed_at_ms, reset_epoch_id,
          reset_min_ms, reset_max_ms
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw UsageStoreError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        for point in points {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            bind(point.key.source.rawValue, at: 1, to: statement)
            bind(point.key.limitID, at: 2, to: statement)
            bind(Int64(point.key.windowMinutes), at: 3, to: statement)
            bind(point.ordinal, at: 4, to: statement)
            sqlite3_bind_double(statement, 5, point.usedPercent)
            bind(point.resetsAtMS ?? noResetMilliseconds, at: 6, to: statement)
            bind(point.observedAtMS, at: 7, to: statement)
            bind(point.lastObservedAtMS, at: 8, to: statement)
            bind(point.resetEpochID, at: 9, to: statement)
            bind(point.resetMinMS ?? noResetMilliseconds, at: 10, to: statement)
            bind(point.resetMaxMS ?? noResetMilliseconds, at: 11, to: statement)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw UsageStoreError.sqlite(String(cString: sqlite3_errmsg(database)))
            }
        }
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

    private func ensureQueryCompleted(_ resultCode: Int32) throws {
        guard resultCode == SQLITE_DONE else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "query failed"
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

    private func pruneUsageLimitEvidence(before cutoffMS: Int64) throws -> Set<UsageLimitSeriesKey> {
        let cutoffDay = UsageLimitEvidenceCodec.dayStart(for: cutoffMS)
        var affected = Set<UsageLimitSeriesKey>()

        let oldPages = try prepare("""
        SELECT source, limit_id, window_minutes
        FROM usage_limit_evidence_pages WHERE day_start_ms < ?
        """)
        defer { sqlite3_finalize(oldPages) }
        bind(cutoffDay, at: 1, to: oldPages)
        var oldPageResult = sqlite3_step(oldPages)
        while oldPageResult == SQLITE_ROW {
            if let key = usageLimitKey(from: oldPages) { affected.insert(key) }
            oldPageResult = sqlite3_step(oldPages)
        }
        try ensureQueryCompleted(oldPageResult)
        let deleteOld = try prepare("DELETE FROM usage_limit_evidence_pages WHERE day_start_ms < ?")
        defer { sqlite3_finalize(deleteOld) }
        bind(cutoffDay, at: 1, to: deleteOld)
        try stepDone(deleteOld)

        let boundary = try prepare("""
        SELECT source, limit_id, window_minutes, evidence
        FROM usage_limit_evidence_pages WHERE day_start_ms = ?
        """)
        defer { sqlite3_finalize(boundary) }
        bind(cutoffDay, at: 1, to: boundary)
        var boundaryUpdates: [(UsageLimitSeriesKey, [UsageLimitEvidence])] = []
        var boundaryResult = sqlite3_step(boundary)
        while boundaryResult == SQLITE_ROW {
            if let key = usageLimitKey(from: boundary), let blob = data(boundary, 3) {
                let decoded = try UsageLimitEvidenceCodec.decode(blob, key: key, dayStartMS: cutoffDay)
                let retained = decoded.filter { $0.observedAtMS >= cutoffMS }
                if retained.count != decoded.count {
                    affected.insert(key)
                    boundaryUpdates.append((key, retained))
                }
            }
            boundaryResult = sqlite3_step(boundary)
        }
        try ensureQueryCompleted(boundaryResult)
        for (key, retained) in boundaryUpdates {
            if retained.isEmpty {
                try deleteEvidencePage(for: key, dayStartMS: cutoffDay)
            } else {
                try saveEvidencePage(retained, for: key, dayStartMS: cutoffDay)
            }
        }
        return affected
    }

    private func mergeUsageLimitEvidence(
        _ evidence: [UsageLimitEvidence],
        for key: UsageLimitSeriesKey
    ) throws -> [UsageLimitEvidence] {
        var inserted: [UsageLimitEvidence] = []
        for (dayStart, additions) in Dictionary(grouping: evidence, by: {
            UsageLimitEvidenceCodec.dayStart(for: $0.observedAtMS)
        }) {
            let existing = Set(try evidencePage(for: key, dayStartMS: dayStart))
            let newItems = additions.filter { !existing.contains($0) }
            guard !newItems.isEmpty else { continue }
            var merged = existing
            merged.formUnion(newItems)
            try saveEvidencePage(Array(merged), for: key, dayStartMS: dayStart)
            inserted.append(contentsOf: newItems)
        }
        return inserted.sorted()
    }

    private func evidencePage(for key: UsageLimitSeriesKey, dayStartMS: Int64) throws -> [UsageLimitEvidence] {
        let statement = try prepare("""
        SELECT evidence FROM usage_limit_evidence_pages
        WHERE source = ? AND limit_id = ? AND window_minutes = ? AND day_start_ms = ?
        """)
        defer { sqlite3_finalize(statement) }
        bind(key.source.rawValue, at: 1, to: statement)
        bind(key.limitID, at: 2, to: statement)
        bind(Int64(key.windowMinutes), at: 3, to: statement)
        bind(dayStartMS, at: 4, to: statement)
        let result = sqlite3_step(statement)
        guard result == SQLITE_ROW else {
            try ensureQueryCompleted(result)
            return []
        }
        guard let blob = data(statement, 0) else {
            throw UsageStoreError.sqlite("quota evidence page is missing its payload")
        }
        return try UsageLimitEvidenceCodec.decode(blob, key: key, dayStartMS: dayStartMS)
    }

    private func saveEvidencePage(
        _ evidence: [UsageLimitEvidence],
        for key: UsageLimitSeriesKey,
        dayStartMS: Int64
    ) throws {
        let statement = try prepare("""
        INSERT INTO usage_limit_evidence_pages(source, limit_id, window_minutes, day_start_ms, evidence)
        VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(source, limit_id, window_minutes, day_start_ms)
        DO UPDATE SET evidence = excluded.evidence
        """)
        defer { sqlite3_finalize(statement) }
        bind(key.source.rawValue, at: 1, to: statement)
        bind(key.limitID, at: 2, to: statement)
        bind(Int64(key.windowMinutes), at: 3, to: statement)
        bind(dayStartMS, at: 4, to: statement)
        bind(UsageLimitEvidenceCodec.encode(evidence, dayStartMS: dayStartMS), at: 5, to: statement)
        try stepDone(statement)
    }

    private func deleteEvidencePage(for key: UsageLimitSeriesKey, dayStartMS: Int64) throws {
        let statement = try prepare("""
        DELETE FROM usage_limit_evidence_pages
        WHERE source = ? AND limit_id = ? AND window_minutes = ? AND day_start_ms = ?
        """)
        defer { sqlite3_finalize(statement) }
        bind(key.source.rawValue, at: 1, to: statement)
        bind(key.limitID, at: 2, to: statement)
        bind(Int64(key.windowMinutes), at: 3, to: statement)
        bind(dayStartMS, at: 4, to: statement)
        try stepDone(statement)
    }

    private func allUsageLimitEvidence(for key: UsageLimitSeriesKey) throws -> [UsageLimitEvidence] {
        let statement = try prepare("""
        SELECT day_start_ms, evidence FROM usage_limit_evidence_pages
        WHERE source = ? AND limit_id = ? AND window_minutes = ?
        ORDER BY day_start_ms
        """)
        defer { sqlite3_finalize(statement) }
        bind(key.source.rawValue, at: 1, to: statement)
        bind(key.limitID, at: 2, to: statement)
        bind(Int64(key.windowMinutes), at: 3, to: statement)
        var result: [UsageLimitEvidence] = []
        var resultCode = sqlite3_step(statement)
        while resultCode == SQLITE_ROW {
            let dayStart = sqlite3_column_int64(statement, 0)
            if let blob = data(statement, 1) {
                result.append(contentsOf: try UsageLimitEvidenceCodec.decode(blob, key: key, dayStartMS: dayStart))
            }
            resultCode = sqlite3_step(statement)
        }
        try ensureQueryCompleted(resultCode)
        return result
    }

    private func latestConfirmation(
        for key: UsageLimitSeriesKey,
        usedPercent: Double,
        resetMinimum: Int64?,
        resetMaximum: Int64?,
        from startMS: Int64,
        through endMS: Int64,
        noLaterThan lastMS: Int64
    ) throws -> Int64? {
        let firstDay = UsageLimitEvidenceCodec.dayStart(for: startMS)
        let lastDay = UsageLimitEvidenceCodec.dayStart(for: min(endMS - 1, lastMS))
        let statement = try prepare("""
        SELECT day_start_ms, evidence FROM usage_limit_evidence_pages
        WHERE source = ? AND limit_id = ? AND window_minutes = ?
          AND day_start_ms >= ? AND day_start_ms <= ?
        ORDER BY day_start_ms DESC
        """)
        defer { sqlite3_finalize(statement) }
        bind(key.source.rawValue, at: 1, to: statement)
        bind(key.limitID, at: 2, to: statement)
        bind(Int64(key.windowMinutes), at: 3, to: statement)
        bind(firstDay, at: 4, to: statement)
        bind(lastDay, at: 5, to: statement)
        var latest: Int64?
        var resultCode = sqlite3_step(statement)
        while resultCode == SQLITE_ROW {
            let dayStart = sqlite3_column_int64(statement, 0)
            if let blob = data(statement, 1) {
                for item in try UsageLimitEvidenceCodec.decode(blob, key: key, dayStartMS: dayStart) {
                    guard item.observedAtMS >= startMS, item.observedAtMS < endMS,
                          item.observedAtMS <= lastMS,
                          item.usedPercent.bitPattern == usedPercent.bitPattern,
                          resetMatches(item.resetsAtMS, minimum: resetMinimum, maximum: resetMaximum)
                    else { continue }
                    latest = max(latest ?? item.observedAtMS, item.observedAtMS)
                }
            }
            if latest != nil { break }
            resultCode = sqlite3_step(statement)
        }
        if latest == nil { try ensureQueryCompleted(resultCode) }
        return latest
    }

    private func lastUsageLimitEvidence(for key: UsageLimitSeriesKey) throws -> UsageLimitEvidence? {
        let statement = try prepare("""
        SELECT day_start_ms, evidence FROM usage_limit_evidence_pages
        WHERE source = ? AND limit_id = ? AND window_minutes = ?
        ORDER BY day_start_ms DESC LIMIT 1
        """)
        defer { sqlite3_finalize(statement) }
        bind(key.source.rawValue, at: 1, to: statement)
        bind(key.limitID, at: 2, to: statement)
        bind(Int64(key.windowMinutes), at: 3, to: statement)
        let result = sqlite3_step(statement)
        guard result == SQLITE_ROW else {
            try ensureQueryCompleted(result)
            return nil
        }
        guard let blob = data(statement, 1) else {
            throw UsageStoreError.sqlite("quota evidence page is missing its payload")
        }
        let dayStart = sqlite3_column_int64(statement, 0)
        return try UsageLimitEvidenceCodec.decode(blob, key: key, dayStartMS: dayStart).max()
    }

    private func rebuildUsageLimitChangePoints(for key: UsageLimitSeriesKey) throws {
        let evidence = try allUsageLimitEvidence(for: key)
        let points = buildUsageLimitChangePoints(evidence, key: key)
        let delete = try prepare("""
        DELETE FROM usage_limit_samples WHERE source = ? AND limit_id = ? AND window_minutes = ?
        """)
        defer { sqlite3_finalize(delete) }
        bind(key.source.rawValue, at: 1, to: delete)
        bind(key.limitID, at: 2, to: delete)
        bind(Int64(key.windowMinutes), at: 3, to: delete)
        try stepDone(delete)
        try insertUsageLimitChangePoints(points)
    }

    private func appendUsageLimitChangePoints(_ evidence: [UsageLimitEvidence], for key: UsageLimitSeriesKey) throws {
        guard !evidence.isEmpty else { return }
        guard var current = try lastUsageLimitChangePoint(for: key) else {
            try rebuildUsageLimitChangePoints(for: key)
            return
        }
        let originalOrdinal = current.ordinal
        var insertions: [UsageLimitChangePoint] = []
        for item in evidence.sorted() {
            let gap = isUsageLimitGap(from: current.lastObservedAtMS, to: item.observedAtMS)
            let resetFits = resetBelongsToEpoch(item.resetsAtMS, minimum: current.resetMinMS, maximum: current.resetMaxMS)
            let startsEpoch = gap || !resetFits
            if startsEpoch {
                current = UsageLimitChangePoint(
                    key: key,
                    ordinal: current.ordinal + 1,
                    usedPercent: item.usedPercent,
                    resetsAtMS: item.resetsAtMS,
                    observedAtMS: item.observedAtMS,
                    lastObservedAtMS: item.observedAtMS,
                    resetEpochID: makeResetEpochID(key: key, evidence: item),
                    resetMinMS: item.resetsAtMS,
                    resetMaxMS: item.resetsAtMS
                )
                insertions.append(current)
            } else if item.usedPercent.bitPattern != current.usedPercent.bitPattern {
                current = UsageLimitChangePoint(
                    key: key,
                    ordinal: current.ordinal + 1,
                    usedPercent: item.usedPercent,
                    resetsAtMS: current.resetsAtMS,
                    observedAtMS: item.observedAtMS,
                    lastObservedAtMS: item.observedAtMS,
                    resetEpochID: current.resetEpochID,
                    resetMinMS: expandedMinimum(current.resetMinMS, item.resetsAtMS),
                    resetMaxMS: expandedMaximum(current.resetMaxMS, item.resetsAtMS)
                )
                insertions.append(current)
            } else {
                current.lastObservedAtMS = item.observedAtMS
                current.resetMinMS = expandedMinimum(current.resetMinMS, item.resetsAtMS)
                current.resetMaxMS = expandedMaximum(current.resetMaxMS, item.resetsAtMS)
                if insertions.isEmpty {
                    try updateUsageLimitChangePoint(current)
                } else {
                    insertions[insertions.count - 1] = current
                }
            }
        }
        if current.ordinal == originalOrdinal {
            try updateUsageLimitChangePoint(current)
        } else {
            try insertUsageLimitChangePoints(insertions)
        }
    }

    private func lastUsageLimitChangePoint(for key: UsageLimitSeriesKey) throws -> UsageLimitChangePoint? {
        let statement = try prepare("""
        SELECT change_ordinal, used_percent, resets_at_ms, observed_at_ms,
               last_observed_at_ms, reset_epoch_id, reset_min_ms, reset_max_ms
        FROM usage_limit_samples
        WHERE source = ? AND limit_id = ? AND window_minutes = ?
        ORDER BY change_ordinal DESC LIMIT 1
        """)
        defer { sqlite3_finalize(statement) }
        bind(key.source.rawValue, at: 1, to: statement)
        bind(key.limitID, at: 2, to: statement)
        bind(Int64(key.windowMinutes), at: 3, to: statement)
        let result = sqlite3_step(statement)
        guard result == SQLITE_ROW else {
            try ensureQueryCompleted(result)
            return nil
        }
        return usageLimitChangePoint(from: statement, key: key)
    }

    private func insertUsageLimitChangePoints(_ points: [UsageLimitChangePoint]) throws {
        guard !points.isEmpty else { return }
        let statement = try prepare("""
        INSERT INTO usage_limit_samples(
          source, limit_id, window_minutes, change_ordinal, used_percent,
          resets_at_ms, observed_at_ms, last_observed_at_ms, reset_epoch_id,
          reset_min_ms, reset_max_ms
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """)
        defer { sqlite3_finalize(statement) }
        for point in points {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            bind(point.key.source.rawValue, at: 1, to: statement)
            bind(point.key.limitID, at: 2, to: statement)
            bind(Int64(point.key.windowMinutes), at: 3, to: statement)
            bind(point.ordinal, at: 4, to: statement)
            sqlite3_bind_double(statement, 5, point.usedPercent)
            bind(point.resetsAtMS ?? Self.noResetMilliseconds, at: 6, to: statement)
            bind(point.observedAtMS, at: 7, to: statement)
            bind(point.lastObservedAtMS, at: 8, to: statement)
            bind(point.resetEpochID, at: 9, to: statement)
            bind(point.resetMinMS ?? Self.noResetMilliseconds, at: 10, to: statement)
            bind(point.resetMaxMS ?? Self.noResetMilliseconds, at: 11, to: statement)
            try stepDone(statement)
        }
    }

    private func updateUsageLimitChangePoint(_ point: UsageLimitChangePoint) throws {
        let statement = try prepare("""
        UPDATE usage_limit_samples
        SET last_observed_at_ms = ?, reset_min_ms = ?, reset_max_ms = ?
        WHERE source = ? AND limit_id = ? AND window_minutes = ? AND change_ordinal = ?
        """)
        defer { sqlite3_finalize(statement) }
        bind(point.lastObservedAtMS, at: 1, to: statement)
        bind(point.resetMinMS ?? Self.noResetMilliseconds, at: 2, to: statement)
        bind(point.resetMaxMS ?? Self.noResetMilliseconds, at: 3, to: statement)
        bind(point.key.source.rawValue, at: 4, to: statement)
        bind(point.key.limitID, at: 5, to: statement)
        bind(Int64(point.key.windowMinutes), at: 6, to: statement)
        bind(point.ordinal, at: 7, to: statement)
        try stepDone(statement)
    }

    private func usageLimitChangePoint(from statement: OpaquePointer, key: UsageLimitSeriesKey) -> UsageLimitChangePoint {
        func reset(_ column: Int32) -> Int64? {
            let value = sqlite3_column_int64(statement, column)
            return value == Self.noResetMilliseconds ? nil : value
        }
        return UsageLimitChangePoint(
            key: key,
            ordinal: sqlite3_column_int64(statement, 0),
            usedPercent: sqlite3_column_double(statement, 1),
            resetsAtMS: reset(2),
            observedAtMS: sqlite3_column_int64(statement, 3),
            lastObservedAtMS: sqlite3_column_int64(statement, 4),
            resetEpochID: text(statement, 5) ?? "",
            resetMinMS: reset(6),
            resetMaxMS: reset(7)
        )
    }

    private func usageLimitKey(from statement: OpaquePointer) -> UsageLimitSeriesKey? {
        guard let sourceText = text(statement, 0), let source = UsageSource(rawValue: sourceText),
              let limitID = text(statement, 1) else { return nil }
        return UsageLimitSeriesKey(
            source: source,
            limitID: limitID,
            windowMinutes: Int(sqlite3_column_int64(statement, 2))
        )
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

private func bind(_ value: Data, at index: Int32, to statement: OpaquePointer) {
    _ = value.withUnsafeBytes { bytes in
        sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), sqliteTransient)
    }
}

private func text(_ statement: OpaquePointer, _ index: Int32) -> String? {
    guard sqlite3_column_type(statement, index) != SQLITE_NULL,
          let value = sqlite3_column_text(statement, index) else { return nil }
    return String(cString: value)
}

private func optionalInt64(_ statement: OpaquePointer, _ index: Int32) -> Int64? {
    sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, index)
}

private func data(_ statement: OpaquePointer, _ index: Int32) -> Data? {
    guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
    let count = Int(sqlite3_column_bytes(statement, index))
    guard count > 0, let bytes = sqlite3_column_blob(statement, index) else { return Data() }
    return Data(bytes: bytes, count: count)
}

private func milliseconds(_ date: Date) -> Int64 {
    Int64((date.timeIntervalSince1970 * 1_000).rounded())
}

private func exactMilliseconds(_ date: Date) -> Int64? {
    Int64(exactly: (date.timeIntervalSince1970 * 1_000).rounded())
}

private struct UsageLimitSeriesKey: Hashable, Comparable {
    let source: UsageSource
    let limitID: String
    let windowMinutes: Int

    init(source: UsageSource, limitID: String, windowMinutes: Int) {
        self.source = source
        self.limitID = limitID
        self.windowMinutes = windowMinutes
    }

    init(_ sample: UsageLimitSnapshot) {
        self.init(source: sample.source, limitID: sample.limitID, windowMinutes: sample.windowMinutes)
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.source.rawValue != rhs.source.rawValue { return lhs.source.rawValue < rhs.source.rawValue }
        if lhs.limitID != rhs.limitID { return lhs.limitID < rhs.limitID }
        return lhs.windowMinutes < rhs.windowMinutes
    }
}

private struct UsageLimitEvidence: Hashable, Comparable {
    let key: UsageLimitSeriesKey
    let usedPercent: Double
    let resetsAtMS: Int64?
    let observedAtMS: Int64

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.observedAtMS != rhs.observedAtMS { return lhs.observedAtMS < rhs.observedAtMS }
        if lhs.usedPercent != rhs.usedPercent { return lhs.usedPercent < rhs.usedPercent }
        if lhs.usedPercent.bitPattern != rhs.usedPercent.bitPattern {
            return lhs.usedPercent.bitPattern < rhs.usedPercent.bitPattern
        }
        switch (lhs.resetsAtMS, rhs.resetsAtMS) {
        case (nil, nil): return false
        case (nil, _): return true
        case (_, nil): return false
        case let (left?, right?): return left < right
        }
    }
}

private struct UsageLimitChangePoint {
    let key: UsageLimitSeriesKey
    var ordinal: Int64
    var usedPercent: Double
    var resetsAtMS: Int64?
    var observedAtMS: Int64
    var lastObservedAtMS: Int64
    var resetEpochID: String
    var resetMinMS: Int64?
    var resetMaxMS: Int64?
}

private enum UsageLimitEvidenceCodec {
    private static let magic: [UInt8] = [0x54, 0x4b, 0x51, 0x01]
    private static let dayMilliseconds: Int64 = 86_400_000

    static func dayStart(for milliseconds: Int64) -> Int64 {
        let quotient = milliseconds / dayMilliseconds
        let remainder = milliseconds % dayMilliseconds
        return (remainder < 0 ? quotient - 1 : quotient) * dayMilliseconds
    }

    static func encode(_ evidence: [UsageLimitEvidence], dayStartMS: Int64) -> Data {
        var data = Data(magic)
        for item in evidence.sorted() {
            append(UInt32(item.observedAtMS - dayStartMS), to: &data)
            append(item.usedPercent.bitPattern, to: &data)
            data.append(item.resetsAtMS == nil ? 0 : 1)
            if let reset = item.resetsAtMS { append(UInt64(bitPattern: reset), to: &data) }
        }
        return data
    }

    static func decode(_ data: Data, key: UsageLimitSeriesKey, dayStartMS: Int64) throws -> [UsageLimitEvidence] {
        let bytes = [UInt8](data)
        guard bytes.count >= magic.count, Array(bytes.prefix(magic.count)) == magic else {
            throw UsageStoreError.sqlite("invalid quota evidence page")
        }
        var index = magic.count
        var result: [UsageLimitEvidence] = []
        while index < bytes.count {
            let offset: UInt32 = try read(bytes, index: &index)
            let usedBits: UInt64 = try read(bytes, index: &index)
            guard index < bytes.count else { throw UsageStoreError.sqlite("truncated quota evidence page") }
            let hasReset = bytes[index]
            index += 1
            let reset: Int64?
            if hasReset == 0 {
                reset = nil
            } else if hasReset == 1 {
                let bits: UInt64 = try read(bytes, index: &index)
                reset = Int64(bitPattern: bits)
            } else {
                throw UsageStoreError.sqlite("invalid quota evidence reset marker")
            }
            result.append(UsageLimitEvidence(
                key: key,
                usedPercent: Double(bitPattern: usedBits),
                resetsAtMS: reset,
                observedAtMS: dayStartMS + Int64(offset)
            ))
        }
        return result
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }

    private static func read<T: FixedWidthInteger>(_ bytes: [UInt8], index: inout Int) throws -> T {
        guard index + MemoryLayout<T>.size <= bytes.count else {
            throw UsageStoreError.sqlite("truncated quota evidence page")
        }
        var value: T = 0
        for shift in 0..<MemoryLayout<T>.size {
            value |= T(bytes[index + shift]) << T(shift * 8)
        }
        index += MemoryLayout<T>.size
        return value
    }
}

private func buildUsageLimitChangePoints(
    _ evidence: [UsageLimitEvidence],
    key: UsageLimitSeriesKey
) -> [UsageLimitChangePoint] {
    let sorted = Array(Set(evidence)).sorted()
    guard let first = sorted.first else { return [] }
    var epochAnchor = first.resetsAtMS
    var epochMin = first.resetsAtMS
    var epochMax = first.resetsAtMS
    var epochID = makeResetEpochID(key: key, evidence: first)
    var previousEvidence = first
    var current = UsageLimitChangePoint(
        key: key,
        ordinal: 0,
        usedPercent: first.usedPercent,
        resetsAtMS: epochAnchor,
        observedAtMS: first.observedAtMS,
        lastObservedAtMS: first.observedAtMS,
        resetEpochID: epochID,
        resetMinMS: epochMin,
        resetMaxMS: epochMax
    )
    var result: [UsageLimitChangePoint] = []

    for item in sorted.dropFirst() {
        let gap = isUsageLimitGap(from: previousEvidence.observedAtMS, to: item.observedAtMS)
        let resetFits = resetBelongsToEpoch(item.resetsAtMS, minimum: epochMin, maximum: epochMax)
        let startsEpoch = gap || !resetFits
        if startsEpoch {
            epochAnchor = item.resetsAtMS
            epochMin = item.resetsAtMS
            epochMax = item.resetsAtMS
            epochID = makeResetEpochID(key: key, evidence: item)
        } else if let reset = item.resetsAtMS {
            epochMin = min(epochMin ?? reset, reset)
            epochMax = max(epochMax ?? reset, reset)
        }

        let usedChanged = item.usedPercent.bitPattern != current.usedPercent.bitPattern
        if startsEpoch || usedChanged {
            result.append(current)
            current = UsageLimitChangePoint(
                key: key,
                ordinal: current.ordinal + 1,
                usedPercent: item.usedPercent,
                resetsAtMS: epochAnchor,
                observedAtMS: item.observedAtMS,
                lastObservedAtMS: item.observedAtMS,
                resetEpochID: epochID,
                resetMinMS: epochMin,
                resetMaxMS: epochMax
            )
        } else {
            current.lastObservedAtMS = item.observedAtMS
            current.resetMinMS = epochMin
            current.resetMaxMS = epochMax
        }
        previousEvidence = item
    }
    result.append(current)
    return result
}

private func resetBelongsToEpoch(_ reset: Int64?, minimum: Int64?, maximum: Int64?) -> Bool {
    switch (reset, minimum, maximum) {
    case (nil, nil, nil): return true
    case let (value?, minimum?, maximum?):
        let newMinimum = min(value, minimum)
        let newMaximum = max(value, maximum)
        let (width, overflow) = newMaximum.subtractingReportingOverflow(newMinimum)
        return !overflow && width <= UsageLimitHistoryPolicy.resetJitterToleranceMilliseconds
    default: return false
    }
}

private func resetMatches(_ reset: Int64?, minimum: Int64?, maximum: Int64?) -> Bool {
    switch (reset, minimum, maximum) {
    case (nil, nil, nil): true
    case let (value?, minimum?, maximum?): value >= minimum && value <= maximum
    default: false
    }
}

private func isUsageLimitGap(from previous: Int64, to current: Int64) -> Bool {
    let (interval, overflow) = current.subtractingReportingOverflow(previous)
    return overflow || interval > UsageLimitHistoryPolicy.maximumContinuousGapMilliseconds
}

private func makeResetEpochID(key: UsageLimitSeriesKey, evidence: UsageLimitEvidence) -> String {
    let reset = evidence.resetsAtMS.map(String.init) ?? "none"
    return "\(key.source.rawValue):\(key.limitID):\(key.windowMinutes):\(evidence.observedAtMS):\(reset)"
}

private func expandedMinimum(_ current: Int64?, _ candidate: Int64?) -> Int64? {
    switch (current, candidate) {
    case let (left?, right?): min(left, right)
    case let (left?, nil): left
    case let (nil, right?): right
    case (nil, nil): nil
    }
}

private func expandedMaximum(_ current: Int64?, _ candidate: Int64?) -> Int64? {
    switch (current, candidate) {
    case let (left?, right?): max(left, right)
    case let (left?, nil): left
    case let (nil, right?): right
    case (nil, nil): nil
    }
}
