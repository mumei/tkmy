import Foundation
import UsageDomain

public struct EventPrice: Equatable, Sendable {
    public enum Basis: Equatable, Sendable {
        case sourceReported
        case catalog(canonicalModel: String)
        case noBillableTokens
        case unknownModel(requestedModel: String?)
    }

    /// Nil means the event could not be priced. It is intentionally distinct from zero.
    public let costMicrosUSD: Int64?
    public let basis: Basis

    public var hasUnknownCost: Bool { costMicrosUSD == nil }
}

public struct UsagePriceCalculator: Sendable {
    public static let microsPerMillionTokens: Int64 = 1_000_000
    public let catalog: PricingCatalog

    public init(catalog: PricingCatalog) throws {
        self.catalog = try catalog.validated()
    }

    public static func bundled() throws -> UsagePriceCalculator {
        try UsagePriceCalculator(catalog: .bundled())
    }

    public func price(_ event: NormalizedUsageEvent) throws -> EventPrice {
        try validate(tokens: event.tokens, eventKey: event.eventKey)
        if let sourceCost = event.sourceCostMicrosUSD {
            guard sourceCost >= 0 else { throw UsagePricingError.negativeSourceCost(event.eventKey) }
            return EventPrice(costMicrosUSD: sourceCost, basis: .sourceReported)
        }

        guard event.tokens.hasBillableTokens else {
            return EventPrice(costMicrosUSD: 0, basis: .noBillableTokens)
        }
        guard let requestedModel = event.model,
              let model = catalog.pricing(for: requestedModel) else {
            return EventPrice(costMicrosUSD: nil, basis: .unknownModel(requestedModel: event.model))
        }

        let cost = try calculate(tokens: event.tokens, rates: model.rates)
        return EventPrice(costMicrosUSD: cost, basis: .catalog(canonicalModel: model.canonicalName))
    }

    /// Aggregates events using the supplied calendar, making the API suitable for local-day UI reports.
    public func dailyUsage(
        events: [NormalizedUsageEvent],
        calendar: Calendar
    ) throws -> [DailyUsage] {
        struct Key: Hashable { let day: Date; let source: UsageSource }
        struct Accumulator {
            var tokens = TokenBreakdown.zero
            var knownCostMicrosUSD: Int64 = 0
            var unknownCostEventCount = 0
        }

        var grouped: [Key: Accumulator] = [:]
        for event in events {
            let key = Key(day: calendar.startOfDay(for: event.occurredAt), source: event.source)
            var value = grouped[key, default: Accumulator()]
            value.tokens = try add(value.tokens, event.tokens)
            let priced = try price(event)
            if let knownCost = priced.costMicrosUSD {
                let (sum, overflow) = value.knownCostMicrosUSD.addingReportingOverflow(knownCost)
                guard !overflow else { throw UsagePricingError.costOverflow }
                value.knownCostMicrosUSD = sum
            } else {
                value.unknownCostEventCount += 1
            }
            grouped[key] = value
        }

        return grouped.map { key, value in
            DailyUsage(
                day: key.day,
                source: key.source,
                tokens: value.tokens,
                knownCostMicrosUSD: value.knownCostMicrosUSD,
                unknownCostEventCount: value.unknownCostEventCount
            )
        }.sorted {
            if $0.day != $1.day { return $0.day < $1.day }
            return $0.source.rawValue < $1.source.rawValue
        }
    }

    public func dailyModelUsage(
        events: [NormalizedUsageEvent],
        calendar: Calendar
    ) throws -> [DailyModelUsage] {
        struct Key: Hashable {
            let day: Date
            let source: UsageSource
            let model: String?
        }

        var grouped: [Key: TokenBreakdown] = [:]
        for event in events {
            try validate(tokens: event.tokens, eventKey: event.eventKey)
            let requestedModel = event.model?.trimmingCharacters(in: .whitespacesAndNewlines)
            let nonemptyModel = requestedModel.flatMap { $0.isEmpty ? nil : $0 }
            let canonicalModel = nonemptyModel.flatMap { catalog.pricing(for: $0)?.canonicalName }
            let key = Key(
                day: calendar.startOfDay(for: event.occurredAt),
                source: event.source,
                model: canonicalModel ?? nonemptyModel
            )
            grouped[key] = try add(grouped[key, default: .zero], event.tokens)
        }

        return grouped.map { key, tokens in
            DailyModelUsage(day: key.day, source: key.source, model: key.model, tokens: tokens)
        }.sorted {
            if $0.day != $1.day { return $0.day < $1.day }
            if $0.source != $1.source { return $0.source.rawValue < $1.source.rawValue }
            if $0.tokens.total != $1.tokens.total { return $0.tokens.total > $1.tokens.total }
            return ($0.model ?? "") < ($1.model ?? "")
        }
    }

    private func calculate(tokens: TokenBreakdown, rates: TokenRates) throws -> Int64 {
        let pairs: [(Int64, Int64)] = [
            (tokens.input, rates.input),
            (tokens.output, rates.output),
            (tokens.cacheCreate5m, rates.cacheCreate5m),
            (tokens.cacheCreate1h, rates.cacheCreate1h),
            (tokens.cacheRead, rates.cacheRead),
        ]
        var numerator: Int64 = 0
        for (tokenCount, rate) in pairs {
            let (product, productOverflow) = tokenCount.multipliedReportingOverflow(by: rate)
            guard !productOverflow else { throw UsagePricingError.costOverflow }
            let (sum, sumOverflow) = numerator.addingReportingOverflow(product)
            guard !sumOverflow else { throw UsagePricingError.costOverflow }
            numerator = sum
        }

        // Round once, half up, after summing every token category.
        let (roundedNumerator, overflow) = numerator.addingReportingOverflow(Self.microsPerMillionTokens / 2)
        guard !overflow else { throw UsagePricingError.costOverflow }
        return roundedNumerator / Self.microsPerMillionTokens
    }

    private func add(_ lhs: TokenBreakdown, _ rhs: TokenBreakdown) throws -> TokenBreakdown {
        func checked(_ lhs: Int64, _ rhs: Int64) throws -> Int64 {
            let (sum, overflow) = lhs.addingReportingOverflow(rhs)
            guard !overflow else { throw UsagePricingError.tokenCountOverflow }
            return sum
        }
        return try TokenBreakdown(
            input: checked(lhs.input, rhs.input),
            cacheCreate5m: checked(lhs.cacheCreate5m, rhs.cacheCreate5m),
            cacheCreate1h: checked(lhs.cacheCreate1h, rhs.cacheCreate1h),
            cacheRead: checked(lhs.cacheRead, rhs.cacheRead),
            output: checked(lhs.output, rhs.output),
            reasoningOutput: checked(lhs.reasoningOutput, rhs.reasoningOutput)
        )
    }

    private func validate(tokens: TokenBreakdown, eventKey: String) throws {
        guard tokens.input >= 0,
              tokens.output >= 0,
              tokens.cacheCreate5m >= 0,
              tokens.cacheCreate1h >= 0,
              tokens.cacheRead >= 0,
              tokens.reasoningOutput >= 0 else {
            throw UsagePricingError.negativeTokenCount(eventKey)
        }
    }
}

public enum UsagePricingError: Error, Equatable {
    case negativeSourceCost(String)
    case negativeTokenCount(String)
    case tokenCountOverflow
    case costOverflow
}
