import Foundation
import Testing
import UsageDomain
@testable import UsageIngestion

@Test(arguments: ["stable", "identity-change", "notification"])
func codexNodeLauncherWorksWithoutNodeOnPATHAndStillChecksIdentity(mode: String) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let launcher = directory.appendingPathComponent("codex")
    let node = directory.appendingPathComponent("node")
    // The fake interpreter runs the synthetic protocol fixture, never real auth.
    try Data("#!/bin/sh\nexec /bin/sh \"$@\"\n".utf8).write(to: node)
    try Data("""
    #!/usr/bin/env node
    test "$1" = "app-server" || exit 1
    while read request; do
      case "$request" in
        *'"id":1'*) echo '{"id":1,"result":{}}';;
        *'"id":3'*)
          case "$request" in *'"refreshToken":false'*) ;; *) exit 1;; esac
          echo '{"id":3,"result":{"account":{"type":"chatgpt","email":"a@example.com","planType":"plus"}}}';;
        *'"id":2'*)
          if [ "$TKMY_TEST_MODE" = "notification" ]; then echo '{"method":"account/updated","params":{"authMode":"chatgpt"}}'; fi
          echo '{"id":2,"result":{"rateLimits":{"limitId":"codex","secondary":{"usedPercent":17,"windowDurationMins":10080}}}}';;
        *'"id":4'*)
          if [ "$TKMY_TEST_MODE" = "identity-change" ]; then
            echo '{"id":4,"result":{"account":{"type":"chatgpt","email":"b@example.com","planType":"plus"}}}'
          else
            echo '{"id":4,"result":{"account":{"type":"chatgpt","email":"a@example.com","planType":"plus"}}}'
          fi;;
      esac
    done
    """.utf8).write(to: launcher)
    for file in [launcher, node] {
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
    }
    let environment = ["PATH": "/usr/bin:/bin", "TKMY_TEST_MODE": mode]
    // Reproduce the original /usr/bin/env node launch failure first.
    let original = Process()
    original.executableURL = launcher
    original.environment = environment
    original.standardError = FileHandle.nullDevice
    original.standardOutput = FileHandle.nullDevice
    try original.run()
    original.waitUntilExit()
    #expect(original.terminationStatus != 0)

    let provider = CodexAccountRateLimitProvider(
        executableURL: launcher, environment: environment, timeout: 2, nodeExecutableURL: node
    )
    let result = await provider.fetchIdentified()
    if mode == "stable" {
        let identified = try #require(result)
        #expect(identified.snapshots.count == 1)
        #expect(identified.snapshots.first?.remainingPercent == 83)
        #expect(identified.snapshots.first?.quotaAccountID == identified.account.id)
    } else {
        #expect(result == nil)
    }
}

@Test func codexNodeLauncherFailsClosedWhenInterpreterCannotRun() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let launcher = directory.appendingPathComponent("codex")
    try Data("#!/usr/bin/env node\n".utf8).write(to: launcher)
    let provider = CodexAccountRateLimitProvider(
        executableURL: launcher, environment: ["PATH": "/usr/bin:/bin"], timeout: 1,
        nodeExecutableURL: directory.appendingPathComponent("missing-node")
    )
    #expect(await provider.identity() == nil)
    #expect(await provider.fetchIdentified() == nil)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["TKMY_LIVE_CODEX_TEST"] == "1"))
func codexIdentifiedQuotaWorksWithInstalledLauncherAndGUIPathWhenRequested() async throws {
    var environment = ProcessInfo.processInfo.environment
    environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
    let provider = CodexAccountRateLimitProvider(environment: environment, timeout: 15)
    let identified = try #require(await provider.fetchIdentified())
    #expect(!identified.snapshots.isEmpty)
    #expect(identified.snapshots.allSatisfy { $0.quotaAccountID == identified.account.id })
}
