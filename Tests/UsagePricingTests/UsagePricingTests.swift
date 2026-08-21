import XCTest
import UsageDomain
@testable import UsagePricing

final class UsagePricingTests: XCTestCase {
    private let day = Date(timeIntervalSince1970: 1_750_000_000)

    func testPackagedCatalogResolvesFromMacOSResourcesDirectory() throws {
        let resources = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let catalog = resources
            .appendingPathComponent("TKMY_UsagePricing.bundle", isDirectory: true)
            .appendingPathComponent("model-pricing.json", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: resources) }

        try FileManager.default.createDirectory(
            at: catalog.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("{}".utf8).write(to: catalog)

        XCTAssertEqual(PricingCatalog.packagedCatalogURL(in: resources), catalog)
    }

    func testSourceCostTakesPriorityOverUnknownModelAndCatalog() throws {
        let calculator = try makeCalculator()
        let event = makeEvent(model: "not-in-catalog", sourceCost: 42, tokens: .init(input: 9_000_000))

        XCTAssertEqual(try calculator.price(event), EventPrice(costMicrosUSD: 42, basis: .sourceReported))
    }

    func testCatalogPricesEveryTokenCategoryAndRoundsOnce() throws {
        let calculator = try makeCalculator()
        let event = makeEvent(
            model: "model-a",
            tokens: .init(input: 1_000_000, cacheCreate5m: 1_000_000, cacheCreate1h: 1_000_000, cacheRead: 1_000_000, output: 1_000_000)
        )

        let price = try calculator.price(event)
        XCTAssertEqual(price.costMicrosUSD, 15_000_000)
        XCTAssertEqual(price.basis, .catalog(canonicalModel: "model-a"))
    }

    func testAliasLookupIsCaseAndWhitespaceInsensitive() throws {
        let calculator = try makeCalculator()
        let price = try calculator.price(makeEvent(model: "  ALIAS-A  ", tokens: .init(input: 500_000)))

        XCTAssertEqual(price.costMicrosUSD, 500_000)
        XCTAssertEqual(price.basis, .catalog(canonicalModel: "model-a"))
    }

    func testDatedModelSnapshotResolvesToReviewedFamily() throws {
        let catalog = try PricingCatalog.bundled().validated()
        XCTAssertEqual(
            catalog.pricing(for: "claude-sonnet-4-6-20260715")?.canonicalName,
            "claude-sonnet-4-6"
        )
        XCTAssertEqual(
            catalog.pricing(for: "gpt-5.4-mini-2026-03-17")?.canonicalName,
            "gpt-5.4-mini"
        )
    }

    func testUnknownModelIsNilRatherThanZero() throws {
        let calculator = try makeCalculator()
        let price = try calculator.price(makeEvent(model: "future-model", tokens: .init(output: 10)))

        XCTAssertNil(price.costMicrosUSD)
        XCTAssertEqual(price.basis, .unknownModel(requestedModel: "future-model"))
        XCTAssertTrue(price.hasUnknownCost)
    }

    func testNoTokensHasKnownZeroCostWithoutModel() throws {
        let calculator = try makeCalculator()
        XCTAssertEqual(
            try calculator.price(makeEvent(model: nil, tokens: .zero)),
            EventPrice(costMicrosUSD: 0, basis: .noBillableTokens)
        )
    }

    func testDailyUsageSeparatesSourcesAndCountsUnknownEvents() throws {
        let calculator = try makeCalculator()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 9 * 3_600)!
        let events = [
            makeEvent(key: "a", source: .codex, model: "model-a", tokens: .init(input: 1_000_000)),
            makeEvent(key: "b", source: .codex, model: "unknown", tokens: .init(output: 50)),
            makeEvent(key: "c", source: .claudeCode, model: nil, sourceCost: 70, tokens: .init(output: 3)),
        ]

        let days = try calculator.dailyUsage(events: events, calendar: calendar)
        XCTAssertEqual(days.count, 2)
        let codex = try XCTUnwrap(days.first { $0.source == .codex })
        XCTAssertEqual(codex.tokens, TokenBreakdown(input: 1_000_000, output: 50))
        XCTAssertEqual(codex.knownCostMicrosUSD, 1_000_000)
        XCTAssertEqual(codex.unknownCostEventCount, 1)
        let claude = try XCTUnwrap(days.first { $0.source == .claudeCode })
        XCTAssertEqual(claude.knownCostMicrosUSD, 70)
        XCTAssertEqual(claude.unknownCostEventCount, 0)
        XCTAssertEqual(codex.day, calendar.startOfDay(for: day))
    }

    func testDailyModelUsageCanonicalizesAliasesAndKeepsUnknownModelBucket() throws {
        let calculator = try makeCalculator()
        let events = [
            makeEvent(key: "a", source: .codex, model: "model-a", tokens: .init(input: 10)),
            makeEvent(key: "b", source: .codex, model: " alias-a ", tokens: .init(output: 5)),
            makeEvent(key: "c", source: .codex, model: nil, tokens: .init(input: 3)),
        ]

        let usage = try calculator.dailyModelUsage(events: events, calendar: .current)
        XCTAssertEqual(usage.count, 2)
        XCTAssertEqual(usage.first { $0.model == "model-a" }?.tokens, .init(input: 10, output: 5))
        XCTAssertEqual(usage.first { $0.model == nil }?.tokens.total, 3)
    }

    func testIncrementalReportMatchesArrayAggregation() throws {
        let calculator = try makeCalculator()
        let events = [
            makeEvent(key: "a", source: .codex, model: "model-a", tokens: .init(input: 10)),
            makeEvent(key: "b", source: .codex, model: "unknown", tokens: .init(output: 5)),
            makeEvent(key: "c", source: .claudeCode, model: nil, sourceCost: 9, tokens: .init(cacheRead: 3)),
        ]
        var report = UsageReportAccumulator(calendar: .current)
        for event in events {
            try report.add(event, calculator: calculator)
        }

        XCTAssertEqual(report.dailyUsage, try calculator.dailyUsage(events: events, calendar: .current))
        XCTAssertEqual(report.dailyModelUsage, try calculator.dailyModelUsage(events: events, calendar: .current))
    }

    func testCatalogJSONLoadingAndValidation() throws {
        let data = try JSONEncoder().encode(makeCatalog())
        let decoded = try PricingCatalog.decode(from: data).validated()
        XCTAssertEqual(decoded.pricing(for: "alias-a")?.canonicalName, "model-a")
    }

    func testBundledCatalogHasProvenanceAndRepresentativeModels() throws {
        let catalog = try PricingCatalog.bundled().validated()
        XCTAssertFalse(catalog.provenance.isEmpty)
        XCTAssertNotNil(catalog.pricing(for: "gpt-5-codex"))
        XCTAssertNotNil(catalog.pricing(for: "claude-sonnet-4-6"))
        XCTAssertNil(catalog.pricing(for: "claude-sonnet-4"))
    }

    func testBundledCatalogCoversCurrentCodexModelFamilies() throws {
        let catalog = try PricingCatalog.bundled().validated()
        for model in ["gpt-5.4", "gpt-5.4-mini", "gpt-5.5", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna"] {
            XCTAssertNotNil(catalog.pricing(for: model), "Missing reviewed pricing for \(model)")
        }
        XCTAssertNil(catalog.pricing(for: "gpt-5.3-codex-spark"))
    }

    func testDuplicateAliasIsRejected() {
        let duplicate = ModelPricing(canonicalName: "model-b", aliases: ["alias-a"], rates: makeRates())
        let catalog = PricingCatalog(
            schemaVersion: 1,
            effectiveDate: "2025-01-01",
            provenance: [],
            models: makeCatalog().models + [duplicate]
        )
        XCTAssertThrowsError(try UsagePriceCalculator(catalog: catalog)) {
            XCTAssertEqual($0 as? PricingCatalogError, .duplicateModelOrAlias("alias-a"))
        }
    }

    func testNegativeTokenCountRejected() throws {
        let calculator = try makeCalculator()
        XCTAssertThrowsError(try calculator.price(makeEvent(model: "model-a", tokens: .init(input: -1)))) {
            XCTAssertEqual($0 as? UsagePricingError, .negativeTokenCount("event"))
        }
    }

    func testDailyTokenOverflowIsReportedInsteadOfTrapping() throws {
        let calculator = try makeCalculator()
        let events = [
            makeEvent(key: "max", model: "model-a", sourceCost: 1, tokens: .init(input: .max)),
            makeEvent(key: "one", model: "model-a", sourceCost: 1, tokens: .init(input: 1)),
        ]
        XCTAssertThrowsError(try calculator.dailyUsage(events: events, calendar: .current)) {
            XCTAssertEqual($0 as? UsagePricingError, .tokenCountOverflow)
        }
    }

    func testCatalogCostOverflowIsReportedInsteadOfTrapping() throws {
        let calculator = try makeCalculator()
        XCTAssertThrowsError(
            try calculator.price(makeEvent(model: "model-a", tokens: .init(input: .max)))
        ) {
            XCTAssertEqual($0 as? UsagePricingError, .costOverflow)
        }
    }

    private func makeCalculator() throws -> UsagePriceCalculator {
        try UsagePriceCalculator(catalog: makeCatalog())
    }

    private func makeCatalog() -> PricingCatalog {
        PricingCatalog(
            schemaVersion: 1,
            effectiveDate: "2025-01-01",
            provenance: [],
            models: [ModelPricing(canonicalName: "model-a", aliases: ["alias-a"], rates: makeRates())]
        )
    }

    private func makeRates() -> TokenRates {
        TokenRates(input: 1_000_000, output: 2_000_000, cacheCreate5m: 3_000_000, cacheCreate1h: 4_000_000, cacheRead: 5_000_000)
    }

    private func makeEvent(
        key: String = "event",
        source: UsageSource = .codex,
        model: String?,
        sourceCost: Int64? = nil,
        tokens: TokenBreakdown
    ) -> NormalizedUsageEvent {
        NormalizedUsageEvent(
            eventKey: key,
            source: source,
            occurredAt: day,
            tokens: tokens,
            model: model,
            sourceCostMicrosUSD: sourceCost,
            originPathHash: "path"
        )
    }
}
