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
