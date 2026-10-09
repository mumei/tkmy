import Foundation
import Testing
import UsageDomain
import UsageIngestion
import UsagePricing
import UsageStore
@testable import TKMYApp

private actor IdentityBox {
    var account: QuotaAccount?
    init(_ account: QuotaAccount) { self.account = account }
    func get() -> QuotaAccount? { account }
    func set(_ value: QuotaAccount?) { account = value }
}

@Test(arguments: [UsageSource.codex, .claudeCode])
func accountSwitchInsideThrottleNeverReturnsPreviousQuota(source: UsageSource) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let first = QuotaAccount(source: source, email: "a@example.com")
    let second = QuotaAccount(source: source, email: "b@example.com")
    let box = IdentityBox(first)
    let coordinator = try UsageCoordinator(
        store: SQLiteUsageStore(databaseURL: directory.appendingPathComponent("usage.sqlite3")),
        calculator: UsagePriceCalculator.bundled(),
        claudeAdapter: ClaudeCodeAdapter(environment: [:], homeDirectory: directory),
        codexIdentityFetch: { await box.get() },
        codexRateLimitFetch: { now in
            guard let account = await box.get() else { return nil }
            return (account, [sample(account, now: now)])
        },
        claudeIdentityFetch: { await box.get() },
        claudeRateLimitFetch: { now in
            guard let account = await box.get() else { return .unavailable }
            return .identified(account, [sample(account, now: now)])
        }
    )
    let now = Date()
    let a = await (source == .codex ? coordinator.currentCodexAccountRateLimits(now: now) : coordinator.currentClaudeAccountRateLimits(now: now))
    #expect(a.first?.quotaAccountID == first.id)
    await box.set(second)
    let b = await (source == .codex ? coordinator.currentCodexAccountRateLimits(now: now.addingTimeInterval(10)) : coordinator.currentClaudeAccountRateLimits(now: now.addingTimeInterval(10)))
    #expect(b.first?.quotaAccountID == second.id)
    await box.set(nil)
    let signedOut = await (source == .codex ? coordinator.currentCodexAccountRateLimits(now: now.addingTimeInterval(20)) : coordinator.currentClaudeAccountRateLimits(now: now.addingTimeInterval(20)))
    #expect(signedOut.isEmpty)
}

@Test(arguments: [UsageSource.codex, .claudeCode])
func authenticationChangeDuringQuotaReadDiscardsResult(source: UsageSource) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let first = QuotaAccount(source: source, email: "a@example.com")
    let second = QuotaAccount(source: source, email: "b@example.com")
    let box = IdentityBox(first)
    let coordinator = try UsageCoordinator(
        store: SQLiteUsageStore(databaseURL: directory.appendingPathComponent("usage.sqlite3")),
        calculator: UsagePriceCalculator.bundled(),
        codexIdentityFetch: { await box.get() },
        codexRateLimitFetch: { now in
            await box.set(second)
            return (first, [sample(first, now: now)])
        },
        claudeIdentityFetch: { await box.get() },
        claudeRateLimitFetch: { now in
            await box.set(second)
            return .identified(first, [sample(first, now: now)])
        }
    )
    let result = await (source == .codex ? coordinator.currentCodexAccountRateLimits(now: Date()) : coordinator.currentClaudeAccountRateLimits(now: Date()))
    #expect(result.isEmpty)
}

private func sample(_ account: QuotaAccount, now: Date) -> UsageLimitSnapshot {
    UsageLimitSnapshot(source: account.source, limitID: account.limitID, usedPercent: 42, windowMinutes: 300, resetsAt: now.addingTimeInterval(7200), observedAt: now)
}

@Test func codexKnownPercentageWithUnknownResetRemainsKnown() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let account = QuotaAccount(source: .codex, email: "a@example.com", subscriptionType: "plus")
    let coordinator = try UsageCoordinator(
        store: SQLiteUsageStore(databaseURL: directory.appendingPathComponent("usage.sqlite3")),
        calculator: UsagePriceCalculator.bundled(),
        codexIdentityFetch: { account },
        codexRateLimitFetch: { now in
            (account, [UsageLimitSnapshot(source: .codex, limitID: account.limitID, usedPercent: 17, windowMinutes: 15, resetsAt: nil, observedAt: now)])
        }
    )
    let result = await coordinator.currentCodexAccountRateLimits(now: Date())
    #expect(result.first?.remainingPercent == 83)
    #expect(result.first?.windowMinutes == 15)
    #expect(result.first?.resetsAt == nil)
}
