import Foundation
import Testing
import UsageDomain
@testable import UsageIngestion

private let claudeQuotaNow = Date(timeIntervalSince1970: 1_800_000_000)

private func claudeQuotaResponse(_ payload: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: [
        "type": "control_response",
        "response": ["subtype": "success", "request_id": "tkmy-usage", "response": payload],
    ])
}

private func claudeWindow(_ used: Any, reset: Any? = nil) -> [String: Any] {
    ["utilization": used, "resets_at": reset ?? ISO8601DateFormatter().string(from: claudeQuotaNow.addingTimeInterval(7200))]
}

@Test func claudeQuotaReadsGeneralWindowsWithoutUsingContextOrModelLimits() throws {
    let response = try claudeQuotaResponse([
        "rate_limits_available": true,
        "rate_limits": [
            "five_hour": claudeWindow(23.5), "seven_day": claudeWindow(41.2),
            "seven_day_opus": claudeWindow(99), "extra_usage": claudeWindow(70),
        ],
        "context_window": ["remaining_percentage": 1],
    ])
    guard case let .available(snapshots) = ClaudeAccountRateLimitProvider.result(from: response, observedAt: claudeQuotaNow) else {
        Issue.record("Expected subscription quota"); return
    }
    #expect(snapshots.map(\.windowMinutes) == [300, 10_080])
    #expect(snapshots.map(\.remainingPercent) == [76.5, 58.8])
    #expect(snapshots.allSatisfy { $0.source == .claudeCode && $0.limitID == "claude-code" && $0.observedAt == claudeQuotaNow })
}

@Test func claudeQuotaMissingDataDoesNotBecomeZeroUsed() throws {
    for limits: [String: Any] in [[:], ["seven_day": NSNull()], ["seven_day_opus": claudeWindow(10)]] {
        let response = try claudeQuotaResponse(["rate_limits_available": true, "rate_limits": limits])
        #expect(ClaudeAccountRateLimitProvider.result(from: response, observedAt: claudeQuotaNow) == .failed)
    }
    let response = try claudeQuotaResponse(["rate_limits_available": false, "rate_limits": NSNull()])
    #expect(ClaudeAccountRateLimitProvider.result(from: response, observedAt: claudeQuotaNow) == .unavailable)
}

@Test func claudeQuotaRejectsInvalidNumbersAndExpiredResets() throws {
    for value: Any in [true, -1, 101, "42", NSNull()] {
        let response = try claudeQuotaResponse(["rate_limits_available": true, "rate_limits": ["seven_day": claudeWindow(value)]])
        #expect(ClaudeAccountRateLimitProvider.result(from: response, observedAt: claudeQuotaNow) == .failed)
    }
    for reset: Any in ["invalid", true, NSNull(), ISO8601DateFormatter().string(from: claudeQuotaNow)] {
        let response = try claudeQuotaResponse(["rate_limits_available": true, "rate_limits": ["seven_day": claudeWindow(42, reset: reset)]])
        #expect(ClaudeAccountRateLimitProvider.result(from: response, observedAt: claudeQuotaNow) == .failed)
    }
    let numericFlag = try claudeQuotaResponse(["rate_limits_available": 1, "rate_limits": ["seven_day": claudeWindow(42)]])
    #expect(ClaudeAccountRateLimitProvider.result(from: numericFlag, observedAt: claudeQuotaNow) == .failed)
}

@Test func claudeQuotaAcceptsKnownZeroAndHundredPercent() throws {
    for used in [0, 100] {
        let response = try claudeQuotaResponse(["rate_limits_available": true, "rate_limits": ["five_hour": claudeWindow(used)]])
        guard case let .available(snapshots) = ClaudeAccountRateLimitProvider.result(from: response, observedAt: claudeQuotaNow) else {
            Issue.record("Expected known quota at boundary"); continue
        }
        #expect(snapshots.first?.remainingPercent == Double(100 - used))
    }
}

@Test func claudeQuotaRejectsProtocolErrorsAndUnknownResponseShapes() throws {
    for response in ["{}", "not JSON", "{\"type\":\"control_response\",\"response\":{\"subtype\":\"error\",\"request_id\":\"tkmy-usage\",\"error\":\"unsupported\"}}"] {
        #expect(ClaudeAccountRateLimitProvider.result(from: Data(response.utf8), observedAt: claudeQuotaNow) == .failed)
    }
}

@Test func claudeQuotaProcessUsesReadOnlyControlRequestsAndStopsAfterResponse() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let executable = directory.appendingPathComponent("claude")
    let response = String(decoding: try claudeQuotaResponse(["rate_limits_available": true, "rate_limits": ["seven_day": claudeWindow(41)]]), as: UTF8.self)
    try Data("""
    #!/bin/sh
    if [ "$1" = "auth" ]; then echo '{"loggedIn":true,"authMethod":"claude.ai","email":"test@example.com","orgId":null}'; exit 0; fi
    if [ "$1" = "--version" ]; then echo '2.1.289 (Claude Code)'; exit 0; fi
    case " $* " in *" --no-session-persistence "*) ;; *) exit 1;; esac
    case " $* " in *" --setting-sources= "*) ;; *) exit 1;; esac
    read initialize
    case "$initialize" in *'"initialize"'*) ;; *) exit 1;; esac
    echo '{"type":"control_response","response":{"subtype":"success","request_id":"tkmy-init","response":{}}}'
    read usage
    case "$usage" in *'"get_usage"'*) ;; *) exit 1;; esac
    case "$usage" in *'"skip_behaviors":true'*) ;; *) exit 1;; esac
    echo '\(response)'
    exec sleep 10
    """.utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    let provider = ClaudeAccountRateLimitProvider(executableURL: executable, environment: ["PATH": "/bin:/usr/bin"], timeout: 3)
    let start = Date()
    guard case let .identified(account, snapshots) = await provider.fetch(observedAt: claudeQuotaNow) else {
        Issue.record("Expected fake CLI response"); return
    }
    #expect(account.email == "test@example.com")
    #expect(snapshots.first?.limitID == account.limitID)
    #expect(snapshots.first?.remainingPercent == 59)
    #expect(Date().timeIntervalSince(start) < 2)
}

@Test func claudeQuotaProcessTimesOutWithoutHanging() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let executable = directory.appendingPathComponent("claude")
    try Data("#!/bin/sh\nif [ \"$1\" = \"auth\" ]; then echo '{\"loggedIn\":true,\"authMethod\":\"claude.ai\",\"email\":\"test@example.com\"}'; exit 0; fi\nif [ \"$1\" = \"--version\" ]; then echo '2.1.289 (Claude Code)'; exit 0; fi\nexec sleep 10\n".utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    let start = Date()
    let result = await ClaudeAccountRateLimitProvider(executableURL: executable, environment: ["PATH": "/bin:/usr/bin"], timeout: 1).fetch()
    // A timeout in the usage channel is failed; an identity read that cannot
    // be verified is unavailable. Neither may return an invented allowance.
    #expect(result == .failed || result == .unavailable)
    #expect(Date().timeIntervalSince(start) < 3)
}

@Test func claudeQuotaOldCLIIsNotStartedInSessionMode() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let executable = directory.appendingPathComponent("claude")
    try Data("#!/bin/sh\nif [ \"$1\" = \"auth\" ]; then echo '{\"loggedIn\":true,\"authMethod\":\"claude.ai\",\"email\":\"test@example.com\"}'; exit 0; fi\nif [ \"$1\" = \"--version\" ]; then echo '2.1.76 (Claude Code)'; exit 0; fi\nexit 42\n".utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    let result = await ClaudeAccountRateLimitProvider(executableURL: executable, environment: ["PATH": "/bin:/usr/bin"], timeout: 1).fetch()
    #expect(result == .unavailable)
}

@Test func claudeQuotaRequiresReviewedCLIContract() {
    #expect(!ClaudeAccountRateLimitProvider.supportsUsageRequest("2.1.76 (Claude Code)"))
    #expect(!ClaudeAccountRateLimitProvider.supportsUsageRequest("2.1.288 (Claude Code)"))
    #expect(ClaudeAccountRateLimitProvider.supportsUsageRequest("2.1.289 (Claude Code)"))
    #expect(ClaudeAccountRateLimitProvider.supportsUsageRequest("2.2.0 (Claude Code)"))
    #expect(!ClaudeAccountRateLimitProvider.supportsUsageRequest("unknown"))
    #expect(!ClaudeAccountRateLimitProvider.supportsUsageRequest("2.1.invalid.289"))
}
