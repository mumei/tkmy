import Foundation

public enum UsageSource: String, Codable, CaseIterable, Sendable {
    case codex
    case claudeCode

    public var displayName: String {
        switch self {
        case .codex: "Codex"
        case .claudeCode: "Claude Code"
        }
    }
}

public struct UsageLimitSnapshot: Equatable, Sendable {
    public let source: UsageSource
    public let limitID: String
    public let usedPercent: Double
    public let windowMinutes: Int
    public let resetsAt: Date?
    public let observedAt: Date

    public init(
        source: UsageSource,
        limitID: String,
        usedPercent: Double,
        windowMinutes: Int,
        resetsAt: Date?,
        observedAt: Date
    ) {
        self.source = source
        self.limitID = limitID
        self.usedPercent = min(100, max(0, usedPercent))
        self.windowMinutes = max(0, windowMinutes)
        self.resetsAt = resetsAt
        self.observedAt = observedAt
    }

    public var remainingPercent: Double { max(0, 100 - usedPercent) }
}

public struct TokenBreakdown: Codable, Equatable, Sendable {
    public var input: Int64
    public var cacheCreate5m: Int64
    public var cacheCreate1h: Int64
    public var cacheRead: Int64
    public var output: Int64
    public var reasoningOutput: Int64

    public init(
        input: Int64 = 0,
        cacheCreate5m: Int64 = 0,
        cacheCreate1h: Int64 = 0,
        cacheRead: Int64 = 0,
        output: Int64 = 0,
        reasoningOutput: Int64 = 0
    ) {
        self.input = input
        self.cacheCreate5m = cacheCreate5m
        self.cacheCreate1h = cacheCreate1h
        self.cacheRead = cacheRead
        self.output = output
        self.reasoningOutput = reasoningOutput
    }

    public var total: Int64 { input + cacheCreate5m + cacheCreate1h + cacheRead + output }

    /// Returns true when at least one token category that can affect billing is non-zero.
    /// `reasoningOutput` is informational because providers include those tokens in `output`.
    public var hasBillableTokens: Bool {
        input != 0 || cacheCreate5m != 0 || cacheCreate1h != 0 || cacheRead != 0 || output != 0
    }

    public static let zero = TokenBreakdown()

    public func adding(_ other: TokenBreakdown) -> TokenBreakdown {
        TokenBreakdown(
            input: input + other.input,
            cacheCreate5m: cacheCreate5m + other.cacheCreate5m,
            cacheCreate1h: cacheCreate1h + other.cacheCreate1h,
            cacheRead: cacheRead + other.cacheRead,
            output: output + other.output,
            reasoningOutput: reasoningOutput + other.reasoningOutput
        )
    }
}

public struct NormalizedUsageEvent: Codable, Equatable, Sendable {
    public let eventKey: String
    public let source: UsageSource
    public let sessionID: String?
    public let occurredAt: Date
    public let tokens: TokenBreakdown
    public let model: String?
    public let sourceCostMicrosUSD: Int64?
    public let originPathHash: String

    public init(
        eventKey: String,
        source: UsageSource,
        sessionID: String? = nil,
        occurredAt: Date,
        tokens: TokenBreakdown,
        model: String? = nil,
        sourceCostMicrosUSD: Int64? = nil,
        originPathHash: String
    ) {
        self.eventKey = eventKey
        self.source = source
        self.sessionID = sessionID
        self.occurredAt = occurredAt
        self.tokens = tokens
        self.model = model
        self.sourceCostMicrosUSD = sourceCostMicrosUSD
        self.originPathHash = originPathHash
    }
}

public struct DailyUsage: Identifiable, Equatable, Sendable {
    public var id: String { "\(source.rawValue):\(day.timeIntervalSince1970)" }
    public let day: Date
    public let source: UsageSource
    public let tokens: TokenBreakdown
    public let knownCostMicrosUSD: Int64
    public let unknownCostEventCount: Int

    public init(
        day: Date,
        source: UsageSource,
        tokens: TokenBreakdown,
        knownCostMicrosUSD: Int64 = 0,
        unknownCostEventCount: Int = 0
    ) {
        self.day = day
        self.source = source
        self.tokens = tokens
        self.knownCostMicrosUSD = knownCostMicrosUSD
        self.unknownCostEventCount = unknownCostEventCount
    }
}

public struct DailyModelUsage: Identifiable, Equatable, Sendable {
    public var id: String {
        "\(source.rawValue):\(day.timeIntervalSince1970):\(model ?? "unknown")"
    }
    public let day: Date
    public let source: UsageSource
    public let model: String?
    public let tokens: TokenBreakdown

    public init(day: Date, source: UsageSource, model: String?, tokens: TokenBreakdown) {
        self.day = day
        self.source = source
        self.model = model
        self.tokens = tokens
    }
}

public protocol UsageEventStore: Sendable {
    func upsert(_ events: [NormalizedUsageEvent]) async throws
    func dailyUsage(source: UsageSource, from: Date, through: Date, calendar: Calendar) async throws -> [DailyUsage]
    func deleteHistory() async throws
}
