import Foundation
import UsageDomain
import UsageIngestion
import UsagePricing
import UsageStore
import UsageUI

actor UsageCoordinator {
    private static let parserVersion = 2
    private static let readChunkSize = 1_048_576
    private static let codexStateLookbackBytes: UInt64 = 4 * 1_048_576
    private let store: SQLiteUsageStore
    private let calculator: UsagePriceCalculator
    private let quotaHistoryImporter: CodexUsageLimitHistoryImporter
    private let codex = CodexAdapter()
    private let claude = ClaudeCodeAdapter()
    private var scanTask: Task<Void, Never>?
    private var inFlightLoads: [UsageSource: Task<SourceUsageLoadResult, Error>] = [:]

    init(store: SQLiteUsageStore, calculator: UsagePriceCalculator) {
        self.store = store
        self.calculator = calculator
        self.quotaHistoryImporter = CodexUsageLimitHistoryImporter(store: store)
    }

    func load(_ source: UsageSource) async throws -> SourceUsageLoadResult {
        if let existing = inFlightLoads[source] {
            return try await existing.value
        }
        let task = Task { try await performLoad(source) }
        inFlightLoads[source] = task
        defer { inFlightLoads[source] = nil }
        return try await task.value
    }

    private func performLoad(_ source: UsageSource) async throws -> SourceUsageLoadResult {
        let adapter: any UsageSourceAdapter = source == .codex ? codex : claude
        let files = try adapter.discoverLogFiles()
        // Retention applies only to the new quota observations, even when no
        // Codex logs have changed or are currently available.
        try await store.pruneUsageLimitHistory(now: Date())

        var unreadable = 0
        for file in files {
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
                let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
                let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
                let modifiedDate = attributes[.modificationDate] as? Date ?? .distantPast
                let modifiedMilliseconds = Int64((modifiedDate.timeIntervalSince1970 * 1_000).rounded())
                let pathHash = UsagePathIdentity.sha256(for: file)
                let signature = try Self.contentSignature(for: file, size: size)
                let cursor = try await store.cursor(for: source, pathHash: pathHash)
                if let cursor,
                   cursor.inode == inode,
                   cursor.size == size,
                   cursor.modifiedAtMilliseconds == modifiedMilliseconds,
                   cursor.contentSignature == signature,
                   cursor.parserVersion == Self.parserVersion {
                    continue
                }

                let isAppend = try cursor.map {
                    try Self.isAppendOnlyChange(
                        cursor: $0,
                        inode: inode,
                        currentSize: size,
                        file: file
                    )
                } ?? false
                let newBytesOffset = isAppend ? min(cursor?.byteOffset ?? 0, size) : 0
                let parserStart: UInt64
                if isAppend, source == .codex {
                    parserStart = newBytesOffset > Self.codexStateLookbackBytes
                        ? newBytesOffset - Self.codexStateLookbackBytes
                        : 0
                } else {
                    parserStart = newBytesOffset
                }

                if !isAppend {
                    try await store.deleteEvents(source: source, originPathHash: pathHash)
                }
                let parser = adapter.makeStreamParser(at: file)
                let handle = try FileHandle(forReadingFrom: file)
                defer { try? handle.close() }

                if parserStart < newBytesOffset {
                    try handle.seek(toOffset: parserStart)
                    let warmup = try handle.read(upToCount: Int(newBytesOffset - parserStart)) ?? Data()
                    _ = parser.consume(warmup, isFinal: false)
                }
                try handle.seek(toOffset: newBytesOffset)
                while let chunk = try handle.read(upToCount: Self.readChunkSize), !chunk.isEmpty {
                    let result = parser.consume(chunk, isFinal: false)
                    unreadable += result.malformedLineCount
                    try await store.upsert(result.events)
                    if !result.usageLimits.isEmpty {
                        try await store.upsertUsageLimits(result.usageLimits, now: Date())
                    }
                }
                let finalResult = parser.consume(Data(), isFinal: true)
                unreadable += finalResult.malformedLineCount
                try await store.upsert(finalResult.events)
                if !finalResult.usageLimits.isEmpty {
                    try await store.upsertUsageLimits(finalResult.usageLimits, now: Date())
                }
                let consumedOffset = min(
                    size,
                    parserStart + UInt64(finalResult.consumedByteCount)
                )
                try await store.saveCursor(
                    FileCursor(
                        inode: inode,
                        size: size,
                        modifiedAtMilliseconds: modifiedMilliseconds,
                        byteOffset: consumedOffset,
                        contentSignature: signature,
                        parserVersion: Self.parserVersion
                    ),
                    source: source,
                    pathHash: pathHash
                )
            } catch {
                unreadable += 1
            }
        }

        if source == .codex {
            let progress = try await quotaHistoryImporter.refresh(files: files, now: Date())
            unreadable += progress.unreadableFiles
        }

        let calendar = Calendar.current
        let through = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date())) ?? Date()
        let from = calendar.date(byAdding: .day, value: -364, to: through) ?? .distantPast
        let report = try await store.reduceEvents(
            source: source,
            from: from,
            through: through,
            initial: UsageReportAccumulator(calendar: calendar)
        ) { report, event in
            try report.add(event, calculator: calculator)
        }
        let daily = report.dailyUsage
        let dailyByModel = report.dailyModelUsage
        let usageLimit = source == .codex ? codex.latestUsageLimit(in: files) : nil
        if let usageLimit {
            // Save the timestamp reported by Codex, never the refresh time.
            try await store.upsertUsageLimits([usageLimit], now: Date())
        }
        let refreshedAt = Date()
        let usageLimitHistory = try await store.usageLimitHistory(
            source: source,
            from: refreshedAt.addingTimeInterval(-30 * 24 * 60 * 60),
            through: refreshedAt
        )
        let snapshot = SourceUsageSnapshot(
            source: source,
            dailyUsage: daily,
            dailyModelUsage: dailyByModel,
            refreshedAt: refreshedAt,
            pricingUpdatedAt: Self.parseCatalogDate(calculator.catalog.effectiveDate),
            usageLimit: usageLimit,
            usageLimitHistory: usageLimitHistory
        )
        if files.isEmpty {
            return daily.isEmpty && usageLimitHistory.isEmpty
                ? .sourceMissing(searchedLocations: searchedLocations(for: source))
                : .staleSource(
                    snapshot: snapshot,
                    warning: L10n.text("stale_history")
                )
        }
        return unreadable > 0
            ? .partialFailure(snapshot: snapshot, unreadableFileCount: unreadable)
            : .ready(snapshot)
    }

    func scheduleRefresh(_ operation: @escaping @Sendable () async -> Void) {
        scanTask?.cancel()
        scanTask = Task {
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            await operation()
        }
    }

    private func searchedLocations(for source: UsageSource) -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        switch source {
        case .codex:
            let base = ProcessInfo.processInfo.environment["CODEX_HOME"] ?? "\(home)/.codex"
            return ["\(base)/sessions", "\(base)/archived_sessions"]
        case .claudeCode:
            var result = ["\(home)/.claude/projects", "\(home)/.config/claude/projects"]
            if let configured = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] {
                result.insert("\(configured)/projects", at: 0)
            }
            return result
        }
    }

    private static func parseCatalogDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: value)
    }

    private static func contentSignature(for url: URL, size: UInt64) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let sampleSize = 4_096
        var sample = try handle.read(upToCount: min(sampleSize, Int(size))) ?? Data()
        if size > UInt64(sampleSize) {
            try handle.seek(toOffset: size - UInt64(sampleSize))
            sample.append(try handle.read(upToCount: sampleSize) ?? Data())
        }
        var encodedSize = size.bigEndian
        sample.append(Data(bytes: &encodedSize, count: MemoryLayout<UInt64>.size))
        return UsagePathIdentity.sha256(data: sample)
    }

    private static func isAppendOnlyChange(
        cursor: FileCursor,
        inode: UInt64,
        currentSize: UInt64,
        file: URL
    ) throws -> Bool {
        guard cursor.parserVersion == parserVersion,
              cursor.inode == inode,
              currentSize >= cursor.size,
              cursor.byteOffset <= cursor.size
        else { return false }
        return try contentSignature(for: file, size: cursor.size) == cursor.contentSignature
    }
}
