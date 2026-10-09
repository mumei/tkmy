import Foundation
import Testing
import UsageDomain
@testable import UsageIngestion

@Test func claudeIdentityAcceptsPersonalAndOrganizationSchemasAndIgnoresExtraKeys() throws {
    let personal = try #require(ClaudeAccountRateLimitProvider.account(from: Data(#"{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","email":"same@example.com","orgId":null,"orgName":null,"subscriptionType":"max","analyticsDisabled":true,"configDirectory":"ignored","accessToken":"never persist"}"#.utf8)))
    #expect(personal.organizationID == nil)
    let missing = try #require(ClaudeAccountRateLimitProvider.account(from: Data(#"{"loggedIn":true,"authMethod":"claude.ai","email":"same@example.com"}"#.utf8)))
    #expect(missing.id == personal.id)
    let org = try #require(ClaudeAccountRateLimitProvider.account(from: Data(#"{"loggedIn":true,"authMethod":"claude.ai","email":"same@example.com","orgId":"org-a","orgName":"Team","subscriptionType":"team"}"#.utf8)))
    #expect(org.id != personal.id)
    #expect(!String(decoding: try JSONEncoder().encode(personal), as: UTF8.self).contains("never persist"))
    #expect(org.id == QuotaAccount(source: .claudeCode, email: org.email, organizationID: "org-a", organizationName: "Renamed", subscriptionType: "enterprise").id)
    #expect(org.id != QuotaAccount(source: .claudeCode, email: "other@example.com", organizationID: "org-a").id)
}

@Test func claudeIdentityFailsClosedForWrongTypesAndNonSubscriptionAuth() {
    for value in [
        #"{"loggedIn":1,"authMethod":"claude.ai","email":"a@b.c"}"#,
        #"{"loggedIn":false,"authMethod":"claude.ai","email":"a@b.c"}"#,
        #"{"loggedIn":true,"authMethod":"api_key","email":"a@b.c"}"#,
        #"{"loggedIn":true,"authMethod":"claude.ai","email":null}"#,
        #"{"loggedIn":true,"authMethod":"claude.ai","email":" "}"#,
        #"{"loggedIn":true,"authMethod":"claude.ai","email":"a@b.c","apiProvider":"bedrock"}"#,
        #"{"loggedIn":true,"authMethod":"claude.ai","email":"a@b.c","apiProvider":null}"#,
        #"{"loggedIn":true,"authMethod":"claude.ai","email":"a@b.c","orgId":" "}"#,
        #"{"loggedIn":true,"authMethod":"claude.ai","email":"a@b.c","orgId":5}"#,
        #"{"loggedIn":true,"authMethod":"claude.ai","email":"a@b.c","orgName":false}"#,
        #"{"loggedIn":true,"authMethod":"claude.ai","email":"a@b.c","subscriptionType":[]}"#,
    ] { #expect(ClaudeAccountRateLimitProvider.account(from: Data(value.utf8)) == nil) }
}

@Test func codexIdentityUsesPublicEmailWithoutPlanDerivedLimits() throws {
    let value = #"{"id":3,"result":{"account":{"type":"chatgpt","email":"a@b.c","planType":"plus","extra":"ignored"}}}"#
    let account = try #require(CodexAccountRateLimitProvider.account(from: Data(value.utf8)))
    #expect(account.source == .codex)
    #expect(account.organizationID == nil)
    #expect(account.id == QuotaAccount(source: .codex, email: "a@b.c", subscriptionType: "pro").id)
    #expect(account.id != QuotaAccount(source: .claudeCode, email: "a@b.c").id)
    for invalid in [#"{"result":{"account":null}}"#, #"{"result":{"account":{"type":"apiKey","email":"a@b.c"}}}"#, #"{"result":{"account":{"type":"chatgpt","email":false}}}"#] {
        #expect(CodexAccountRateLimitProvider.account(from: Data(invalid.utf8)) == nil)
    }
}

@Test(arguments: ["identity-change", "notification"])
func codexProviderRejectsSwitchingDuringProtocolRead(mode: String) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let executable = directory.appendingPathComponent("fake-codex")
    let script = """
    #!/bin/sh
    read init
    echo '{"id":1,"result":{}}'
    read notification
    read before
    case "$before" in *'"refreshToken":false'*) ;; *) exit 1;; esac
    echo '{"id":3,"result":{"account":{"type":"chatgpt","email":"a@example.com","planType":"plus"}}}'
    read quota
    if [ "$TKMY_TEST_MODE" = "notification" ]; then echo '{"method":"account/updated","params":{"authMode":"chatgpt","planType":"plus"}}'; fi
    echo '{"id":2,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":0,"windowDurationMins":300,"resetsAt":2100000000}}}}'
    read after
    if [ "$TKMY_TEST_MODE" = "identity-change" ]; then
      echo '{"id":4,"result":{"account":{"type":"chatgpt","email":"b@example.com","planType":"plus"}}}'
    else
      echo '{"id":4,"result":{"account":{"type":"chatgpt","email":"a@example.com","planType":"plus"}}}'
    fi
    exec sleep 10
    """
    try Data(script.utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    let provider = CodexAccountRateLimitProvider(executableURL: executable, environment: ["PATH": "/bin:/usr/bin", "TKMY_TEST_MODE": mode], timeout: 2)
    #expect(await provider.fetchIdentified() == nil)
}

@Test func claudeProviderDiscardsQuotaWhenAuthStatusChangesAndParsesMultilineJSON() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let executable = directory.appendingPathComponent("fake-claude")
    let state = directory.appendingPathComponent("fake-state").path
    let script = """
    #!/bin/sh
    if [ "$1" = "auth" ]; then
      email='a@example.com'
      if [ -f "$TKMY_TEST_STATE" ]; then email='b@example.com'; fi
      echo '{'
      echo '"loggedIn":true,"authMethod":"claude.ai",'
      echo "\\"email\\":\\"$email\\",\\"orgId\\":null,\\"orgName\\":null}"
      exit 0
    fi
    if [ "$1" = "--version" ]; then echo '2.1.289 (Claude Code)'; exit 0; fi
    read init
    echo '{"type":"control_response","response":{"subtype":"success","request_id":"tkmy-init","response":{}}}'
    read quota
    touch "$TKMY_TEST_STATE"
    echo '{"type":"control_response","response":{"subtype":"success","request_id":"tkmy-usage","response":{"rate_limits_available":true,"rate_limits":{"five_hour":{"utilization":0,"resets_at":"2030-01-01T00:00:00Z"}}}}}'
    exec sleep 10
    """
    try Data(script.utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    let provider = ClaudeAccountRateLimitProvider(executableURL: executable, environment: ["PATH": "/bin:/usr/bin", "TKMY_TEST_STATE": state], timeout: 2)
    #expect(await provider.identity()?.email == "a@example.com")
    #expect(await provider.fetch() == .unavailable)
    #expect(await provider.identity()?.email == "b@example.com")
}
