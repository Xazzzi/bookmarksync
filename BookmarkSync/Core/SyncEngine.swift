import Foundation
import SwiftData

@MainActor
class SyncEngine {
    private static var watcher: FileWatcher?
    let modelContext: ModelContext
    let viewModel: AppViewModel
    private var debounceItem: DispatchWorkItem?
    /// True while a sync's background read is in flight.
    var isSyncing = false
    /// Set when a sync is requested while one is already running, so the request
    /// is honoured once the in-flight pass finishes. Tracked separately from the
    /// paths below because a full rescan carries no paths at all.
    var hasPendingSync = false
    /// Paths that changed while a sync was running, coalesced into the next pass.
    var pendingSyncPaths: Set<String> = []
    
    init(modelContext: ModelContext, viewModel: AppViewModel) {
        self.modelContext = modelContext
        self.viewModel = viewModel
    }
    
    func triggerSync(changedPaths: [String], forceImmediate: Bool = false) {
        if !viewModel.isWatchingEnabled && !changedPaths.isEmpty {
            return
        }
        
        let now = Date()
        let filteredPaths = changedPaths.filter { path in
            if let lastWrite = WriteQueue.lastWriteTimes[path], now.timeIntervalSince(lastWrite) < 5.0 {
                SyncLog.verbose("Ignoring change on \(path) from our own write")
                return false
            }
            return true
        }
        
        if !changedPaths.isEmpty && filteredPaths.isEmpty {
            return
        }
        
        debounceItem?.cancel()
        
        if forceImmediate {
            executeSync(changedPaths: filteredPaths)
            return
        }
        
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            Task { @MainActor in
                self.executeSync(changedPaths: filteredPaths)
            }
        }
        debounceItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + (changedPaths.isEmpty ? 0.0 : 1.0), execute: workItem)
    }
    
    /// Bookmark files the current watcher reports changes for.
    private static var watchedFiles: [String] = []

    func updateWatcher(activeConfigs: [BrowserConfig]) {
        // Capture plain paths, never the configs: the callback can outlive
        // them, and touching a deleted or reset @Model instance from it is a
        // fatal error.
        let activeFilePaths = activeConfigs.map { $0.bookmarkFilePath }.sorted()
        let watchDirs = Set(activeFilePaths.map {
            URL(fileURLWithPath: $0).deletingLastPathComponent().path
        }).sorted()

        if let currentWatcher = Self.watcher,
           currentWatcher.pathsToWatch.sorted() == watchDirs,
           Self.watchedFiles == activeFilePaths {
            return
        }

        Self.watcher?.stop()
        Self.watcher = nil
        Self.watchedFiles = activeFilePaths

        guard !watchDirs.isEmpty else { return }

        let newWatcher = FileWatcher(paths: watchDirs)
        newWatcher.callback = { [weak self] paths in
            guard let self = self else { return }
            Task { @MainActor in
                let relevantPaths = paths.filter { path in
                    activeFilePaths.contains(path) ||
                    activeFilePaths.contains((path as NSString).appendingPathComponent("Bookmarks")) ||
                    activeFilePaths.contains((path as NSString).appendingPathComponent("Bookmarks.plist")) ||
                    activeFilePaths.contains((path as NSString).appendingPathComponent("places.sqlite"))
                }

                if !relevantPaths.isEmpty {
                    self.triggerSync(changedPaths: relevantPaths)
                }
            }
        }
        newWatcher.start()
        Self.watcher = newWatcher
    }
    

    

}
