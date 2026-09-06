import Foundation
import SQLite3
import Testing
import UsageDomain
@testable import UsageStore

/// Opt-in integration harness. Scripts/measure-quota-storage.py creates a
/// disposable schema-3 fixture and explicitly supplies its path. Normal test
/// runs never inspect an installed app's database.
@Test func quotaHistoryStorageMeasurement() async throws {
    guard let path = ProcessInfo.processInfo.environment["TKMY_QUOTA_VERIFY_DATABASE"] else { return }
    let url = URL(fileURLWithPath: path)
    let marker = url.appendingPathExtension("measurement-fixture")
    #expect(FileManager.default.fileExists(atPath: marker.path))
    guard FileManager.default.fileExists(atPath: marker.path) else { return }
    let now = Date()
    let original = try measurementSamples(at: url)
    let store = try SQLiteUsageStore(databaseURL: url)
    let migrated = try await store.usageLimitHistory(source: .codex, from: .distantPast, through: now)
    let beforeReplay = migrated
    // Reversed replay exercises the duplicate/backfill path, rather than just
    // an already-ordered bulk insert. No confirmation may move to refresh time.
    try await store.upsertUsageLimits(Array(original.reversed()), now: now)
    let replayed = try await store.usageLimitHistory(source: .codex, from: .distantPast, through: now)
    #expect(replayed == beforeReplay)
    #expect(replayed.map(\.lastObservedAt).max() == original.map(\.observedAt).max())

    let result: [String: Any] = [
        "input_samples": original.count,
        "history_rows": migrated.count,
        "duplicate_replay_unchanged": replayed == beforeReplay,
        "points": migrated.map { point -> [String: Any] in
            [
                "source": point.source.rawValue,
                "limit_id": point.limitID,
                "window_minutes": point.windowMinutes,
                "used_percent": point.usedPercent,
                "observed_at_ms": Int64((point.observedAt.timeIntervalSince1970 * 1_000).rounded()),
                "last_observed_at_ms": Int64((point.lastObservedAt.timeIntervalSince1970 * 1_000).rounded()),
                "resets_at_ms": point.resetsAt.map { Int64(($0.timeIntervalSince1970 * 1_000).rounded()) } as Any? ?? NSNull(),
                "reset_epoch_id": point.resetEpochID as Any? ?? NSNull(),
            ]
        },
    ]
    try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        .write(to: url.appendingPathExtension("verification.json"), options: .atomic)
}

private func measurementSamples(at url: URL) throws -> [UsageLimitSnapshot] {
    var handle: OpaquePointer?
    guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let handle else {
        throw UsageStoreError.open("Could not read measurement fixture")
    }
    defer { sqlite3_close(handle) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(handle, "SELECT source, limit_id, used_percent, window_minutes, resets_at_ms, observed_at_ms FROM usage_limit_samples ORDER BY observed_at_ms", -1, &statement, nil) == SQLITE_OK,
          let statement else {
        throw UsageStoreError.sqlite(String(cString: sqlite3_errmsg(handle)))
    }
    defer { sqlite3_finalize(statement) }
    var result: [UsageLimitSnapshot] = []
    var status = sqlite3_step(statement)
    while status == SQLITE_ROW {
        guard let source = UsageSource(rawValue: String(cString: sqlite3_column_text(statement, 0))) else {
            throw UsageStoreError.sqlite("Unknown source in measurement fixture")
        }
        let reset = sqlite3_column_int64(statement, 4)
        result.append(UsageLimitSnapshot(
            source: source,
            limitID: String(cString: sqlite3_column_text(statement, 1)),
            usedPercent: sqlite3_column_double(statement, 2),
            windowMinutes: Int(sqlite3_column_int64(statement, 3)),
            resetsAt: reset == Int64.min ? nil : Date(timeIntervalSince1970: Double(reset) / 1_000),
            observedAt: Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, 5)) / 1_000)
        ))
        status = sqlite3_step(statement)
    }
    guard status == SQLITE_DONE else { throw UsageStoreError.sqlite(String(cString: sqlite3_errmsg(handle))) }
    return result
}
