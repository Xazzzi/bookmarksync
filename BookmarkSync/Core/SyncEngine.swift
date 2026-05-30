import Foundation
import SwiftData

@MainActor
class SyncEngine {
    private static var watcher: FileWatcher?
    let modelContext: ModelContext
    let viewModel: AppViewModel
    private var debounceItem: DispatchWorkItem?
    
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
                print("SyncEngine: Ignoring change on \(path) from our own write")
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
    
    func updateWatcher(activeConfigs: [BrowserConfig]) {
        let watchDirs = Set(activeConfigs.map { 
            URL(fileURLWithPath: $0.bookmarkFilePath).deletingLastPathComponent().path 
        }).sorted()
        
        if let currentWatcher = Self.watcher, currentWatcher.pathsToWatch.sorted() == watchDirs {
            return
        }
        
        Self.watcher?.stop()
        Self.watcher = nil
        
        guard !watchDirs.isEmpty else { return }
        
        let newWatcher = FileWatcher(paths: watchDirs)
        newWatcher.callback = { [weak self] paths in
            guard let self = self else { return }
            Task { @MainActor in
                let activeFilePaths = activeConfigs.map { $0.bookmarkFilePath }
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
