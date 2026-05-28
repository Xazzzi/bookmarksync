import Foundation
import CoreServices

class FileWatcher {
    let pathsToWatch: [String]
    var callback: (([String]) -> Void)?
    
    private var stream: FSEventStreamRef?
    
    init(paths: [String]) {
        self.pathsToWatch = paths
    }
    
    func start() {
        let pathsToWatchAsCFArray = pathsToWatch as CFArray
        
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        
        let fsCallback: FSEventStreamCallback = { (streamRef, clientCallBackInfo, numEvents, eventPaths, eventFlags, eventIds) in
            guard let info = clientCallBackInfo else { return }
            let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
            let paths = Unmanaged<NSArray>.fromOpaque(eventPaths).takeUnretainedValue() as? [String] ?? []
            
            DispatchQueue.main.async {
                watcher.callback?(paths)
            }
        }
        
        stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            fsCallback,
            &context,
            pathsToWatchAsCFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            2.0, // Debounce 2 seconds
            UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)
        )
        
        if let stream = stream {
            FSEventStreamSetDispatchQueue(stream, DispatchQueue.global(qos: .background))
            FSEventStreamStart(stream)
        }
    }
    
    func stop() {
        if let stream = stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
    }
}
