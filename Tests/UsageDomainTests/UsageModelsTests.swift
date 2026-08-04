import XCTest
@testable import UsageDomain

final class UsageModelsTests: XCTestCase {
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
}
