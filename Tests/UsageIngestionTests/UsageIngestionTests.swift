import Foundation
import Testing
import UsageDomain
@testable import UsageIngestion

@Test func incrementalParserRetainsUnfinishedTailAndSkipsMalformedLines() throws {
    let first = Data("{\"a\":1}\ninvalid\n{\"b\":".utf8)
    let parsed = IncrementalJSONLParser.parse(first)

    #expect(parsed.completeLines.count == 1)
    #expect(parsed.malformedLineCount == 1)
    #expect(String(decoding: parsed.remainder, as: UTF8.self) == "{\"b\":")
    #expect(parsed.consumedByteCount + parsed.remainder.count == first.count)

    let resumed = IncrementalJSONLParser.parse(parsed.remainder + Data("2}\n".utf8))
    #expect(resumed.completeLines.count == 1)
    #expect(resumed.remainder.isEmpty)
}

@Test func codexUsesLastUsageThenCumulativeDelta() throws {
    let adapter = CodexAdapter(environment: [:], homeDirectory: URL(fileURLWithPath: "/tmp/home"))
    let sourceURL = URL(fileURLWithPath: "/tmp/.codex/sessions/2026/session.jsonl")
    let result = adapter.parse(FixtureData.codexSession, at: sourceURL)

    #expect(result.events.count == 2)
    #expect(result.malformedLineCount == 1)
    #expect(result.events[0].source == .codex)
    #expect(result.events[0].sessionID == "codex-session-1")
    #expect(result.events[0].model == "gpt-5")
    #expect(result.events[0].tokens == TokenBreakdown(input: 80, cacheRead: 20, output: 10, reasoningOutput: 2))
    #expect(result.events[1].tokens == TokenBreakdown(input: 40, cacheRead: 10, output: 10, reasoningOutput: 3))
    #expect(result.events[0].originPathHash.count == 64)
    #expect(result.events[0].eventKey == adapter.parse(FixtureData.codexSession, at: sourceURL).events[0].eventKey)
}

@Test func codexReadsLatestWeeklyLimitFromTokenEvents() throws {
    let adapter = CodexAdapter(environment: [:], homeDirectory: URL(fileURLWithPath: "/tmp/home"))
    let limit = try #require(adapter.latestUsageLimit(in: FixtureData.codexSession))

    #expect(limit.source == .codex)
    #expect(limit.limitID == "codex")
    #expect(limit.usedPercent == 42)
    #expect(limit.remainingPercent == 58)
    #expect(limit.windowMinutes == 10_080)
    #expect(limit.resetsAt == Date(timeIntervalSince1970: 1_786_168_800))
}

@Test func claudeParsesCostsCacheBucketsAndConservativeReplayDedupe() throws {
    let adapter = ClaudeCodeAdapter(environment: [:], homeDirectory: URL(fileURLWithPath: "/tmp/home"))
    let result = adapter.parse(
        FixtureData.claudeSession,
        at: URL(fileURLWithPath: "/tmp/.claude/projects/project/session.jsonl")
    )

    #expect(result.events.count == 2)
    #expect(result.events[0].source == .claudeCode)
    #expect(result.events[0].sourceCostMicrosUSD == 1_234)
    #expect(result.events[0].tokens == TokenBreakdown(input: 40, cacheCreate5m: 6, cacheRead: 10, output: 8))
    #expect(result.events[1].tokens == TokenBreakdown(input: 5, cacheCreate5m: 3, cacheCreate1h: 4, output: 2))
    #expect(result.events[0].eventKey != result.events[1].eventKey)
}

@Test func codexDiscoveryPrefersActiveCopyWithSameRelativePath() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let codexHome = root.appendingPathComponent("custom-codex")
    let active = codexHome.appendingPathComponent("sessions/year/session.jsonl")
    let archived = codexHome.appendingPathComponent("archived_sessions/year/session.jsonl")
    try FileManager.default.createDirectory(at: active.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: archived.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data().write(to: active)
    try Data().write(to: archived)

    let adapter = CodexAdapter(environment: ["CODEX_HOME": codexHome.path], homeDirectory: root)
    let files = try adapter.discoverLogFiles()
    #expect(files.map { $0.resolvingSymlinksInPath() } == [active.resolvingSymlinksInPath()])
}

@Test func claudeDiscoverySupportsConfiguredNestedAndDefaultFlatLayouts() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let configured = root.appendingPathComponent("claude-config")
    let nested = configured.appendingPathComponent("projects/project/subagents/agent.jsonl")
    let flat = root.appendingPathComponent(".claude/projects/project/session.jsonl")
    try FileManager.default.createDirectory(at: nested.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: flat.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data().write(to: nested)
    try Data().write(to: flat)

    let adapter = ClaudeCodeAdapter(environment: ["CLAUDE_CONFIG_DIR": configured.path], homeDirectory: root)
    let files = try adapter.discoverLogFiles()
    #expect(Set(files.map { $0.resolvingSymlinksInPath() }) == Set([nested, flat].map { $0.resolvingSymlinksInPath() }))
}

@Test func adaptersCanBeUsedThroughSharedProtocol() throws {
    let adapters: [any UsageSourceAdapter] = [
        CodexAdapter(environment: [:], homeDirectory: URL(fileURLWithPath: "/tmp/home")),
        ClaudeCodeAdapter(environment: [:], homeDirectory: URL(fileURLWithPath: "/tmp/home")),
    ]
    #expect(adapters.map(\.source) == [.codex, .claudeCode])
}

@Test func streamParsersPreserveEventsAcrossSmallChunks() throws {
    let cases: [(any UsageSourceAdapter, Data, URL)] = [
        (
            CodexAdapter(environment: [:], homeDirectory: URL(fileURLWithPath: "/tmp/home")),
            FixtureData.codexSession,
            URL(fileURLWithPath: "/tmp/.codex/sessions/session.jsonl")
        ),
        (
            ClaudeCodeAdapter(environment: [:], homeDirectory: URL(fileURLWithPath: "/tmp/home")),
            FixtureData.claudeSession,
            URL(fileURLWithPath: "/tmp/.claude/projects/session.jsonl")
        ),
    ]

    for (adapter, data, url) in cases {
        let expected = Set(adapter.parse(data, at: url).events.map(\.eventKey))
        let parser = adapter.makeStreamParser(at: url)
        var actual = Set<String>()
        var offset = 0
        while offset < data.count {
            let end = min(data.count, offset + 17)
            let result = parser.consume(Data(data[offset..<end]), isFinal: false)
            actual.formUnion(result.events.map(\.eventKey))
            offset = end
        }
        let final = parser.consume(Data(), isFinal: true)
        actual.formUnion(final.events.map(\.eventKey))

        #expect(actual == expected)
        #expect(final.consumedByteCount + final.remainder.count == data.count)
    }
}

@Test func codexQuotaParserAcceptsNullInfoAndBothWindows() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let data = Data("""
    {"timestamp":"2026-06-01T00:00:00Z","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{"limit_id":"codex","primary":{"used_percent":17,"window_minutes":300,"resets_at":1780000300},"secondary":{"usedPercent":42,"windowDurationMins":10080,"resetsAt":1780600000}}}}
    """.utf8)

    let result = CodexUsageLimitParser(now: now).consume(data, isFinal: true)
    #expect(result.events.isEmpty)
    #expect(result.usageLimits.count == 2)
    #expect(result.usageLimits.map(\.windowMinutes).sorted() == [300, 10_080])
    #expect(Set(result.usageLimits.map(\.limitID)) == ["codex"])
}

@Test func codexQuotaParserFiltersHistoryBoundaryAndFuture() throws {
    let now = Date(timeIntervalSince1970: 1_735_689_600) // 2025-01-01T00:00:00Z
    let cutoff = UsageLimitHistoryPolicy.cutoff(relativeTo: now)
    let old = ISO8601DateFormatter().string(from: cutoff.addingTimeInterval(-1))
    let boundary = ISO8601DateFormatter().string(from: cutoff)
    let future = ISO8601DateFormatter().string(from: now.addingTimeInterval(1))
    let line: (String, Int) -> String = { ts, used in
        "{\"timestamp\":\"\(ts)\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"rate_limits\":{\"limit_id\":\"codex\",\"primary\":{\"used_percent\":\(used),\"window_minutes\":10080}}}}"
    }
    let data = Data(([line(old, 1), line(boundary, 2), line(future, 3)] as [String]).joined(separator: "\n").utf8)
    let result = CodexUsageLimitParser(now: now).consume(data, isFinal: true)
    #expect(result.usageLimits.count == 1)
    #expect((try #require(result.usageLimits.first)).usedPercent == 2)
    #expect((try #require(result.usageLimits.first)).observedAt == cutoff)
}

@Test func codexQuotaParserHandlesChunksTrailingLineAndSkipsHugeLine() throws {
    let valid = "{\"timestamp\":\"2026-06-01T00:00:00Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"rate_limits\":{\"limitId\":\"codex\",\"primary\":{\"usedPercent\":9,\"windowMinutes\":10080}}}}"
    let huge = "{\"padding\":\"" + String(repeating: "x", count: 1_048_577) + "\"}"
    let data = Data((huge + "\n" + valid).utf8)
    let parser = CodexUsageLimitParser(now: Date(timeIntervalSince1970: 1_800_000_000))
    var observedLimits: [UsageLimitSnapshot] = []
    var malformedLines = 0
    var offset = 0
    while offset < data.count {
        let end = min(data.count, offset + 257)
        let result = parser.consume(Data(data[offset..<end]), isFinal: false)
        observedLimits.append(contentsOf: result.usageLimits)
        malformedLines += result.malformedLineCount
        offset = end
    }
    let final = parser.consume(Data(), isFinal: true)
    observedLimits.append(contentsOf: final.usageLimits)
    malformedLines += final.malformedLineCount
    #expect(observedLimits.count == 1)
    #expect((try #require(observedLimits.first)).usedPercent == 9)
    #expect(malformedLines >= 1)
    #expect(final.remainder.isEmpty)
    #expect(final.consumedByteCount == data.count)
}

@Test func codexQuotaParserDoesNotParseSuffixOfOversizedLine() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let quota = "{\"timestamp\":\"2026-06-01T00:00:00Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"rate_limits\":{\"limit_id\":\"codex\",\"primary\":{\"used_percent\":7,\"window_minutes\":10080}}}}"
    let oversized = String(repeating: "x", count: 1_048_577) + quota
    let valid = quota.replacingOccurrences(of: "7,", with: "8,")
    let parser = CodexUsageLimitParser(now: now)
    let result = parser.consume(Data((oversized + "\n" + valid).utf8), isFinal: true)
    #expect(result.usageLimits.count == 1)
    #expect((try #require(result.usageLimits.first)).usedPercent == 8)
    #expect(result.malformedLineCount == 1)
}

@Test func codexQuotaParserRejectsInvalidNumericQuotaValues() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let data = Data("""
    {"timestamp":"2026-06-01T00:00:00Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":true,"window_minutes":1.5}}}}
    {"timestamp":"2026-06-01T00:00:01Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":17,"window_minutes":0}}}}
    {"timestamp":"2026-06-01T00:00:02Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":18,"window_minutes":10080,"resets_at":null}}}}
    """.utf8)
    let result = CodexUsageLimitParser(now: now).consume(data, isFinal: true)
    #expect(result.usageLimits.count == 1)
    #expect((try #require(result.usageLimits.first)).usedPercent == 18)
    #expect((try #require(result.usageLimits.first)).resetsAt == nil)
}

@Test func codexQuotaParserCanResumeInsideDiscardedOversizedLine() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let quota = "{\"timestamp\":\"2026-06-01T00:00:00Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"rate_limits\":{\"limit_id\":\"codex\",\"primary\":{\"used_percent\":9,\"window_minutes\":10080}}}}"
    let parser = CodexUsageLimitParser(now: now)
    let first = parser.consume(Data(String(repeating: "x", count: 1_048_577).utf8), isFinal: false)
    #expect(first.usageLimits.isEmpty)
    let resumed = CodexUsageLimitParser(now: now, startsInsideLine: true)
    let result = resumed.consume(Data((quota + "\n" + quota).utf8), isFinal: true)
    #expect(result.usageLimits.count == 1)
    #expect(result.malformedLineCount == 0)
}

@Test func codexQuotaParserRejectsUnrepresentableWindowsAndSanitizesResetDates() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let data = Data("""
    {"timestamp":"2026-06-01T00:00:00Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":17,"window_minutes":9223372036854775808}}}}
    {"timestamp":"2026-06-01T00:00:01Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":18,"window_minutes":10080,"resets_at":1e300}}}}
    """.utf8)
    let result = CodexUsageLimitParser(now: now).consume(data, isFinal: true)
    #expect(result.usageLimits.count == 1)
    #expect(try #require(result.usageLimits.first).resetsAt == nil)
    #expect(CodexAdapter().latestUsageLimit(in: data)?.resetsAt == nil)
}
