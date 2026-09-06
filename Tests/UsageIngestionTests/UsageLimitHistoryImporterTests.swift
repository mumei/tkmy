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
        try fixture.log("\(index).jsonl", observations: [now.addingTimeInterval(Double(-index - 1))], resetAt: now.addingTimeInterval(3_600))
    }
    let importer = CodexUsageLimitHistoryImporter(store: fixture.store, byteBudget: 80, fileBudget: 1)
    for _ in 0..<30 {
        let progress = try await importer.refresh(files: files, now: now)
        #expect(progress.bytesRead <= 80)
        #expect(progress.filesExamined <= 1)
        #expect(progress.unreadableFiles == 0)
    }
    #expect(try await fixture.history().count == 1)
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

@Test func quotaBackfillMergesSameValueAndAdvancesLastObservedAt() async throws {
    let fixture = try QuotaImportFixture()
    defer { fixture.remove() }
    let first = fixture.now.addingTimeInterval(-30)
    let second = fixture.now.addingTimeInterval(-10)
    let reset = fixture.now.addingTimeInterval(3_600)
    let file = try fixture.log("same.jsonl", observations: [first], resetAt: reset)
    let importer = CodexUsageLimitHistoryImporter(store: fixture.store)
    _ = try await importer.refresh(files: [file], now: fixture.now)
    try fixture.append(try quotaLine(at: second, resetAt: reset))
    _ = try await importer.refresh(files: [file], now: fixture.now)
    let history = try await fixture.history()
    #expect(history.count == 1)
    #expect(history[0].observedAt == first)
    #expect(history[0].lastObservedAt == second)
}

@Test func quotaBackfillChangePointsAreDeterministicAcrossOrderAndFiles() async throws {
    let fixture = try QuotaImportFixture()
    defer { fixture.remove() }
    let first = fixture.now.addingTimeInterval(-60)
    let second = fixture.now.addingTimeInterval(-30)
    let reset = fixture.now.addingTimeInterval(3_600)
    let a = try fixture.log("a.jsonl", observations: [first], usedPercent: 17, resetAt: reset)
    let b = try fixture.log("b.jsonl", observations: [second], usedPercent: 21, resetAt: reset)
    let importer = CodexUsageLimitHistoryImporter(store: fixture.store)
    _ = try await importer.refresh(files: [b, a], now: fixture.now)
    let history = try await fixture.history()
    #expect(history.count == 2)
    #expect(history.map(\.observedAt) == [first, second])
    #expect(history.map(\.usedPercent) == [17, 21])
}

@Test func quotaBackfillReplayDoesNotCreateOrAdvanceDuplicateChangePoint() async throws {
    let fixture = try QuotaImportFixture()
    defer { fixture.remove() }
    let observation = fixture.now.addingTimeInterval(-10)
    let file = try fixture.log("replay.jsonl", observations: [observation])
    let importer = CodexUsageLimitHistoryImporter(store: fixture.store)
    _ = try await importer.refresh(files: [file], now: fixture.now)
    let before = try await fixture.history()
    _ = try await importer.refresh(files: [file], now: fixture.now)
    let after = try await fixture.history()
    #expect(after.count == 1)
    #expect(after[0].lastObservedAt == before[0].lastObservedAt)
}

@Test func quotaBackfillCreatesChangePointAfterLongGap() async throws {
    let fixture = try QuotaImportFixture()
    defer { fixture.remove() }
    let first = fixture.now.addingTimeInterval(-3_600)
    let second = fixture.now.addingTimeInterval(-10)
    let file = try fixture.log("gap.jsonl", observations: [first, second], usedPercent: 17, resetAt: fixture.now.addingTimeInterval(3_600))
    let importer = CodexUsageLimitHistoryImporter(store: fixture.store)
    _ = try await importer.refresh(files: [file], now: fixture.now)
    let history = try await fixture.history()
    #expect(history.count == 2)
    #expect(history[0].lastObservedAt == first)
    #expect(history[1].lastObservedAt == second)
}

@Test func quotaBackfillRestartMatchesUninterruptedWithCopiedReplay() async throws {
    let interrupted = try QuotaImportFixture()
    let uninterrupted = try QuotaImportFixture()
    defer { interrupted.remove(); uninterrupted.remove() }
    let t1 = interrupted.now.addingTimeInterval(-120)
    let t2 = interrupted.now.addingTimeInterval(-100)
    let reset = interrupted.now.addingTimeInterval(3_600)
    let lines = [try quotaLine(at: t2, usedPercent: 21, resetAt: reset),
                 try quotaLine(at: t1, usedPercent: 17, resetAt: reset),
                 try quotaLine(at: t1.addingTimeInterval(5), usedPercent: 17, resetAt: reset)]
    let partial = interrupted.directory.appendingPathComponent("partial.jsonl")
    try lines.reduce(into: Data()) { $0.append($1) }.write(to: partial)
    let copied = interrupted.directory.appendingPathComponent("copied.jsonl")
    try FileManager.default.copyItem(at: partial, to: copied)
    let full = uninterrupted.directory.appendingPathComponent("full.jsonl")
    try lines.reduce(into: Data()) { $0.append($1) }.write(to: full)
    let resumed = CodexUsageLimitHistoryImporter(store: interrupted.store, byteBudget: 70)
    for _ in 0..<40 { _ = try await resumed.refresh(files: [partial, copied], now: interrupted.now) }
    let complete = CodexUsageLimitHistoryImporter(store: uninterrupted.store)
    _ = try await complete.refresh(files: [full], now: uninterrupted.now)
    #expect(try await interrupted.history() == uninterrupted.history())
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

    func log(_ name: String, observations: [Date], usedPercent: Int = 17, resetAt: Date? = nil) throws -> URL {
        let file = directory.appendingPathComponent(name)
        try observations.reduce(into: Data()) { $0.append(try quotaLine(at: $1, usedPercent: usedPercent, resetAt: resetAt)) }.write(to: file)
        return file
    }

    func append(_ data: Data) throws {
        let file = directory.appendingPathComponent("same.jsonl")
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.close()
    }

    func history() async throws -> [UsageLimitSnapshot] {
        try await store.usageLimitHistory(source: .codex, from: .distantPast, through: now.addingTimeInterval(1))
    }
}

private func quotaLine(at date: Date, usedPercent: Int = 17, resetAt: Date? = nil) throws -> Data {
    let object: [String: Any] = [
        "type": "event_msg", "timestamp": date.timeIntervalSince1970,
        "payload": ["type": "token_count", "info": NSNull(), "rate_limits": [
            "limit_id": "codex", "primary": ["used_percent": usedPercent, "window_minutes": 10_080,
                                              "resets_at": (resetAt ?? date.addingTimeInterval(500)).timeIntervalSince1970]
        ]]
    ]
    var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    data.append(0x0A)
    return data
}
