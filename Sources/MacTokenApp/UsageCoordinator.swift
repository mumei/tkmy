import Foundation
import UsageDomain
import UsageIngestion
import UsagePricing
import UsageStore
import UsageUI

actor UsageCoordinator {
    private static let parserVersion = 2
    // A negative Codex parser version means the file was parsed through its
    // cursor but has known gaps. Existing positive v2 cursors remain intact.
    private static let quotaTokenCoveragePathHash = "quota-token-coverage:v1"
    private static let quotaTokenCoverageSignature = "quota-token-coverage:v1"
    private static let readChunkSize = 1_048_576
    private static let codexStateLookbackBytes: UInt64 = 4 * 1_048_576
    private static let accountRateLimitRefreshInterval: TimeInterval = 60
    private static let accountRateLimitStaleInterval: TimeInterval = 10 * 60
    private let store: SQLiteUsageStore
    private let calculator: UsagePriceCalculator
    private let quotaHistoryImporter: CodexUsageLimitHistoryImporter
    private let codexAccountRateLimits = CodexAccountRateLimitProvider()
    private let codex = CodexAdapter()
    private let claude = ClaudeCodeAdapter()
    private var scanTask: Task<Void, Never>?
    private var inFlightLoads: [UsageSource: Task<SourceUsageLoadResult, Error>] = [:]
    private var usageReportCaches: [UsageSource: UsageReportCache] = [:]
    private var accountRateLimitAttemptedAt: Date?
    private var accountRateLimitSucceededAt: Date?
    private var cachedAccountRateLimits: [UsageLimitSnapshot] = []

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
        let loadStartedAt = Date()
        let adapter: any UsageSourceAdapter = source == .codex ? codex : claude
        let files = try adapter.discoverLogFiles()
        var requiresFullUsageRebuild = usageReportCaches[source] == nil
        var earliestUsageChange: Date?
        let existingCoverageStartedAt = source == .codex
            ? try await quotaTokenCoverageStartedAt()
            : nil
        // Retention applies only to the new quota observations, even when no
        // Codex logs have changed or are currently available.
        try await store.pruneUsageLimitHistory(now: Date())

        var unreadable = 0
        let parserVersion = Self.parserVersion
        for file in files {
            do {
                var fileMalformedLineCount = 0
                let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
                let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
                let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
                let modifiedDate = attributes[.modificationDate] as? Date ?? .distantPast
                let modifiedMilliseconds = Int64((modifiedDate.timeIntervalSince1970 * 1_000).rounded())
                let pathHash = UsagePathIdentity.sha256(for: file)
                let signature = try Self.contentSignature(for: file, size: size)
                let cursor = try await store.cursor(for: source, pathHash: pathHash)
                let cursorVersionMatches = cursor.map {
                    Self.cursorVersionMatches(
                        $0.parserVersion,
                        expected: parserVersion,
                        permitsIncomplete: source == .codex
                    )
                } ?? false
                if let cursor,
                   cursor.inode == inode,
                   cursor.size == size,
                   cursor.modifiedAtMilliseconds == modifiedMilliseconds,
                   cursor.contentSignature == signature,
                   cursorVersionMatches {
                    if cursor.parserVersion == -parserVersion { unreadable += 1 }
                    continue
                }

                let isAppend = try cursor.map {
                    try Self.isAppendOnlyChange(
                        cursor: $0,
                        inode: inode,
                        currentSize: size,
                        file: file,
                        parserVersion: parserVersion,
                        permitsIncompleteVersion: source == .codex
                    )
                } ?? false
                if cursor != nil, !isAppend {
                    // A rewritten or truncated transcript may have removed
                    // events from any day previously attributed to this file.
                    requiresFullUsageRebuild = true
                }
                let priorIncomplete = isAppend && cursor?.parserVersion == -parserVersion
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
                    fileMalformedLineCount += result.malformedLineCount
                    earliestUsageChange = Self.earliestDate(
                        earliestUsageChange,
                        among: result.events
                    )
                    try await store.upsert(result.events)
                    if !result.usageLimits.isEmpty {
                        try await store.upsertUsageLimits(result.usageLimits, now: Date())
                    }
                }
                let finalResult = parser.consume(Data(), isFinal: true)
                unreadable += finalResult.malformedLineCount
                fileMalformedLineCount += finalResult.malformedLineCount
                earliestUsageChange = Self.earliestDate(
                    earliestUsageChange,
                    among: finalResult.events
                )
                try await store.upsert(finalResult.events)
                if !finalResult.usageLimits.isEmpty {
                    try await store.upsertUsageLimits(finalResult.usageLimits, now: Date())
                }
                let consumedOffset = min(
                    size,
                    parserStart + UInt64(finalResult.consumedByteCount)
                )
                if priorIncomplete, fileMalformedLineCount == 0 { unreadable += 1 }
                let incomplete = source == .codex
                    && (priorIncomplete || fileMalformedLineCount > 0)
                try await store.saveCursor(
                    FileCursor(
                        inode: inode,
                        size: size,
                        modifiedAtMilliseconds: modifiedMilliseconds,
                        byteOffset: consumedOffset,
                        contentSignature: signature,
                        // Negative Codex versions preserve known incomplete
                        // coverage without reparsing a permanently malformed
                        // file on every refresh. Claude keeps its positive v2.
                        parserVersion: incomplete ? -parserVersion : parserVersion
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

        let loggedUsageLimit = source == .codex ? codex.latestUsageLimit(in: files) : nil
        let accountRateLimits = source == .codex
            ? await currentCodexAccountRateLimits(now: Date())
            : []
        if !accountRateLimits.isEmpty {
            try await store.upsertUsageLimits(accountRateLimits, now: Date())
        } else if let loggedUsageLimit {
            // Save the timestamp reported by Codex, never the refresh time.
            try await store.upsertUsageLimits([loggedUsageLimit], now: Date())
        }
        let usageLimit = accountRateLimits.max { $0.windowMinutes < $1.windowMinutes }
            ?? loggedUsageLimit
        let refreshedAt = Date()
        let usageLimitHistory = try await store.usageLimitHistory(
            source: source,
            // A connected predecessor can fall just outside the 30-day chart.
            from: refreshedAt.addingTimeInterval(
                -30 * 24 * 60 * 60 - UsageLimitHistoryPolicy.maximumContinuousGap
            ),
            through: refreshedAt
        )

        let calendar = Calendar.current
        let through = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date())) ?? Date()
        let from = calendar.date(byAdding: .day, value: -364, to: through) ?? .distantPast
        let report = try await usageReport(
            source: source,
            from: from,
            through: through,
            calendar: calendar,
            requiresFullRebuild: requiresFullUsageRebuild,
            earliestChange: earliestUsageChange
        )
        let quotaTokens = try await quotaTokenAccumulator(
            source: source,
            endpoints: usageLimitHistory.map(\.observedAt)
        )
        let daily = report.dailyUsage
        let dailyByModel = report.dailyModelUsage
        let coverageStartedAt = try await establishQuotaTokenCoverageIfNeeded(
            source: source,
            existing: existingCoverageStartedAt,
            loadStartedAt: loadStartedAt,
            hasFiles: !files.isEmpty
        )
        let quotaTokenSummary = quotaTokens?.summary(
            isComplete: unreadable == 0 && !files.isEmpty,
            coverageStartedAt: coverageStartedAt
        )
        let snapshot = SourceUsageSnapshot(
            source: source,
            dailyUsage: daily,
            dailyModelUsage: dailyByModel,
            refreshedAt: refreshedAt,
            pricingUpdatedAt: Self.parseCatalogDate(calculator.catalog.effectiveDate),
            usageLimit: usageLimit,
            usageLimitHistory: usageLimitHistory,
            quotaTokenSummary: quotaTokenSummary
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

    private func usageReport(
        source: UsageSource,
        from: Date,
        through: Date,
        calendar: Calendar,
        requiresFullRebuild: Bool,
        earliestChange: Date?
    ) async throws -> UsageReportCache {
        let cached = usageReportCaches[source]
        let canReuse = !requiresFullRebuild && cached.map {
            $0.from <= from && $0.timeZoneIdentifier == calendar.timeZone.identifier
        } == true

        if canReuse, earliestChange == nil, let cached {
            let trimmed = cached.trimmed(from: from, through: through)
            usageReportCaches[source] = trimmed
            return trimmed
        }

        let rebuildFrom: Date
        let accumulator: UsageReportAccumulator
        if canReuse, let cached, let earliestChange {
            rebuildFrom = max(from, calendar.startOfDay(for: earliestChange))
            if rebuildFrom >= through {
                let trimmed = cached.trimmed(from: from, through: through)
                usageReportCaches[source] = trimmed
                return trimmed
            }
            accumulator = UsageReportAccumulator(
                calendar: calendar,
                reusing: cached.dailyUsage,
                dailyModelUsage: cached.dailyModelUsage,
                before: rebuildFrom
            )
        } else {
            rebuildFrom = from
            accumulator = UsageReportAccumulator(calendar: calendar)
        }

        let updated = try await store.reduceEvents(
            source: source,
            from: rebuildFrom,
            through: through,
            initial: accumulator
        ) { report, event in
            try report.add(event, calculator: calculator)
        }
        let result = UsageReportCache(
            from: from,
            through: through,
            timeZoneIdentifier: calendar.timeZone.identifier,
            dailyUsage: updated.dailyUsage,
            dailyModelUsage: updated.dailyModelUsage
        )
        usageReportCaches[source] = result
        return result
    }

    private func quotaTokenAccumulator(
        source: UsageSource,
        endpoints: [Date]
    ) async throws -> QuotaTokenSummary.Accumulator? {
        guard source == .codex else { return nil }
        var accumulator = QuotaTokenSummary.Accumulator(source: source, endpoints: endpoints)
        guard let first = endpoints.min(), let last = endpoints.max() else { return accumulator }

        accumulator = try await store.reduceEvents(
            source: source,
            from: first,
            // Stored timestamps have millisecond precision and the query's
            // upper bound is exclusive. Include events exactly at the endpoint.
            through: last.addingTimeInterval(0.001),
            initial: accumulator
        ) { summary, event in
            summary.add(
                event,
                attribution: Self.quotaAttribution(for: event, calculator: calculator)
            )
        }
        return accumulator
    }

    private static func earliestDate(
        _ current: Date?,
        among events: [NormalizedUsageEvent]
    ) -> Date? {
        guard let candidate = events.lazy.map(\.occurredAt).min() else { return current }
        return min(current ?? candidate, candidate)
    }

    private func currentCodexAccountRateLimits(now: Date) async -> [UsageLimitSnapshot] {
        if let attemptedAt = accountRateLimitAttemptedAt,
           now.timeIntervalSince(attemptedAt) < Self.accountRateLimitRefreshInterval {
            return cachedAccountRateLimits
        }
        accountRateLimitAttemptedAt = now
        let fetched = await codexAccountRateLimits.fetch(observedAt: now)
        if !fetched.isEmpty {
            cachedAccountRateLimits = fetched
            accountRateLimitSucceededAt = now
            return fetched
        }
        if let succeededAt = accountRateLimitSucceededAt,
           now.timeIntervalSince(succeededAt) <= Self.accountRateLimitStaleInterval {
            return cachedAccountRateLimits
        }
        cachedAccountRateLimits = []
        return []
    }

    func scheduleRefresh(_ operation: @escaping @Sendable () async -> Void) {
        scanTask?.cancel()
        scanTask = Task {
            try? await Task.sleep(for: .seconds(2))
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

    private func quotaTokenCoverageStartedAt() async throws -> Date? {
        guard let cursor = try await store.cursor(
            for: .codex,
            pathHash: Self.quotaTokenCoveragePathHash
        ),
        cursor.parserVersion == 1,
        cursor.contentSignature == Self.quotaTokenCoverageSignature,
        cursor.modifiedAtMilliseconds > 0
        else { return nil }
        return Date(
            timeIntervalSince1970: Double(cursor.modifiedAtMilliseconds) / 1_000
        )
    }

    private func establishQuotaTokenCoverageIfNeeded(
        source: UsageSource,
        existing: Date?,
        loadStartedAt: Date,
        hasFiles: Bool
    ) async throws -> Date? {
        guard source == .codex else { return nil }
        if let existing { return existing }
        guard hasFiles else { return nil }

        let milliseconds = Int64(ceil(loadStartedAt.timeIntervalSince1970 * 1_000))
        let exactDate = Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
        try await store.saveCursor(
            FileCursor(
                inode: 0,
                size: 0,
                modifiedAtMilliseconds: milliseconds,
                byteOffset: 0,
                contentSignature: Self.quotaTokenCoverageSignature,
                parserVersion: 1
            ),
            source: .codex,
            pathHash: Self.quotaTokenCoveragePathHash
        )
        return exactDate
    }

    private static func cursorVersionMatches(
        _ stored: Int,
        expected: Int,
        permitsIncomplete: Bool
    ) -> Bool {
        stored == expected || (permitsIncomplete && stored == -expected)
    }

    private static func quotaAttribution(
        for event: NormalizedUsageEvent,
        calculator: UsagePriceCalculator
    ) -> QuotaTokenSummary.CodexEventAttribution {
        guard event.source == .codex,
              let requestedModel = event.model?.trimmingCharacters(in: .whitespacesAndNewlines),
              !requestedModel.isEmpty
        else { return .unknown }

        let normalizedModel = requestedModel.lowercased()
        if normalizedModel.contains("spark") {
            // GPT-5.3-Codex-Spark is reported under codex_bengalfox, so its
            // local events must not be silently charged to the general bucket.
            return .separateModelQuota
        }
        guard let canonical = calculator.pricing(for: requestedModel)?.canonicalName,
              canonical.lowercased().hasPrefix("gpt-")
        else { return .unknown }
        return .general
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
        file: URL,
        parserVersion: Int,
        permitsIncompleteVersion: Bool
    ) throws -> Bool {
        guard cursorVersionMatches(
                  cursor.parserVersion,
                  expected: parserVersion,
                  permitsIncomplete: permitsIncompleteVersion
              ),
              cursor.inode == inode,
              currentSize >= cursor.size,
              cursor.byteOffset <= cursor.size
        else { return false }
        return try contentSignature(for: file, size: cursor.size) == cursor.contentSignature
    }
}

private struct UsageReportCache: Sendable {
    let from: Date
    let through: Date
    let timeZoneIdentifier: String
    let dailyUsage: [DailyUsage]
    let dailyModelUsage: [DailyModelUsage]

    func trimmed(from: Date, through: Date) -> UsageReportCache {
        UsageReportCache(
            from: from,
            through: through,
            timeZoneIdentifier: timeZoneIdentifier,
            dailyUsage: dailyUsage.filter { $0.day >= from && $0.day < through },
            dailyModelUsage: dailyModelUsage.filter { $0.day >= from && $0.day < through }
        )
    }
}
