import Foundation
import Testing
import UsageDomain
@testable import UsageIngestion

private func profileFixture() throws -> (URL, URL, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let a = root.appendingPathComponent("profile a")
    let b = root.appendingPathComponent("profile b")
    try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
    let cli = root.appendingPathComponent("fake-claude")
    let script = #"""
    #!/bin/sh
    case "$CLAUDE_CONFIG_DIR" in
      *'/profile a') account=a; used=27 ;;
      *'/profile b') account=b; used=63 ;;
      *) exit 42 ;;
    esac
    if [ "$1" = "auth" ]; then
      echo "{\"loggedIn\":true,\"authMethod\":\"claude.ai\",\"email\":\"$account@example.com\",\"orgId\":\"org-$account\",\"orgName\":\"Team $account\"}"
      exit 0
    fi
    if [ "$1" = "--version" ]; then echo '2.1.289 (Claude Code)'; exit 0; fi
    read init
    echo initialize >> "$CLAUDE_CONFIG_DIR/requests.txt"
    email="$account@example.com"; organization="org-$account"; provider=firstParty
    case "$TKMY_SYNTH_MODE" in
      wrong-email) email=other@example.com ;;
      wrong-org) organization=org-other ;;
      display-org) organization="Team $account" ;;
      wrong-provider) provider=gateway ;;
    esac
    if [ "$TKMY_SYNTH_MODE" = missing ]; then
      echo '{"type":"control_response","response":{"subtype":"success","request_id":"tkmy-init","response":{}}}'
    else
      echo "{\"type\":\"control_response\",\"response\":{\"subtype\":\"success\",\"request_id\":\"tkmy-init\",\"response\":{\"account\":{\"email\":\"$email\",\"organization\":\"$organization\",\"apiProvider\":\"$provider\"}}}}"
    fi
    read quota || exit 0
    echo get_usage >> "$CLAUDE_CONFIG_DIR/requests.txt"
    echo "{\"type\":\"control_response\",\"response\":{\"subtype\":\"success\",\"request_id\":\"tkmy-usage\",\"response\":{\"rate_limits_available\":true,\"rate_limits\":{\"five_hour\":{\"utilization\":$used,\"resets_at\":\"2030-01-01T00:00:00Z\"}}}}}"
    """#
    try Data(script.utf8).write(to: cli)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
    return (root, a, b)
}

@Suite(.serialized)
struct ClaudeQuotaProfileProcessTests {
@Test func explicitClaudeFoldersUseTheirOwnCLIEnvironmentAndQuota() async throws {
    let (root, a, b) = try profileFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    for (folder, email, remaining) in [(a, "a@example.com", 73.0), (b, "b@example.com", 37.0)] {
        let provider = ClaudeAccountRateLimitProvider(executableURL: root.appendingPathComponent("fake-claude"),
            environment: ["PATH":"/usr/bin:/bin", "CLAUDE_CONFIG_DIR":"/must-not-be-used"], configDirectory: folder)
        guard case let .identified(account, samples) = await provider.fetch() else {
            Issue.record("Expected the explicitly scoped fake CLI"); continue
        }
        #expect(account.email == email)
        #expect(samples.first?.remainingPercent == remaining)
        #expect(samples.first?.quotaAccountID == account.id)
    }
}

@Test(arguments: ["wrong-email", "wrong-org", "wrong-provider", "missing"])
func claudeSessionMismatchIsRejectedBeforeRequestingQuota(mode: String) async throws {
    let (root, a, _) = try profileFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let provider = ClaudeAccountRateLimitProvider(executableURL: root.appendingPathComponent("fake-claude"),
        environment: ["PATH":"/usr/bin:/bin", "TKMY_SYNTH_MODE": mode], timeout: 2, configDirectory: a)
    #expect(await provider.fetch() == .unavailable)
    let requests = try String(contentsOf: a.appendingPathComponent("requests.txt"), encoding: .utf8)
    #expect(requests.contains("initialize"))
    #expect(!requests.contains("get_usage"))
}

@Test func sessionOrganizationDisplayNameRetainsBeforeAfterStableIdentityChecks() async throws {
    let (root, a, _) = try profileFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let provider = ClaudeAccountRateLimitProvider(executableURL: root.appendingPathComponent("fake-claude"),
        environment: ["PATH":"/usr/bin:/bin", "TKMY_SYNTH_MODE":"display-org"], configDirectory: a)
    guard case let .identified(account, _) = await provider.fetch() else { Issue.record("Expected documented display organization"); return }
    #expect(account.organizationID == "org-a")
}

@Test func missingExplicitFolderNeverFallsBackToAnotherLogin() async throws {
    let (root, a, _) = try profileFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let provider = ClaudeAccountRateLimitProvider(executableURL: root.appendingPathComponent("fake-claude"),
        environment: ["PATH":"/usr/bin:/bin", "CLAUDE_CONFIG_DIR":a.path], configDirectory: root.appendingPathComponent("missing"))
    #expect(await provider.identity() == nil)
    #expect(await provider.fetch() == .unavailable)
    #expect(!FileManager.default.fileExists(atPath: a.appendingPathComponent("requests.txt").path))
}

@Test func sessionIdentityRejectsAPIKeysAndPersonalToOrganizationChanges() {
    let personal = QuotaAccount(source: .claudeCode, email: "a@example.com")
    #expect(!ClaudeAccountRateLimitProvider.sessionMatches(["email":"a@example.com", "apiProvider":"firstParty", "apiKeySource":"apiKeyHelper"], expected: personal))
    #expect(!ClaudeAccountRateLimitProvider.sessionMatches(["email":"a@example.com", "apiProvider":"firstParty", "organization":"org-other"], expected: personal))
    #expect(!ClaudeAccountRateLimitProvider.sessionMatches(["email":"a@example.com", "apiProvider":"firstParty", "apiKeySource":true], expected: personal))
}

}

private actor ProfileResponses {
    var unavailableB = false
    var calls: [String: Int] = [:]
    func failB() { unavailableB = true }
    func quota(_ profile: ClaudeQuotaProfile, now: Date) -> ClaudeAccountRateLimitResult {
        calls[profile.id, default: 0] += 1
        guard let account = Self.account(profile) else { return .unavailable }
        if unavailableB && profile.id == "/b" { return .unavailable }
        return .identified(account, [account.assigning(UsageLimitSnapshot(source: .claudeCode, limitID: "claude-code",
            usedPercent: profile.id == "/a" ? 20 : 70, windowMinutes: 300,
            resetsAt: now.addingTimeInterval(3600), observedAt: now))])
    }
    static func account(_ profile: ClaudeQuotaProfile) -> QuotaAccount? {
        profile.configDirectory.map { QuotaAccount(source: .claudeCode, email: $0 == "/a" ? "a@example.com" : "b@example.com") }
    }
}

@Test func profileCachesAreIndependentAndSelectedFailureNeverUsesAnotherAccount() async {
    let responses = ProfileResponses()
    let reader = ClaudeQuotaProfileReader(identityFetch: { ProfileResponses.account($0) }, quotaFetch: { await responses.quota($0, now: $1) })
    let now = Date()
    let initial = await reader.read(ClaudeQuotaProfileConfiguration(directories: "/a\n/b", selectedProfileID: "/a"), now: now)
    #expect(initial.accounts.count == 2)
    #expect(initial.historySamples.count == 2)
    #expect(initial.selectedSamples.first?.remainingPercent == 80)
    let switched = await reader.read(ClaudeQuotaProfileConfiguration(directories: "/a\n/b", selectedProfileID: "/b"), now: now.addingTimeInterval(10))
    #expect(switched.selectedSamples.first?.remainingPercent == 30)
    #expect(await responses.calls == ["/a":1, "/b":1])
    await responses.failB()
    let failed = await reader.read(ClaudeQuotaProfileConfiguration(directories: "/a\n/b", selectedProfileID: "/b"), now: now.addingTimeInterval(61))
    #expect(failed.selectedSamples.isEmpty)
    #expect(failed.historySamples.count == 1)
    #expect(failed.historySamples.first?.quotaAccountID == initial.selectedAccount?.id)
}

@Test func profileConfigurationNormalizesDeduplicatesAndDoesNotGuessRelativePaths() {
    let configuration = ClaudeQuotaProfileConfiguration(directories: "/a/../b\n/b\nrelative\n\n/path with spaces", selectedProfileID: "/removed")
    #expect(configuration.profiles.map(\.id) == ["system", "/b", "/path with spaces"])
    #expect(configuration.selectedProfileID == "system")
}
