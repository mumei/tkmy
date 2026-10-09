import Darwin
import Foundation

/// Bounded stdout capture. Authentication output exists only in memory and is
/// decoded into an allowlist of identity metadata by the caller.
enum ReadOnlyCommand {
    static func capture(executableURL: URL, arguments: [String], environment: [String: String], timeout: TimeInterval) -> Data? {
        let process = Process()
        let pipe = Pipe()
        let output = BoundedCommandOutput()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tkmy-identity-" + UUID().uuidString)
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        catch { return nil }
        defer { try? FileManager.default.removeItem(at: directory) }
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = environment.merging(["DISABLE_AUTOUPDATER": "1"]) { _, new in new }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { output.append($0.availableData) }
        defer {
            pipe.fileHandleForReading.readabilityHandler = nil
            if process.isRunning {
                process.terminate()
                let deadline = Date().addingTimeInterval(1)
                while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
                if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
            }
            if process.processIdentifier > 0 { process.waitUntilExit() }
        }
        do { try process.run() } catch { return nil }
        guard output.finished.wait(timeout: .now() + timeout) == .success else { return nil }
        let deadline = Date().addingTimeInterval(1)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        guard !process.isRunning, process.terminationStatus == 0 else { return nil }
        return output.result
    }
}

private final class BoundedCommandOutput: @unchecked Sendable {
    let finished = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var storage = Data()
    private var overflow = false
    var result: Data? { lock.withLock { overflow ? nil : storage } }
    func append(_ data: Data) {
        let done = lock.withLock {
            if storage.count + data.count > 65_536 { overflow = true }
            if !overflow { storage.append(data) }
            return data.isEmpty || overflow
        }
        if done { finished.signal() }
    }
}
