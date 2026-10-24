import Foundation
import Testing
import UsageDomain
import UsageIngestion
import UsagePricing
import UsageStore
@testable import TKMYApp

private actor SelectedClaudeProfile {
    var id = "/a"
    func select(_ id: String) { self.id = id }
    func configuration() -> ClaudeQuotaProfileConfiguration {
        ClaudeQuotaProfileConfiguration(directories: "/a\n/b", selectedProfileID: id)
    }
}

@Test func configuredClaudeAccountsBothSaveHistoryButOnlySelectedAccountFeedsMeter() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = try SQLiteUsageStore(databaseURL: folder.appendingPathComponent("usage.sqlite3"))
    let selection = SelectedClaudeProfile()
    let a = QuotaAccount(source: .claudeCode, email: "a@example.com", organizationID: "org-a")
    let b = QuotaAccount(source: .claudeCode, email: "b@example.com", organizationID: "org-b")
    let reader = ClaudeQuotaProfileReader(identityFetch: { profile in
        profile.configDirectory == nil ? nil : (profile.id == "/a" ? a : b)
    }, quotaFetch: { profile, now in
        let account = profile.id == "/a" ? a : b
        return .identified(account, [account.assigning(UsageLimitSnapshot(source: .claudeCode, limitID: "claude-code",
            usedPercent: profile.id == "/a" ? 25 : 65, windowMinutes: 10_080,
            resetsAt: now.addingTimeInterval(7200), observedAt: now))])
    })
    let coordinator = try UsageCoordinator(store: store, calculator: UsagePriceCalculator.bundled(),
        claudeAdapter: ClaudeCodeAdapter(environment: [:], homeDirectory: folder),
        claudeProfileConfiguration: { await selection.configuration() }, claudeProfileReader: reader)
    guard case let .ready(first) = try await coordinator.load(.claudeCode) else { Issue.record("Expected live synthetic quota without transcripts"); return }
    #expect(first.currentUsageLimits.count == 1)
    #expect(first.usageLimit?.remainingPercent == 75)
    #expect(first.activeQuotaAccountID == a.id)
    #expect(Set(first.usageLimitHistory.compactMap(\.quotaAccountID)) == Set([a.id,b.id]))
    #expect(first.quotaAccounts.count == 2)
    await selection.select("/b")
    guard case let .ready(second) = try await coordinator.load(.claudeCode) else { Issue.record("Expected selected profile B"); return }
    #expect(second.activeQuotaAccountID == b.id)
    #expect(second.currentUsageLimits.allSatisfy { $0.quotaAccountID == b.id })
    #expect(second.usageLimit?.remainingPercent == 35)
    let reopened = try SQLiteUsageStore(databaseURL: folder.appendingPathComponent("usage.sqlite3"))
    #expect(try await reopened.quotaAccounts(source: .claudeCode).count == 2)
    let history = try await reopened.usageLimitHistory(source: .claudeCode, from: .distantPast, through: .distantFuture)
    #expect(Set(history.compactMap(\.quotaAccountID)) == Set([a.id,b.id]))
}
