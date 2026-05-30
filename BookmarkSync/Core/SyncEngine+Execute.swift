import Foundation
import SwiftData

extension SyncEngine {
    func executeSync(changedPaths: [String]) {
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
                                profileSetId: currentSetId,
                                index: rawNode.index
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
                                profileSetId: currentSetId,
                                index: record.index ?? 0
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
                                if currentNode.title != latestNode.title || currentNode.url != latestNode.url || currentNode.parentId != latestNode.parentId || currentNode.index != latestNode.index {
                                    if let stateNode = updatedStateNodes.first(where: { $0.id == id }) {
                                        if stateNode.title != currentNode.title || stateNode.url != currentNode.url || stateNode.parentId != currentNode.parentId || stateNode.index != currentNode.index {
                                            let oldTitle = stateNode.title
                                            stateNode.title = currentNode.title
                                            stateNode.url = currentNode.url
                                            stateNode.parentId = currentNode.parentId
                                            stateNode.index = currentNode.index
                                            stateNode.mtime = Date()
                                            hasChanges = true
                                            print("SyncEngine [Import]: Updated \(currentNode.title) (\(id)) in Hub")
                                            
                                            // Cancel any pending diffs for the old or new title!
                                            viewModel.cancelPendingDiffs(for: oldTitle)
                                            viewModel.cancelPendingDiffs(for: currentNode.title)
                                        }
                                    } else {
                                        // Node was deleted from Hub by another profile, but this profile updated it! Resurrect it.
                                        let newNode = BookmarkNode(
                                            id: currentNode.id,
                                            title: currentNode.title,
                                            url: currentNode.url,
                                            type: currentNode.type,
                                            parentId: currentNode.parentId,
                                            mtime: Date(),
                                            profileSetId: currentSetId,
                                            index: currentNode.index
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
                                    profileSetId: currentSetId,
                                    index: currentNode.index
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
                
                // Normalize indexes to resolve any collisions
                var parentGroups: [String: [BookmarkNode]] = [:]
                for node in updatedStateNodes {
                    let groupKey: String
                    if let pid = node.parentId {
                        groupKey = pid
                    } else {
                        let stripped = stripProfileSetPrefix(node.id)
                        let prefix = stripped.split(separator: ":").first.map(String.init) ?? "unknown"
                        groupKey = "root:\(prefix)"
                    }
                    parentGroups[groupKey, default: []].append(node)
                }
                
                for (_, children) in parentGroups {
                    let sortedChildren = children.sorted { 
                        if $0.index == $1.index {
                            if $0.mtime == $1.mtime {
                                return $0.id < $1.id
                            }
                            return $0.mtime > $1.mtime // Newest modification wins tie (gets earlier index)
                        }
                        return $0.index < $1.index 
                    }
                    
                    for (i, child) in sortedChildren.enumerated() {
                        if child.index != i {
                            child.index = i
                            hasChanges = true
                            print("SyncEngine [Import]: Normalized index for \(child.title) to \(i)")
                        }
                    }
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
                    var needsReorder = false
                    
                    for (id, stateNode) in stateDict {
                        if let currentNode = currentDict[id] {
                            if currentNode.title != stateNode.title || currentNode.url != stateNode.url || currentNode.parentId != stateNode.parentId {
                                mismatchTitles.append("Update: \(stateNode.title)")
                            } else if currentNode.index != stateNode.index {
                                needsReorder = true
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
                    
                    if !mismatchTitles.isEmpty || needsReorder {
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
                        } else if needsReorder {
                            print("SyncEngine [Export]: Browser \(config.browserName) (\(config.profileName)) is out of order. Triggering Reorder.")
                            let diff = DiffRecord(
                                bookmarkTitle: "Reorder",
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
                                    profileSetId: currentSetId,
                                    index: node.index
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
                            parentId: node.parentId,
                            index: node.index
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
}
