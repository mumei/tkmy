import Foundation
import UsageDomain
import UsageIngestion
import UsagePricing
import UsageStore
import UsageUI

actor UsageCoordinator {
    private static let parserVersion = 1
    private let store: SQLiteUsageStore
    private let calculator: UsagePriceCalculator
    private let codex = CodexAdapter()
    private let claude = ClaudeCodeAdapter()
    private var scanTask: Task<Void, Never>?
    private var inFlightLoads: [UsageSource: Task<SourceUsageLoadResult, Error>] = [:]

    init(store: SQLiteUsageStore, calculator: UsagePriceCalculator) {
        self.store = store
        self.calculator = calculator
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
                if let cursor = try await store.cursor(for: source, pathHash: pathHash),
                   cursor.inode == inode,
                   cursor.size == size,
                   cursor.modifiedAtMilliseconds == modifiedMilliseconds,
                   cursor.contentSignature == signature,
                   cursor.parserVersion == Self.parserVersion {
                    continue
                }
                let data = try Data(contentsOf: file, options: [.mappedIfSafe])
                var result = adapter.parse(data, at: file)
                if !result.remainder.isEmpty,
                   (try? JSONSerialization.jsonObject(with: result.remainder)) != nil {
                    var finalized = data
                    finalized.append(0x0A)
                    result = adapter.parse(finalized, at: file)
                }
                unreadable += result.malformedLineCount
                try await store.replaceEvents(source: source, originPathHash: pathHash, with: result.events)
                if result.malformedLineCount == 0, result.remainder.isEmpty {
                    try await store.saveCursor(
                        FileCursor(
                        inode: inode,
                        size: size,
                        modifiedAtMilliseconds: modifiedMilliseconds,
                        byteOffset: UInt64(result.consumedByteCount),
                        contentSignature: signature,
                        parserVersion: Self.parserVersion
                    ),
                        source: source,
                        pathHash: pathHash
                    )
                }
            } catch {
                unreadable += 1
            }
        }

        let calendar = Calendar.current
        let through = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date())) ?? Date()
        let from = calendar.date(byAdding: .day, value: -364, to: through) ?? .distantPast
        let events = try await store.events(source: source, from: from, through: through)
        let daily = try calculator.dailyUsage(events: events, calendar: calendar)
        let dailyByModel = try calculator.dailyModelUsage(events: events, calendar: calendar)
        let usageLimit = source == .codex ? codex.latestUsageLimit(in: files) : nil
        let snapshot = SourceUsageSnapshot(
            source: source,
            dailyUsage: daily,
            dailyModelUsage: dailyByModel,
            refreshedAt: Date(),
            pricingUpdatedAt: Self.parseCatalogDate(calculator.catalog.effectiveDate),
            usageLimit: usageLimit
        )
        if files.isEmpty {
            return daily.isEmpty
                ? .sourceMissing(searchedLocations: searchedLocations(for: source))
                : .staleSource(
                    snapshot: snapshot,
                    warning: "現在の利用記録が見つからないため、端末に保存済みの履歴を表示しています。"
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
        var sample = try handle.read(upToCount: sampleSize) ?? Data()
        if size > UInt64(sampleSize) {
            try handle.seek(toOffset: size - UInt64(sampleSize))
            sample.append(try handle.read(upToCount: sampleSize) ?? Data())
        }
        var encodedSize = size.bigEndian
        sample.append(Data(bytes: &encodedSize, count: MemoryLayout<UInt64>.size))
        return UsagePathIdentity.sha256(data: sample)
    }
}
