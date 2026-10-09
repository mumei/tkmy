import Foundation
import Testing
import UsageDomain
import UsageIngestion
import UsagePricing
import UsageStore
@testable import TKMYApp

private actor ClaudeQuotaSequence {
    private var results: [ClaudeAccountRateLimitResult]
    private(set) var calls = 0

    init(_ results: [ClaudeAccountRateLimitResult]) { self.results = results }
    func fetch(_ now: Date) -> ClaudeAccountRateLimitResult {
        calls += 1
        return results.isEmpty ? .failed : results.removeFirst()
    }
}

private func claudeQuota(_ now: Date, minutes: Int, resetAfter: TimeInterval = 7200) -> UsageLimitSnapshot {
    UsageLimitSnapshot(source: .claudeCode, limitID: "claude-code", usedPercent: 42,
                       windowMinutes: minutes, resetsAt: now.addingTimeInterval(resetAfter), observedAt: now)
}

private func quotaCoordinator(directory: URL, sequence: ClaudeQuotaSequence) throws -> UsageCoordinator {
    try UsageCoordinator(
        store: SQLiteUsageStore(databaseURL: directory.appendingPathComponent("usage.sqlite3")),
        calculator: UsagePriceCalculator.bundled(),
        claudeAdapter: ClaudeCodeAdapter(environment: [:], homeDirectory: directory),
        claudeIdentityFetch: { QuotaAccount(source: .claudeCode, email: "test@example.com") },
        claudeRateLimitFetch: { await sequence.fetch($0) }
    )
}

@Test func claudeQuotaIsShownWithoutLocalTranscriptsAndPrefersWeeklyWindow() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let now = Date()
    let sequence = ClaudeQuotaSequence([.available([claudeQuota(now, minutes: 300), claudeQuota(now, minutes: 10_080)])])
    let coordinator = try quotaCoordinator(directory: directory, sequence: sequence)
    guard case let .ready(snapshot) = try await coordinator.load(.claudeCode) else {
        Issue.record("Online quota should work without a local transcript"); return
    }
    #expect(snapshot.usageLimit?.windowMinutes == 10_080)
    #expect(snapshot.usageLimit?.remainingPercent == 58)
    #expect(snapshot.usageLimitHistory.count == 2)
    #expect(snapshot.dailyUsage.isEmpty)
}

@Test func claudeQuotaUnavailableClearsPreviousAccountAndDoesNotInventPercentage() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let now = Date()
    let quota = claudeQuota(now, minutes: 10_080)
    let sequence = ClaudeQuotaSequence([.available([quota]), .unavailable])
    let coordinator = try quotaCoordinator(directory: directory, sequence: sequence)
    #expect(await coordinator.currentClaudeAccountRateLimits(now: now) == [QuotaAccount(source: .claudeCode, email: "test@example.com").assigning(quota)])
    #expect(await coordinator.currentClaudeAccountRateLimits(now: now.addingTimeInterval(30)) == [QuotaAccount(source: .claudeCode, email: "test@example.com").assigning(quota)])
    #expect(await sequence.calls == 1)
    #expect(await coordinator.currentClaudeAccountRateLimits(now: now.addingTimeInterval(61)) == [])
}

@Test func claudeQuotaFailuresHaveBoundedCacheAndKeepOriginalObservationTime() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let now = Date()
    let quota = claudeQuota(now, minutes: 10_080)
    let sequence = ClaudeQuotaSequence([.available([quota]), .failed, .failed])
    let coordinator = try quotaCoordinator(directory: directory, sequence: sequence)
    #expect(await coordinator.currentClaudeAccountRateLimits(now: now) == [QuotaAccount(source: .claudeCode, email: "test@example.com").assigning(quota)])
    #expect(await coordinator.currentClaudeAccountRateLimits(now: now.addingTimeInterval(61)) == [QuotaAccount(source: .claudeCode, email: "test@example.com").assigning(quota)])
    #expect(await coordinator.currentClaudeAccountRateLimits(now: now.addingTimeInterval(601)) == [])
}

@Test func claudeQuotaResetExpiresEvenInsideRefreshThrottle() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let now = Date()
    let sequence = ClaudeQuotaSequence([.available([claudeQuota(now, minutes: 300, resetAfter: 10)])])
    let coordinator = try quotaCoordinator(directory: directory, sequence: sequence)
    #expect(await coordinator.currentClaudeAccountRateLimits(now: now).count == 1)
    #expect(await coordinator.currentClaudeAccountRateLimits(now: now.addingTimeInterval(11)) == [])
    #expect(await sequence.calls == 1)
}
