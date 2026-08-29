import Foundation
import Testing
import UsageDomain
@testable import UsageUI

@MainActor
@Test func recentCostSummaryIncludesExactlyThirtyDaysAcrossMonthBoundary() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let through = calendar.date(from: DateComponents(year: 2026, month: 8, day: 15))!
    let viewModel = SourceUsageViewModel(source: .codex, calendar: calendar)

    viewModel.apply(.ready(SourceUsageSnapshot(
        source: .codex,
        dailyUsage: [
            usage(year: 2026, month: 7, day: 16, cost: 900_000, calendar: calendar),
            usage(year: 2026, month: 7, day: 17, cost: 1_250_000, calendar: calendar),
            usage(year: 2026, month: 8, day: 15, cost: 2_500_000, unknown: 2, calendar: calendar),
            usage(year: 2026, month: 8, day: 16, cost: 8_000_000, calendar: calendar),
        ]
    )))

    let summary = viewModel.costSummary(lastDays: 30, through: through)
    #expect(summary.knownCostMicrosUSD == 3_750_000)
    #expect(summary.unknownCostEventCount == 2)
}

@MainActor
@Test func codexModelUsageUsesStableCapabilityOrderInsteadOfTokenCount() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let day = calendar.date(from: DateComponents(year: 2026, month: 8, day: 15))!
    let viewModel = SourceUsageViewModel(source: .codex, calendar: calendar)
    viewModel.apply(.ready(SourceUsageSnapshot(
        source: .codex,
        dailyUsage: [],
        dailyModelUsage: [
            DailyModelUsage(day: day, source: .codex, model: nil, tokens: .init(input: 999)),
            DailyModelUsage(day: day, source: .codex, model: "gpt-5.6-luna", tokens: .init(input: 900)),
            DailyModelUsage(day: day, source: .codex, model: "gpt-5.6-terra", tokens: .init(input: 800)),
            DailyModelUsage(day: day, source: .codex, model: "gpt-5.5", tokens: .init(input: 1)),
            DailyModelUsage(day: day, source: .codex, model: "gpt-5.6-sol", tokens: .init(input: 2)),
            DailyModelUsage(day: day, source: .codex, model: "codex-auto-review", tokens: .init(input: 700)),
            DailyModelUsage(day: day, source: .claudeCode, model: "other", tokens: .init(input: 99)),
        ]
    )))

    #expect(viewModel.modelUsage(on: day).map(\.model) == [
        "gpt-5.6-sol",
        "gpt-5.5",
        "gpt-5.6-terra",
        "gpt-5.6-luna",
        "codex-auto-review",
        nil,
    ])
}

@MainActor
@Test func claudeModelUsageOrdersOpusThenSonnetThenHaikuAndNewestFirst() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let day = calendar.date(from: DateComponents(year: 2026, month: 8, day: 15))!
    let viewModel = SourceUsageViewModel(source: .claudeCode, calendar: calendar)
    viewModel.apply(.ready(SourceUsageSnapshot(
        source: .claudeCode,
        dailyUsage: [],
        dailyModelUsage: [
            DailyModelUsage(day: day, source: .claudeCode, model: "claude-haiku-4-5-20251001", tokens: .init(input: 100)),
            DailyModelUsage(day: day, source: .claudeCode, model: "claude-sonnet-4-5-20250929", tokens: .init(input: 90)),
            DailyModelUsage(day: day, source: .claudeCode, model: "claude-opus-4-5-20251101", tokens: .init(input: 1)),
            DailyModelUsage(day: day, source: .claudeCode, model: "claude-sonnet-4-6", tokens: .init(input: 2)),
            DailyModelUsage(day: day, source: .claudeCode, model: "claude-opus-4-6", tokens: .init(input: 3)),
        ]
    )))

    #expect(viewModel.modelUsage(on: day).compactMap(\.model) == [
        "claude-opus-4-6",
        "claude-opus-4-5-20251101",
        "claude-sonnet-4-6",
        "claude-sonnet-4-5-20250929",
        "claude-haiku-4-5-20251001",
    ])
}

@Test func popoverHeightExpandsForAdditionalModelRows() {
    let day = Date(timeIntervalSince1970: 1_700_000_000)
    let makeUsage: (Int) -> DailyModelUsage = { index in
        DailyModelUsage(
            day: day,
            source: .codex,
            model: "model-\(index)",
            tokens: .init(input: 1)
        )
    }

    #expect(SourceUsagePopoverSizing.contentHeight(for: []) == 566)
    #expect(SourceUsagePopoverSizing.contentHeight(for: (0..<4).map(makeUsage)) == 566)
    #expect(SourceUsagePopoverSizing.contentHeight(for: (0..<5).map(makeUsage)) == 604)
    #expect(SourceUsagePopoverSizing.modelSectionHeight(for: (0..<5).map(makeUsage)) == 89)
    #expect(SourceUsagePopoverSizing.contentHeight(for: (0..<9).map(makeUsage)) == 642)
}

private func usage(
    year: Int,
    month: Int,
    day: Int,
    cost: Int64,
    unknown: Int = 0,
    calendar: Calendar
) -> DailyUsage {
    DailyUsage(
        day: calendar.date(from: DateComponents(year: year, month: month, day: day))!,
        source: .codex,
        tokens: .zero,
        knownCostMicrosUSD: cost,
        unknownCostEventCount: unknown
    )
}
