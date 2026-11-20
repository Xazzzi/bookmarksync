import Foundation
import AppKit

class WriteQueue {
    static let shared = WriteQueue()
    static var lastWriteTimes: [String: Date] = [:]
    private static let lastWriteTimesLock = NSLock()
    weak var viewModel: AppViewModel?
    /// Called on the main queue when a write is dropped because its file changed.
    var onWriteConflict: ((URL) -> Void)?

    struct PendingWrite {
        let parser: BrowserParser
        let nodes: [ParsedBookmark]
        let bundleId: String
        /// `BookmarkSnapshotFingerprint` of the file when the sync read it.
        let expectedDiskFingerprint: String?
    }

    private var queue: [PendingWrite] = []
    private var timer: Timer?
    private let queueLock = NSLock()
    private let runningBundleIds: () -> Set<String>

    func isWritePending(for bundleId: String) -> Bool {
        queueLock.lock()
        defer { queueLock.unlock() }
        return queue.contains { $0.bundleId == bundleId }
    }

    /// Tests pass `monitorsSystem: false` to skip the flush timer and quit observer.
    init(
        monitorsSystem: Bool = true,
        runningBundleIds: @escaping () -> Set<String> = {
            Set(NSWorkspace.shared.runningApplications.filter { !$0.isTerminated }.compactMap { $0.bundleIdentifier })
        }
    ) {
        self.runningBundleIds = runningBundleIds
        guard monitorsSystem else { return }

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
    
    func enqueue(parser: BrowserParser, nodes: [ParsedBookmark], bundleId: String, expectedDiskFingerprint: String? = nil) {
        queueLock.lock()
        // Remove existing pending writes for the same file to prevent queue buildup
        queue.removeAll { $0.parser.filePath.path == parser.filePath.path }
        queue.append(PendingWrite(parser: parser, nodes: nodes, bundleId: bundleId, expectedDiskFingerprint: expectedDiskFingerprint))
        queueLock.unlock()
        flush()
    }
    
    func removePendingWrites(for bookmarkFilePath: String) {
        queueLock.lock()
        let matching = queue.filter { $0.parser.filePath.path == bookmarkFilePath }
        queue.removeAll { $0.parser.filePath.path == bookmarkFilePath }
        let queuedBundleIds = Set(queue.map { $0.bundleId })
        queueLock.unlock()
        let running = runningBundleIds()
        publishAwaitingQuit(queuedBundleIds.intersection(running))
        
        for pending in matching {
            DispatchQueue.main.async { [weak self] in
                self?.viewModel?.markBrowserSynced(bundleId: pending.bundleId)
            }
        }
    }
    
    /// True when the file no longer holds the tree the write was computed from.
    /// An unreadable file counts as changed.
    private func diskChanged(since pending: PendingWrite) -> Bool {
        guard let expected = pending.expectedDiskFingerprint else { return false }
        guard let live = try? pending.parser.read() else { return true }
        return BookmarkSnapshotFingerprint.compute(live) != expected
    }

    func flush() {
        let runningApps = runningBundleIds()

        queueLock.lock()
        var remaining: [PendingWrite] = []
        for pending in queue {
            if runningApps.contains(pending.bundleId) {
                // Browser is running, wait until it quits to safely write
                SyncLog.verbose("WriteQueue: waiting for \(pending.bundleId) to quit before writing")
                remaining.append(pending)
            } else if diskChanged(since: pending) {
                // Writing now would discard the newer edits; re-sync to merge them first.
                SyncLog.event("WriteQueue: \(pending.bundleId) changed on disk since it was read; dropping stale write")
                DispatchQueue.main.async { [weak self, filePath = pending.parser.filePath] in
                    self?.onWriteConflict?(filePath)
                }
            } else {
                do {
                    try pending.parser.write(nodes: pending.nodes)
                    WriteQueue.lastWriteTimesLock.lock()
                    WriteQueue.lastWriteTimes[pending.parser.filePath.path] = Date()
                    WriteQueue.lastWriteTimesLock.unlock()
                    SyncLog.event("Wrote bookmarks to \(pending.bundleId)")
                    
                    DispatchQueue.main.async { [weak self, bundleId = pending.bundleId] in
                        self?.viewModel?.queueError = nil
                        self?.viewModel?.markBrowserSynced(bundleId: bundleId)
                    }
                } catch let error as SafariBookmarksLock.LockError {
                    // Held for a second or two at a time; the next flush retries.
                    SyncLog.event("WriteQueue: deferring \(pending.bundleId) write: \(error.localizedDescription)")
                    remaining.append(pending)
                } catch {
                    SyncLog.error("Write failed for \(pending.bundleId): \(error)")
                    DispatchQueue.main.async { [weak self] in
                        self?.viewModel?.queueError = L10n.format("Write error (%@): %@", pending.bundleId, error.localizedDescription)
                    }
                    remaining.append(pending)
                }
            }
        }
        queue = remaining
        let awaitingQuit = Set(remaining.map { $0.bundleId }.filter { runningApps.contains($0) })
        queueLock.unlock()
        publishAwaitingQuit(awaitingQuit)
    }

    /// Tells the menu bar which browsers must be quit before their writes land.
    private func publishAwaitingQuit(_ bundleIds: Set<String>) {
        DispatchQueue.main.async { [weak self] in
            guard let viewModel = self?.viewModel, viewModel.browsersAwaitingQuit != bundleIds else { return }
            viewModel.browsersAwaitingQuit = bundleIds
        }
    }
    
    @objc private func handleAppTermination(_ notification: Notification) {
        // Any app termination can be a signal that a browser has quit.
        // We flush immediately so that browser-specific queue items write independently.
        DispatchQueue.main.async { [weak self] in
            self?.flush()
        }
    }
}
