import CoreServices
import Foundation

final class DirectoryWatcher: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.mactoken.directory-watcher", qos: .utility)
    private let onChange: @Sendable () -> Void
    private var stream: FSEventStreamRef?

    init(urls: [URL], onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
        let paths = urls
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .map(\.standardizedFileURL.path)
        guard !paths.isEmpty else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        stream = FSEventStreamCreate(
            nil,
            { _, clientInfo, _, _, _, _ in
                guard let clientInfo else { return }
                let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(clientInfo).takeUnretainedValue()
                watcher.onChange()
            },
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.35,
            FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagFileEvents
                    | kFSEventStreamCreateFlagWatchRoot
                    | kFSEventStreamCreateFlagNoDefer
            )
        )
    }

    func start() {
        guard let stream else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    func cancel() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit {
        cancel()
    }
}
