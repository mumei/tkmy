import XCTest
@testable import UsageDomain

final class UsageModelsTests: XCTestCase {
    func testLocalizationSupportsSameElevenLanguagesAsCapswitch() {
        XCTAssertEqual(AppLanguage.allCases.count, 11)
        for language in AppLanguage.allCases {
            XCTAssertNotEqual(L10n.text("settings_title", language: language), "settings_title")
            XCTAssertFalse(language.nativeName.isEmpty)
        }
    }

    func testLocalizationFormatsArgumentsAndTraditionalChinese() {
        XCTAssertEqual(
            L10n.text("remaining_format", language: .english, "58%"),
            "58% left"
        )
        XCTAssertEqual(
            L10n.text("remaining_format", language: .japanese, "58%"),
            "残り58%"
        )
        XCTAssertEqual(
            L10n.text("settings_title", language: .traditionalChinese),
            "TKMY 設定"
        )
    }

    func testSystemLanguageSelectsSupportedLanguageAndChineseScript() {
        XCTAssertEqual(AppLanguage.systemDefault(preferredLanguages: ["de-DE", "en-US"]), .german)
        XCTAssertEqual(AppLanguage.systemDefault(preferredLanguages: ["zh-TW"]), .traditionalChinese)
        XCTAssertEqual(AppLanguage.systemDefault(preferredLanguages: ["zh-CN"]), .simplifiedChinese)
        XCTAssertEqual(AppLanguage.systemDefault(preferredLanguages: ["pt-BR"]), .english)
    }

    func testTokenBreakdownAddsAllCategories() {
        let lhs = TokenBreakdown(input: 1, cacheCreate5m: 2, cacheCreate1h: 3, cacheRead: 4, output: 5, reasoningOutput: 6)
        let rhs = TokenBreakdown(input: 10, cacheCreate5m: 20, cacheCreate1h: 30, cacheRead: 40, output: 50, reasoningOutput: 60)

        XCTAssertEqual(
            lhs.adding(rhs),
            TokenBreakdown(input: 11, cacheCreate5m: 22, cacheCreate1h: 33, cacheRead: 44, output: 55, reasoningOutput: 66)
        )
    }

    func testTotalExcludesReasoningAlreadyIncludedInOutput() {
        let tokens = TokenBreakdown(input: 2, cacheRead: 3, output: 5, reasoningOutput: 4)
        XCTAssertEqual(tokens.total, 10)
        XCTAssertTrue(tokens.hasBillableTokens)
        XCTAssertFalse(TokenBreakdown.zero.hasBillableTokens)
    }

    func testUsageLimitReportsRemainingPercentageAndClampsProviderValues() {
        let limit = UsageLimitSnapshot(
            source: .codex,
            limitID: "codex",
            usedPercent: 42,
            windowMinutes: 10_080,
            resetsAt: nil,
            observedAt: Date()
        )
        XCTAssertEqual(limit.remainingPercent, 58)

        let overLimit = UsageLimitSnapshot(
            source: .codex,
            limitID: "codex",
            usedPercent: 120,
            windowMinutes: -1,
            resetsAt: nil,
            observedAt: Date()
        )
        XCTAssertEqual(overLimit.usedPercent, 100)
        XCTAssertEqual(overLimit.remainingPercent, 0)
        XCTAssertEqual(overLimit.windowMinutes, 0)
    }

    func testUsageLimitHistoryPolicyIncludesExact365DayBoundary() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let cutoff = UsageLimitHistoryPolicy.cutoff(relativeTo: now)
        XCTAssertEqual(now.timeIntervalSince(cutoff), 365 * 24 * 60 * 60)
        XCTAssertTrue(UsageLimitHistoryPolicy.contains(cutoff, relativeTo: now))
        XCTAssertFalse(UsageLimitHistoryPolicy.contains(cutoff.addingTimeInterval(-0.001), relativeTo: now))
        XCTAssertTrue(UsageLimitHistoryPolicy.contains(now, relativeTo: now))
        XCTAssertFalse(UsageLimitHistoryPolicy.contains(now.addingTimeInterval(0.001), relativeTo: now))
    }
}
