import Combine
import Foundation
import UsageDomain

public enum SourceUsagePhase: Equatable, Sendable {
    case loading
    case ready
    case sourceMissing(searchedLocations: [String])
    case partialFailure(unreadableFileCount: Int)
    case staleSource(warning: String)
    case unavailable(reason: String?)
}

public struct SourceUsageSnapshot: Equatable, Sendable {
    public let source: UsageSource
    public let dailyUsage: [DailyUsage]
    public let dailyModelUsage: [DailyModelUsage]
    public let refreshedAt: Date
    public let pricingUpdatedAt: Date?
    public let usageLimit: UsageLimitSnapshot?

    public init(
        source: UsageSource,
        dailyUsage: [DailyUsage],
        dailyModelUsage: [DailyModelUsage] = [],
        refreshedAt: Date = Date(),
        pricingUpdatedAt: Date? = nil,
        usageLimit: UsageLimitSnapshot? = nil
    ) {
        self.source = source
        self.dailyUsage = dailyUsage
        self.dailyModelUsage = dailyModelUsage
        self.refreshedAt = refreshedAt
        self.pricingUpdatedAt = pricingUpdatedAt
        self.usageLimit = usageLimit
    }
}

public enum SourceUsageLoadResult: Equatable, Sendable {
    case ready(SourceUsageSnapshot)
    case sourceMissing(searchedLocations: [String])
    case partialFailure(snapshot: SourceUsageSnapshot, unreadableFileCount: Int)
    case staleSource(snapshot: SourceUsageSnapshot, warning: String)
    case unavailable(reason: String?)
}

public typealias SourceUsageLoader = @Sendable () async throws -> SourceUsageLoadResult

public struct UsageCostSummary: Equatable, Sendable {
    public let knownCostMicrosUSD: Decimal
    public let unknownCostEventCount: Int

    public init(knownCostMicrosUSD: Decimal, unknownCostEventCount: Int) {
        self.knownCostMicrosUSD = knownCostMicrosUSD
        self.unknownCostEventCount = max(0, unknownCostEventCount)
    }
}

/// Main-actor state for one source item. Codex and Claude Code must each own a
/// distinct instance so loading and error states never leak between popovers.
@MainActor
public final class SourceUsageViewModel: ObservableObject {
    public let source: UsageSource

    @Published public private(set) var phase: SourceUsagePhase
    @Published public private(set) var dailyUsage: [DailyUsage]
    @Published public private(set) var dailyModelUsage: [DailyModelUsage]
    @Published public var selectedDay: Date?
    @Published public private(set) var lastSuccessfulUpdate: Date?
    @Published public private(set) var pricingUpdatedAt: Date?
    @Published public private(set) var usageLimit: UsageLimitSnapshot?

    private let calendar: Calendar
    private let loader: SourceUsageLoader?

    public init(
        source: UsageSource,
        calendar: Calendar = .current,
        loader: SourceUsageLoader? = nil
    ) {
        self.source = source
        self.calendar = calendar
        self.loader = loader
        self.phase = .loading
        self.dailyUsage = []
        self.dailyModelUsage = []
        self.selectedDay = nil
        self.usageLimit = nil
    }

    public func refresh() async {
        guard let loader else { return }
        phase = .loading

        do {
            apply(try await loader())
        } catch is CancellationError {
            return
        } catch {
            setUnavailable(reason: String(describing: error))
        }
    }

    public func apply(_ result: SourceUsageLoadResult) {
        switch result {
        case let .ready(snapshot):
            apply(snapshot: snapshot)
            phase = .ready
        case let .sourceMissing(locations):
            dailyUsage = []
            dailyModelUsage = []
            selectedDay = nil
            usageLimit = nil
            phase = .sourceMissing(searchedLocations: locations)
        case let .partialFailure(snapshot, unreadableFileCount):
            apply(snapshot: snapshot)
            phase = .partialFailure(unreadableFileCount: max(0, unreadableFileCount))
        case let .staleSource(snapshot, warning):
            apply(snapshot: snapshot)
            phase = .staleSource(warning: warning)
        case let .unavailable(reason):
            setUnavailable(reason: reason)
        }
    }

    public func setLoading() {
        phase = .loading
    }

    public func setSourceMissing(searchedLocations: [String]) {
        apply(.sourceMissing(searchedLocations: searchedLocations))
    }

    public func setUnavailable(reason: String? = nil) {
        phase = .unavailable(reason: reason)
    }

    public func usage(on day: Date) -> DailyUsage? {
        let target = calendar.startOfDay(for: day)
        return dailyUsage.first { calendar.isDate($0.day, inSameDayAs: target) }
    }

    public func modelUsage(on day: Date) -> [DailyModelUsage] {
        let target = calendar.startOfDay(for: day)
        return dailyModelUsage
            .filter { calendar.isDate($0.day, inSameDayAs: target) }
            .sorted(by: ModelCapabilityOrder.precedes)
    }

    public var todayUsage: DailyUsage? {
        usage(on: Date())
    }

    public var recent30DayCostSummary: UsageCostSummary {
        costSummary(lastDays: 30, through: Date())
    }

    public func costSummary(lastDays dayCount: Int, through date: Date) -> UsageCostSummary {
        guard dayCount > 0 else {
            return UsageCostSummary(knownCostMicrosUSD: 0, unknownCostEventCount: 0)
        }
        let through = calendar.startOfDay(for: date)
        guard let start = calendar.date(byAdding: .day, value: -(dayCount - 1), to: through) else {
            return UsageCostSummary(knownCostMicrosUSD: 0, unknownCostEventCount: 0)
        }

        var knownCostMicrosUSD: Decimal = 0
        var unknownCostEventCount = 0
        for usage in dailyUsage where usage.day >= start && usage.day <= through {
            knownCostMicrosUSD += Decimal(usage.knownCostMicrosUSD)
            let (sum, overflow) = unknownCostEventCount.addingReportingOverflow(usage.unknownCostEventCount)
            unknownCostEventCount = overflow ? Int.max : sum
        }
        return UsageCostSummary(
            knownCostMicrosUSD: knownCostMicrosUSD,
            unknownCostEventCount: unknownCostEventCount
        )
    }

    private func apply(snapshot: SourceUsageSnapshot) {
        guard snapshot.source == source else {
            setUnavailable(reason: L10n.text("source_mismatch"))
            return
        }

        dailyUsage = snapshot.dailyUsage
            .filter { $0.source == source }
            .sorted { $0.day < $1.day }
        dailyModelUsage = snapshot.dailyModelUsage
            .filter { $0.source == source }
            .sorted { $0.day < $1.day }
        lastSuccessfulUpdate = snapshot.refreshedAt
        pricingUpdatedAt = snapshot.pricingUpdatedAt
        usageLimit = snapshot.usageLimit

        if selectedDay == nil {
            selectedDay = calendar.startOfDay(for: Date())
        }
    }
}

private enum ModelCapabilityOrder {
    private struct Key: Comparable {
        let capabilityClass: Int
        let majorVersion: Int
        let minorVersion: Int
        let patchVersion: Int
        let normalizedName: String

        static func < (lhs: Key, rhs: Key) -> Bool {
            if lhs.capabilityClass != rhs.capabilityClass {
                return lhs.capabilityClass < rhs.capabilityClass
            }
            if lhs.majorVersion != rhs.majorVersion {
                return lhs.majorVersion > rhs.majorVersion
            }
            if lhs.minorVersion != rhs.minorVersion {
                return lhs.minorVersion > rhs.minorVersion
            }
            if lhs.patchVersion != rhs.patchVersion {
                return lhs.patchVersion > rhs.patchVersion
            }
            return lhs.normalizedName < rhs.normalizedName
        }
    }

    static func precedes(_ lhs: DailyModelUsage, _ rhs: DailyModelUsage) -> Bool {
        key(for: lhs) < key(for: rhs)
    }

    private static func key(for usage: DailyModelUsage) -> Key {
        guard let model = usage.model?.trimmingCharacters(in: .whitespacesAndNewlines),
              !model.isEmpty else {
            return Key(
                capabilityClass: 5,
                majorVersion: 0,
                minorVersion: 0,
                patchVersion: 0,
                normalizedName: ""
            )
        }

        let name = model.lowercased()
        let version = versionComponents(in: name)
        return Key(
            capabilityClass: capabilityClass(source: usage.source, model: name),
            majorVersion: version[safe: 0] ?? 0,
            minorVersion: version[safe: 1] ?? 0,
            patchVersion: version[safe: 2] ?? 0,
            normalizedName: name
        )
    }

    /// A stable, capability-oriented family order. It deliberately avoids using
    /// token volume, which changes every day and made the grid jump between refreshes.
    private static func capabilityClass(source: UsageSource, model: String) -> Int {
        switch source {
        case .codex:
            if model.contains("auto-review") { return 4 }
            if model.contains("luna") || model.contains("mini") || model.contains("spark") { return 2 }
            if model.contains("terra") { return 1 }
            if model.contains("sol") || model.contains("max") || model.hasPrefix("gpt-") { return 0 }
            return 3
        case .claudeCode:
            if model.contains("opus") { return 0 }
            if model.contains("sonnet") { return 1 }
            if model.contains("haiku") { return 2 }
            return 3
        }
    }

    private static func versionComponents(in model: String) -> [Int] {
        model.split(whereSeparator: { !$0.isNumber })
            .compactMap { Int($0) }
            .prefix(3)
            .map { $0 }
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
