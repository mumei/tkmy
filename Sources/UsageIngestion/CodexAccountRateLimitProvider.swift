import Darwin
import Foundation
import UsageDomain

/// Reads the account-wide Codex quota through the public app-server protocol.
/// Local session logs remain the fallback because older Codex versions may not
/// provide this method or the executable may not be installed.
public struct CodexAccountRateLimitProvider: Sendable {
    private let executableURL: URL?
    private let environment: [String: String]
    private let timeout: TimeInterval

    public init(
        executableURL: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        timeout: TimeInterval = 8
    ) {
        self.environment = environment
        self.executableURL = executableURL ?? Self.findExecutable(environment: environment)
        self.timeout = max(1, timeout)
    }

    public func fetch(observedAt: Date = Date()) async -> [UsageLimitSnapshot] {
        guard let executableURL else { return [] }
        return await Task.detached(priority: .utility) {
            Self.fetchSynchronously(
                executableURL: executableURL,
                environment: environment,
                timeout: timeout,
                observedAt: observedAt
            )
        }.value
    }

    static func snapshots(from responseData: Data, observedAt: Date) -> [UsageLimitSnapshot] {
        for line in responseData.split(separator: 0x0A).reversed() {
            guard let object = IngestionSupport.jsonObject(Data(line)),
                  let id = object["id"] as? NSNumber, id.intValue == 2,
                  let result = object["result"] as? [String: Any]
            else { continue }

            if let byID = result["rateLimitsByLimitId"] as? [String: Any],
               let general = byID["codex"] as? [String: Any] {
                return snapshots(from: general, fallbackLimitID: "codex", observedAt: observedAt)
            }
            if let legacy = result["rateLimits"] as? [String: Any] {
                return snapshots(from: legacy, fallbackLimitID: "codex", observedAt: observedAt)
            }
        }
        return []
    }

    private static func fetchSynchronously(
        executableURL: URL,
        environment: [String: String],
        timeout: TimeInterval,
        observedAt: Date
    ) -> [UsageLimitSnapshot] {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let collector = CodexRateLimitOutputCollector()
        process.executableURL = executableURL
        process.arguments = ["app-server", "--disable", "plugins", "--disable", "apps", "--stdio"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        var childEnvironment = environment
        childEnvironment["RUST_LOG"] = "error"
        childEnvironment["NO_COLOR"] = "1"
        process.environment = childEnvironment
        output.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                collector.finish()
                return
            }
            let accumulated = collector.append(chunk)
            if !snapshots(from: accumulated, observedAt: observedAt).isEmpty {
                collector.finish()
            }
        }
        process.terminationHandler = { _ in collector.finish() }

        do {
            try process.run()
            try input.fileHandleForWriting.write(contentsOf: requestData())
        } catch {
            if process.isRunning { process.terminate() }
            try? input.fileHandleForWriting.close()
            output.fileHandleForReading.readabilityHandler = nil
            return []
        }

        _ = collector.wait(timeout: timeout)
        try? input.fileHandleForWriting.close()
        output.fileHandleForReading.readabilityHandler = nil
        if process.isRunning {
            process.terminate()
            let terminationDeadline = Date().addingTimeInterval(1)
            while process.isRunning, Date() < terminationDeadline {
                Thread.sleep(forTimeInterval: 0.02)
            }
            if process.isRunning, process.processIdentifier > 0 {
                Darwin.kill(process.processIdentifier, SIGKILL)
            }
        }
        process.waitUntilExit()
        return snapshots(from: collector.data, observedAt: observedAt)
    }

    private static func requestData() throws -> Data {
        let messages: [[String: Any]] = [
            [
                "id": 1,
                "method": "initialize",
                "params": [
                    "clientInfo": ["name": "tkmy", "title": "TKMY", "version": "1"],
                    "capabilities": [:],
                ],
            ],
            ["method": "initialized"],
            ["id": 2, "method": "account/rateLimits/read", "params": NSNull()],
        ]
        var data = Data()
        for message in messages {
            data.append(try JSONSerialization.data(withJSONObject: message))
            data.append(0x0A)
        }
        return data
    }

    private static func snapshots(
        from value: [String: Any],
        fallbackLimitID: String,
        observedAt: Date
    ) -> [UsageLimitSnapshot] {
        let limitID = IngestionSupport.string(value, "limitId", "limit_id") ?? fallbackLimitID
        guard limitID.lowercased() == "codex" else { return [] }
        return ["primary", "secondary"].compactMap { key in
            guard let window = value[key] as? [String: Any],
                  let usedPercent = finiteNumber(window["usedPercent"] ?? window["used_percent"]),
                  (0...100).contains(usedPercent),
                  let minutes = positiveWholeInt(
                      window["windowDurationMins"]
                          ?? window["window_duration_mins"]
                          ?? window["windowMinutes"]
                          ?? window["window_minutes"]
                  )
            else { return nil }
            let resetValue = window["resetsAt"] ?? window["resets_at"]
            return UsageLimitSnapshot(
                source: .codex,
                limitID: limitID,
                usedPercent: usedPercent,
                windowMinutes: minutes,
                resetsAt: safeDate(resetValue),
                observedAt: observedAt
            )
        }
    }

    private static func finiteNumber(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite
        else { return nil }
        return number.doubleValue
    }

    private static func positiveWholeInt(_ value: Any?) -> Int? {
        guard let number = finiteNumber(value), number > 0 else { return nil }
        return Int(exactly: number)
    }

    private static func safeDate(_ value: Any?) -> Date? {
        if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
        guard let date = IngestionSupport.date(value),
              date.timeIntervalSinceReferenceDate.isFinite,
              Int64(exactly: (date.timeIntervalSince1970 * 1_000).rounded()) != nil
        else { return nil }
        return date
    }

    private static func findExecutable(environment: [String: String]) -> URL? {
        let fileManager = FileManager.default
        var candidates: [String] = []
        if let override = environment["TKMY_CODEX_EXECUTABLE"], !override.isEmpty {
            candidates.append(override)
        }
        candidates.append("/Applications/Codex.app/Contents/Resources/codex")
        if let path = environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map { "\($0)/codex" })
        }
        if let home = environment["HOME"], !home.isEmpty {
            candidates.append("\(home)/.bun/bin/codex")
            candidates.append("\(home)/.local/bin/codex")
        }
        candidates.append("/opt/homebrew/bin/codex")
        candidates.append("/usr/local/bin/codex")

        for path in candidates {
            let expanded = NSString(string: path).expandingTildeInPath
            if fileManager.isExecutableFile(atPath: expanded) {
                return URL(fileURLWithPath: expanded).standardizedFileURL
            }
        }
        return nil
    }
}

private final class CodexRateLimitOutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var storage = Data()
    private var isFinished = false

    var data: Data {
        lock.withLock { storage }
    }

    func append(_ data: Data) -> Data {
        lock.withLock {
            storage.append(data)
            return storage
        }
    }

    func finish() {
        let shouldSignal = lock.withLock {
            guard !isFinished else { return false }
            isFinished = true
            return true
        }
        if shouldSignal { semaphore.signal() }
    }

    func wait(timeout: TimeInterval) -> DispatchTimeoutResult {
        semaphore.wait(timeout: .now() + timeout)
    }
}
