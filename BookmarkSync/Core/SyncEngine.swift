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
    
    private func updateWatcher(activeConfigs: [BrowserConfig]) {
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
    
    private func executeSync(changedPaths: [String]) {
        viewModel.syncStatus = "Syncing..."
        
        do {
            let allConfigs = try modelContext.fetch(FetchDescriptor<BrowserConfig>())
            let enabledConfigs = allConfigs.filter { $0.isEnabled && $0.profileSetId != nil && !$0.profileSetId!.isEmpty }
            
            updateWatcher(activeConfigs: enabledConfigs)
            
            if enabledConfigs.isEmpty {
                viewModel.syncStatus = "Idle"
                return
            }
            
            let configsBySet = Dictionary(grouping: enabledConfigs, by: { $0.profileSetId! })
            let allStateNodes = try modelContext.fetch(FetchDescriptor<BookmarkNode>())
            
            for (currentSetId, activeConfigs) in configsBySet {
                var configCurrentNodes: [String: [BookmarkNode]] = [:]
                var configParsers: [String: BrowserParser] = [:]
                
                for config in activeConfigs {
                    if config.bundleId == "com.apple.Safari" && !viewModel.isFullDiskAccessGranted {
                        print("SyncEngine: Skipping Safari sync because Full Disk Access is not granted")
                        continue
                    }
                    
                    let url = URL(fileURLWithPath: config.bookmarkFilePath)
                    var parser: BrowserParser?
                    if config.bundleId == "com.apple.Safari" {
                        parser = SafariParser(filePath: url, profileName: config.profileName)
                    } else if config.bundleId == "org.mozilla.firefox" {
                        parser = FirefoxParser(filePath: url)
                    } else {
                        parser = ChromeParser(filePath: url)
                    }
                    
                    if let parser = parser {
                        configParsers[config.id] = parser
                        let rawNodes = (try? parser.read()) ?? []
                        let mappedNodes = rawNodes.map { rawNode in
                            BookmarkNode(
                                id: "\(currentSetId):\(rawNode.id)",
                                title: rawNode.title,
                                url: rawNode.url,
                                type: rawNode.type,
                                parentId: rawNode.parentId != nil ? "\(currentSetId):\(rawNode.parentId!)" : nil,
                                mtime: rawNode.mtime,
                                profileSetId: currentSetId
                            )
                        }
                        configCurrentNodes[config.id] = mappedNodes
                    }
                }
                
                let stateNodes = allStateNodes.filter { $0.profileSetId == currentSetId }
                
                // Populate previousLatestNodes from viewModel cache or fallback to observedStateData
                var previousLatestNodes: [String: [String: BookmarkNode]] = [:]
                for config in activeConfigs {
                    if let cached = viewModel.latestBrowserNodes[config.id] {
                        previousLatestNodes[config.id] = cached
                    } else if let data = config.observedStateData,
                              let decoded = try? JSONDecoder().decode([String: BookmarkNodeRecord].self, from: data) {
                        var nodeMap: [String: BookmarkNode] = [:]
                        for (id, record) in decoded {
                            nodeMap[id] = BookmarkNode(
                                id: id,
                                title: record.title,
                                url: record.url,
                                type: record.type,
                                parentId: record.parentId,
                                mtime: Date(),
                                profileSetId: currentSetId
                            )
                        }
                        previousLatestNodes[config.id] = nodeMap
                        viewModel.latestBrowserNodes[config.id] = nodeMap
                    } else {
                        previousLatestNodes[config.id] = [:]
                    }
                }
                
                // Identify triggering profiles (local changes to import)
                var triggeringConfigs: [BrowserConfig] = []
                for config in activeConfigs {
                    var isTriggered = false
                    
                    // 1. File watcher path matches
                    let configDir = (config.bookmarkFilePath as NSString).deletingLastPathComponent
                    let isPathMatched = changedPaths.contains { path in
                        path == config.bookmarkFilePath || 
                        (path as NSString).standardizingPath == (config.bookmarkFilePath as NSString).standardizingPath ||
                        (path as NSString).deletingLastPathComponent == configDir
                    }
                    if isPathMatched {
                        isTriggered = true
                    }
                    
                    // 2. File mod time is newer than last sync time
                    if !isTriggered, let lastSync = config.lastSyncTime {
                        if let fileAttr = try? FileManager.default.attributesOfItem(atPath: config.bookmarkFilePath),
                           let fileModDate = fileAttr[.modificationDate] as? Date {
                            if fileModDate.timeIntervalSince(lastSync) > 1.0 {
                                print("SyncEngine: \(config.browserName) (\(config.profileName)) file changed while app closed. Mod: \(fileModDate), Last sync: \(lastSync)")
                                isTriggered = true
                            }
                        }
                    }
                    
                    // 3. Initial sync for a new profile
                    if !isTriggered, config.lastSyncTime == nil {
                        print("SyncEngine: Initial sync for \(config.browserName) (\(config.profileName)). Treating as triggering to import all local bookmarks.")
                        isTriggered = true
                    }
                    
                    if isTriggered {
                        triggeringConfigs.append(config)
                    }
                }
                
                // --- IMPORT PHASE (Spoke -> Hub) ---
                var updatedStateNodes = stateNodes
                var hasChanges = false
                
                for config in triggeringConfigs {
                    guard let currentNodes = configCurrentNodes[config.id] else { continue }
                    let latestDict = previousLatestNodes[config.id] ?? [:]
                    let currentDict = Dictionary(currentNodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                    
                    // 1. Handle Deletions
                    if config.lastSyncTime != nil {
                        for (id, latestNode) in latestDict {
                            if currentDict[id] == nil {
                                if let idx = updatedStateNodes.firstIndex(where: { $0.id == id }) {
                                    let stateNode = updatedStateNodes[idx]
                                    
                                    // Conflict check: if stateNode differs from latestNode, another profile updated it!
                                    let isModified = stateNode.title != latestNode.title || stateNode.url != latestNode.url || stateNode.parentId != latestNode.parentId
                                    
                                    if isModified {
                                        print("SyncEngine [Import]: Rejecting deletion of \(latestNode.title) (\(id)) from Hub because it was modified by another profile.")
                                    } else {
                                        let nodeToDelete = updatedStateNodes.remove(at: idx)
                                        modelContext.delete(nodeToDelete)
                                        hasChanges = true
                                        print("SyncEngine [Import]: Deleted \(nodeToDelete.title) (\(nodeToDelete.id)) from Hub")
                                        
                                        // Cancel any pending diffs for this bookmark in the queue!
                                        viewModel.cancelPendingDiffs(for: nodeToDelete.title)
                                    }
                                }
                            }
                        }
                    }
                    
                    // 2. Handle Additions & Updates
                    for (id, currentNode) in currentDict {
                        if let latestNode = latestDict[id] {
                            if config.lastSyncTime != nil {
                                if currentNode.title != latestNode.title || currentNode.url != latestNode.url || currentNode.parentId != latestNode.parentId {
                                    if let stateNode = updatedStateNodes.first(where: { $0.id == id }) {
                                        let oldTitle = stateNode.title
                                        stateNode.title = currentNode.title
                                        stateNode.url = currentNode.url
                                        stateNode.parentId = currentNode.parentId
                                        stateNode.mtime = Date()
                                        hasChanges = true
                                        print("SyncEngine [Import]: Updated \(currentNode.title) (\(id)) in Hub")
                                        
                                        // Cancel any pending diffs for the old or new title!
                                        viewModel.cancelPendingDiffs(for: oldTitle)
                                        viewModel.cancelPendingDiffs(for: currentNode.title)
                                    } else {
                                        // Node was deleted from Hub by another profile, but this profile updated it! Resurrect it.
                                        let newNode = BookmarkNode(
                                            id: currentNode.id,
                                            title: currentNode.title,
                                            url: currentNode.url,
                                            type: currentNode.type,
                                            parentId: currentNode.parentId,
                                            mtime: Date(),
                                            profileSetId: currentSetId
                                        )
                                        updatedStateNodes.append(newNode)
                                        modelContext.insert(newNode)
                                        hasChanges = true
                                        print("SyncEngine [Import]: Resurrected updated node \(newNode.title) (\(newNode.id)) to Hub")
                                        
                                        viewModel.cancelPendingDiffs(for: latestNode.title)
                                        viewModel.cancelPendingDiffs(for: currentNode.title)
                                    }
                                }
                            }
                        } else {
                            if !updatedStateNodes.contains(where: { $0.id == id }) {
                                let newNode = BookmarkNode(
                                    id: currentNode.id,
                                    title: currentNode.title,
                                    url: currentNode.url,
                                    type: currentNode.type,
                                    parentId: currentNode.parentId,
                                    mtime: Date(),
                                    profileSetId: currentSetId
                                )
                                updatedStateNodes.append(newNode)
                                modelContext.insert(newNode)
                                hasChanges = true
                                print("SyncEngine [Import]: Added \(newNode.title) (\(newNode.id)) to Hub")
                            }
                        }
                    }
                }
                
                // Clean up empty folders from Hub
                let filteredNodes = filterEmptyFolders(nodes: updatedStateNodes)
                if filteredNodes.count < updatedStateNodes.count {
                    let filteredIds = Set(filteredNodes.map { $0.id })
                    for node in updatedStateNodes {
                        if !filteredIds.contains(node.id) {
                            modelContext.delete(node)
                            hasChanges = true
                            print("SyncEngine [Import]: Filtered out empty folder \(node.title) (\(node.id))")
                        }
                    }
                    updatedStateNodes = filteredNodes
                }
                
                if hasChanges {
                    try modelContext.save()
                }
                
                // --- EXPORT PHASE (Hub -> Spoke) ---
                for config in activeConfigs {
                    let currentNodes = configCurrentNodes[config.id] ?? []
                    let currentDict = Dictionary(currentNodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                    let stateDict = Dictionary(updatedStateNodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                    
                    var mismatchTitles: [String] = []
                    
                    for (id, stateNode) in stateDict {
                        if let currentNode = currentDict[id] {
                            if currentNode.title != stateNode.title || currentNode.url != stateNode.url || currentNode.parentId != stateNode.parentId {
                                mismatchTitles.append("Update: \(stateNode.title)")
                            }
                        } else {
                            mismatchTitles.append("Add: \(stateNode.title)")
                        }
                    }
                    
                    for (id, currentNode) in currentDict {
                        if stateDict[id] == nil {
                            // Never cause deletions inside newly added profiles
                            if config.lastSyncTime != nil {
                                mismatchTitles.append("Delete: \(currentNode.title)")
                            } else {
                                print("SyncEngine [Export]: Newly added profile \(config.browserName) (\(config.profileName)) - keeping local item \(currentNode.title) instead of deleting it")
                            }
                        }
                    }
                    
                    if !mismatchTitles.isEmpty {
                        print("SyncEngine [Export]: Browser \(config.browserName) (\(config.profileName)) is out of sync. Changes: \(mismatchTitles.count)")
                        
                        for diffTitle in mismatchTitles {
                            let diff = DiffRecord(
                                bookmarkTitle: diffTitle,
                                sourceBundleIds: ["System"],
                                targetBundleIds: [config.bundleId],
                                sourceProfileNames: ["System"],
                                targetProfileNames: [config.profileName],
                                isWaiting: true,
                                profileSetId: currentSetId
                            )
                            viewModel.addDiff(diff)
                        }
                        
                        if viewModel.isWritingEnabled {
                            let cleanNodes = updatedStateNodes.map { node in
                                BookmarkNode(
                                    id: node.id,
                                    title: node.title,
                                    url: node.url,
                                    type: node.type,
                                    parentId: node.parentId,
                                    mtime: node.mtime,
                                    profileSetId: currentSetId
                                )
                            }
                            
                            if let parser = configParsers[config.id] {
                                WriteQueue.shared.enqueue(parser: parser, nodes: cleanNodes, bundleId: config.bundleId)
                            }
                        }
                    }
                    
                    // ALWAYS update the observed state to match what was actually read from disk
                    var nodeMap: [String: BookmarkNode] = [:]
                    var recordsMap: [String: BookmarkNodeRecord] = [:]
                    for node in currentNodes {
                        nodeMap[node.id] = node
                        recordsMap[node.id] = BookmarkNodeRecord(
                            id: node.id,
                            title: node.title,
                            url: node.url,
                            type: node.type,
                            parentId: node.parentId
                        )
                    }
                    viewModel.latestBrowserNodes[config.id] = nodeMap
                    
                    if let data = try? JSONEncoder().encode(recordsMap) {
                        config.observedStateData = data
                    }
                    
                    if config.lastSyncTime == nil || !mismatchTitles.isEmpty {
                        config.lastSyncTime = Date()
                        try? modelContext.save()
                    }
                }
                
                for config in activeConfigs {
                    viewModel.recordSyncTime(for: config.id)
                }
            }
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.viewModel.syncStatus = "Idle"
            }
        } catch {
            print("Sync failed: \(error)")
        }
    }
    
    private func filterEmptyFolders(nodes: [BookmarkNode]) -> [BookmarkNode] {
        var parentToChildren: [String?: [BookmarkNode]] = [:]
        for node in nodes {
            parentToChildren[node.parentId, default: []].append(node)
        }
        
        func hasLeafDescendant(_ node: BookmarkNode) -> Bool {
            if node.type == .leaf {
                return true
            }
            guard let children = parentToChildren[node.id] else {
                return false
            }
            for child in children {
                if hasLeafDescendant(child) {
                    return true
                }
            }
            return false
        }
        
        return nodes.filter { node in
            if node.type == .leaf {
                return true
            }
            return hasLeafDescendant(node)
        }
    }
    
    func merge(
        state: [BookmarkNode],
        browsers: [[BookmarkNode]],
        activeConfigs: [BrowserConfig],
        initialSyncMap: [String: Bool] = [:],
        profileSetId: String = ""
    ) -> ([BookmarkNode], [DiffRecord]) {
        var updatedStateNodes = state
        
        for (idx, config) in activeConfigs.enumerated() {
            guard idx < browsers.count else { continue }
            let currentNodes = browsers[idx]
            
            let latestNodes: [String: BookmarkNode]
            if let cached = viewModel.latestBrowserNodes[config.id] {
                latestNodes = cached
            } else if let data = config.observedStateData,
                      let decoded = try? JSONDecoder().decode([String: BookmarkNodeRecord].self, from: data) {
                var nodeMap: [String: BookmarkNode] = [:]
                for (id, record) in decoded {
                    nodeMap[id] = BookmarkNode(
                        id: id,
                        title: record.title,
                        url: record.url,
                        type: record.type,
                        parentId: record.parentId,
                        mtime: Date(),
                        profileSetId: profileSetId
                    )
                }
                latestNodes = nodeMap
            } else {
                latestNodes = [:]
            }
            
            let currentDict = Dictionary(currentNodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            
            let isNewlyEnabled = config.lastSyncTime == nil || initialSyncMap[config.id] == true
            
            // Handle deletions
            if !isNewlyEnabled {
                for (id, _) in latestNodes {
                    if currentDict[id] == nil {
                        if let idx = updatedStateNodes.firstIndex(where: { $0.id == id }) {
                            updatedStateNodes.remove(at: idx)
                        }
                    }
                }
            }
            
            // Handle additions and updates
            for (id, currentNode) in currentDict {
                if let latestNode = latestNodes[id] {
                    if !isNewlyEnabled {
                        if currentNode.title != latestNode.title || currentNode.url != latestNode.url || currentNode.parentId != latestNode.parentId {
                            if let stateNode = updatedStateNodes.first(where: { $0.id == id }) {
                                stateNode.title = currentNode.title
                                stateNode.url = currentNode.url
                                stateNode.parentId = currentNode.parentId
                            }
                        }
                    }
                } else {
                    if !updatedStateNodes.contains(where: { $0.id == id }) {
                        updatedStateNodes.append(currentNode)
                    }
                }
            }
        }
        
        let filtered = filterEmptyFolders(nodes: updatedStateNodes)
        return (filtered, [])
    }
}
