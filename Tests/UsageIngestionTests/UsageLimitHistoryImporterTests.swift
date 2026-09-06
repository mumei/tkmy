import Foundation
import Testing
import UsageDomain
import UsageStore
@testable import UsageIngestion

@Test func quotaBackfillHasByteAndFileBudgetsAndContinuesAcrossRefreshes() async throws {
    let fixture = try QuotaImportFixture()
    defer { fixture.remove() }
    let now = fixture.now
    let files = try (0..<3).map { index in
        try fixture.log("\(index).jsonl", observations: [now.addingTimeInterval(Double(-index - 1))])
    }
    let importer = CodexUsageLimitHistoryImporter(store: fixture.store, byteBudget: 80, fileBudget: 1)
    for _ in 0..<30 {
        let progress = try await importer.refresh(files: files, now: now)
        #expect(progress.bytesRead <= 80)
        #expect(progress.filesExamined <= 1)
        #expect(progress.unreadableFiles == 0)
    }
    #expect(try await fixture.history().count == 3)
    let finished = try await importer.refresh(files: files, now: now)
    #expect(finished.bytesRead == 0)
}

@Test func quotaBackfillPersistsCursorAndOnlyReadsAppendedObservations() async throws {
    let fixture = try QuotaImportFixture()
    defer { fixture.remove() }
    let firstDate = fixture.now.addingTimeInterval(-30)
    let file = try fixture.log("recent.jsonl", observations: [firstDate])
    let importer = CodexUsageLimitHistoryImporter(store: fixture.store)
    _ = try await importer.refresh(files: [file], now: fixture.now)
    let reopened = CodexUsageLimitHistoryImporter(store: fixture.store)
    #expect(try await reopened.refresh(files: [file], now: fixture.now).bytesRead == 0)
    let appended = try quotaLine(at: fixture.now.addingTimeInterval(-10))
    let handle = try FileHandle(forWritingTo: file)
    try handle.seekToEnd()
    try handle.write(contentsOf: appended)
    try handle.close()
    let changed = try await reopened.refresh(files: [file], now: fixture.now)
    #expect(changed.bytesRead == appended.count)
    #expect(try await fixture.history().count == 2)
    #expect(try await reopened.refresh(files: [file], now: fixture.now).bytesRead == 0)
}

@Test func quotaBackfillRecoversAfterRestartInTheMiddleOfALine() async throws {
    let fixture = try QuotaImportFixture()
    defer { fixture.remove() }
    let file = try fixture.log("partial.jsonl", observations: [fixture.now.addingTimeInterval(-5)])
    let first = CodexUsageLimitHistoryImporter(store: fixture.store, byteBudget: 40)
    _ = try await first.refresh(files: [file], now: fixture.now)
    #expect(try await fixture.history().isEmpty)
    let restarted = CodexUsageLimitHistoryImporter(store: fixture.store, byteBudget: 40)
    for _ in 0..<20 { _ = try await restarted.refresh(files: [file], now: fixture.now) }
    #expect(try await fixture.history().count == 1)
}

@Test func quotaBackfillFilters365DaysAndDoesNotResurrectExpiredData() async throws {
    let fixture = try QuotaImportFixture()
    defer { fixture.remove() }
    let cutoff = UsageLimitHistoryPolicy.cutoff(relativeTo: fixture.now)
    let file = try fixture.log("mixed.jsonl", observations: [
        cutoff.addingTimeInterval(-1), cutoff, fixture.now.addingTimeInterval(10)
    ])
    let importer = CodexUsageLimitHistoryImporter(store: fixture.store)
    _ = try await importer.refresh(files: [file], now: fixture.now)
    #expect(try await fixture.history().map(\.observedAt) == [cutoff])
    let later = fixture.now.addingTimeInterval(2)
    _ = try await importer.refresh(files: [], now: later)
    #expect(try await fixture.history().isEmpty)
    // A new path forces a historical re-read; expiry filtering still applies.
    let copied = fixture.directory.appendingPathComponent("copy.jsonl")
    try FileManager.default.copyItem(at: file, to: copied)
    _ = try await importer.refresh(files: [copied], now: later)
    #expect(try await fixture.history().isEmpty)
}

@Test func quotaBackfillSkipsOldFilesAndDeduplicatesCopiedLogs() async throws {
    let fixture = try QuotaImportFixture()
    defer { fixture.remove() }
    let old = try fixture.log("old.jsonl", observations: [fixture.now.addingTimeInterval(-10)])
    try FileManager.default.setAttributes(
        [.modificationDate: UsageLimitHistoryPolicy.cutoff(relativeTo: fixture.now).addingTimeInterval(-1)],
        ofItemAtPath: old.path
    )
    let importer = CodexUsageLimitHistoryImporter(store: fixture.store)
    #expect(try await importer.refresh(files: [old], now: fixture.now).bytesRead == 0)
    let recent = try fixture.log("recent.jsonl", observations: [fixture.now.addingTimeInterval(-10)])
    let copied = fixture.directory.appendingPathComponent("copied.jsonl")
    try FileManager.default.copyItem(at: recent, to: copied)
    _ = try await importer.refresh(files: [recent, copied], now: fixture.now)
    #expect(try await fixture.history().count == 1)
}

@Test func quotaBackfillHandlesFileReplacementDuringPartialRead() async throws {
    let fixture = try QuotaImportFixture()
    defer { fixture.remove() }
    let file = try fixture.log("rewritten.jsonl", observations: [fixture.now.addingTimeInterval(-10)])
    let importer = CodexUsageLimitHistoryImporter(store: fixture.store, byteBudget: 40)
    _ = try await importer.refresh(files: [file], now: fixture.now)
    let replacementDate = fixture.now.addingTimeInterval(-3)
    try quotaLine(at: replacementDate).write(to: file, options: .atomic)
    for _ in 0..<20 { _ = try await importer.refresh(files: [file], now: fixture.now) }
    #expect(try await fixture.history().map(\.observedAt) == [replacementDate])
}

private struct QuotaImportFixture {
    let directory: URL
    let store: SQLiteUsageStore
    let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("TKMYQuotaImport-\(UUID().uuidString)")
        store = try SQLiteUsageStore(databaseURL: directory.appendingPathComponent("usage.sqlite3"))
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }

    func log(_ name: String, observations: [Date]) throws -> URL {
        let file = directory.appendingPathComponent(name)
        try observations.reduce(into: Data()) { $0.append(try quotaLine(at: $1)) }.write(to: file)
        return file
    }

    func history() async throws -> [UsageLimitSnapshot] {
        try await store.usageLimitHistory(source: .codex, from: .distantPast, through: now.addingTimeInterval(1))
    }
}

private func quotaLine(at date: Date) throws -> Data {
    let object: [String: Any] = [
        "type": "event_msg", "timestamp": date.timeIntervalSince1970,
        "payload": ["type": "token_count", "info": NSNull(), "rate_limits": [
            "limit_id": "codex", "primary": ["used_percent": 17, "window_minutes": 10_080,
                                              "resets_at": date.timeIntervalSince1970 + 500]
        ]]
    ]
    var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    data.append(0x0A)
    return data
}
