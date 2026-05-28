import Foundation
import AppKit

class WriteQueue {
    static let shared = WriteQueue()
    static var lastWriteTimes: [String: Date] = [:]
    private static let lastWriteTimesLock = NSLock()
    weak var viewModel: AppViewModel?
    
    struct PendingWrite {
        let parser: BrowserParser
        let nodes: [BookmarkNode]
        let bundleId: String
    }
    
    private var queue: [PendingWrite] = []
    private var timer: Timer?
    private let queueLock = NSLock()
    
    func isWritePending(for bundleId: String) -> Bool {
        queueLock.lock()
        defer { queueLock.unlock() }
        return queue.contains { $0.bundleId == bundleId }
    }
    
    private init() {
        DispatchQueue.main.async {
            self.timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
                self?.flush()
            }
        }
        
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleAppTermination(_:)),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )
    }
    
    func enqueue(parser: BrowserParser, nodes: [BookmarkNode], bundleId: String) {
        queueLock.lock()
        // Remove existing pending writes for the same file to prevent queue buildup
        queue.removeAll { $0.parser.filePath.path == parser.filePath.path }
        queue.append(PendingWrite(parser: parser, nodes: nodes, bundleId: bundleId))
        queueLock.unlock()
        flush()
    }
    
    func removePendingWrites(for bookmarkFilePath: String) {
        queueLock.lock()
        let matching = queue.filter { $0.parser.filePath.path == bookmarkFilePath }
        queue.removeAll { $0.parser.filePath.path == bookmarkFilePath }
        queueLock.unlock()
        
        for pending in matching {
            DispatchQueue.main.async { [weak self] in
                self?.viewModel?.markBrowserSynced(bundleId: pending.bundleId)
            }
        }
    }
    
    private func flush() {
        let runningApps = NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier }
        
        queueLock.lock()
        var remaining: [PendingWrite] = []
        for pending in queue {
            if runningApps.contains(pending.bundleId) {
                // Browser is running, wait until it quits to safely write
                remaining.append(pending)
            } else {
                do {
                    try pending.parser.write(nodes: pending.nodes)
                    WriteQueue.lastWriteTimesLock.lock()
                    WriteQueue.lastWriteTimes[pending.parser.filePath.path] = Date()
                    WriteQueue.lastWriteTimesLock.unlock()
                    print("Successfully wrote to \(pending.bundleId)")
                    
                    DispatchQueue.main.async { [weak self, bundleId = pending.bundleId] in
                        self?.viewModel?.markBrowserSynced(bundleId: bundleId)
                    }
                } catch {
                    print("Write error for \(pending.bundleId): \(error)")
                    // Optionally retry, but for now we drop it or it could loop forever if permissions fail
                }
            }
        }
        queue = remaining
        queueLock.unlock()
    }
    
    @objc private func handleAppTermination(_ notification: Notification) {
        // Any app termination can be a signal that a browser has quit.
        // We flush immediately so that browser-specific queue items write independently.
        DispatchQueue.main.async { [weak self] in
            self?.flush()
        }
    }
}
