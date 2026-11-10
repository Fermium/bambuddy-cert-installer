import CoreServices
import Foundation

/// Calls back when anything changes under some folders, through FSEvents. A watch on the folder alone missed
/// Homebrew replacing an app.
final class FolderWatcher {
    private var stream: FSEventStreamRef?
    private let changed: () -> Void

    init(_ paths: [String], changed: @escaping () -> Void) {
        self.changed = changed
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue().changed()
        }
        stream = FSEventStreamCreate(nil, callback, &context, paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 2,
                                     FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer))
        if let stream {
            FSEventStreamSetDispatchQueue(stream, .main)
            FSEventStreamStart(stream)
        }
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
