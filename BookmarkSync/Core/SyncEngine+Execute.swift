import Foundation
import SwiftData

/// What one profile's storage contained, as read off the main actor.
private struct ProfileRead: Sendable {
    let configId: String
    let parser: BrowserParser
    let nodes: [ParsedBookmark]
}

/// Reads every requested profile's bookmark file. Free of SwiftData and of the
/// main actor: file I/O, JSON/plist decoding and Firefox's SQLite copy+query all
/// happen here so they never stall the UI.
private func readProfiles(_ requests: [(configId: String, bundleId: String, profileName: String, path: String, setId: String)]) async -> [ProfileRead] {
    // The entire point of this function is to keep parsing off the UI thread.
    // Whether it does depends on subtle isolation rules (a nonisolated async
    // function does not inherit its caller's actor), so assert it rather than
    // assume it: if a future change re-isolates this to the main actor, debug
    // runs and the test suite fail loudly instead of silently regressing.
    dispatchPrecondition(condition: .notOnQueue(.main))

    return await withTaskGroup(of: ProfileRead?.self) { group in
        for request in requests {
            group.addTask {
                let url = URL(fileURLWithPath: request.path)
                let parser: BrowserParser
                switch request.bundleId {
                case "com.apple.Safari":
                    parser = SafariParser(filePath: url, profileName: request.profileName)
                case "org.mozilla.firefox":
                    parser = FirefoxParser(filePath: url)
                default:
                    parser = ChromeParser(filePath: url)
                }

                do {
                    let raw = try parser.read()
                    // Namespace ids to the profile set while we are still off-main.
                    let prefixed = raw.map { node in
                        ParsedBookmark(
                            id: "\(request.setId):\(node.id)",
                            title: node.title,
                            url: node.url,
                            type: node.type,
                            parentId: node.parentId.map { "\(request.setId):\($0)" },
                            mtime: node.mtime,
                            index: node.index
                        )
                    }
                    return ProfileRead(configId: request.configId, parser: parser, nodes: prefixed)
                } catch {
                    SyncLog.error("Failed to read \(request.bundleId) (\(request.profileName)) - skipping: \(error)")
                    return nil
                }
            }
        }

        var results: [ProfileRead] = []
        for await case let read? in group {
            results.append(read)
        }
        return results
    }
}

extension SyncEngine {
    /// Entry point. Gathers what needs reading on the main actor, performs the
    /// reads in the background, then applies the result back on the main actor.
    func executeSync(changedPaths: [String]) {
        guard !isSyncing else {
            // A sync is already in flight; coalesce into it rather than
            // interleaving two passes over the same store. The flag is set
            // unconditionally: a full rescan arrives with no paths, so an empty
            // `changedPaths` must still schedule a follow-up pass.
            hasPendingSync = true
            pendingSyncPaths.formUnion(changedPaths)
            return
        }

        viewModel.syncStatus = "Syncing..."

        let allConfigs = (try? modelContext.fetch(FetchDescriptor<BrowserConfig>())) ?? []
        let enabledConfigs = allConfigs.filter { $0.isEnabled && $0.profileSetId != nil && !$0.profileSetId!.isEmpty }

        updateWatcher(activeConfigs: enabledConfigs)

        guard !enabledConfigs.isEmpty else {
            viewModel.syncStatus = "Idle"
            return
        }

        let requests = enabledConfigs.compactMap { config -> (configId: String, bundleId: String, profileName: String, path: String, setId: String)? in
            if config.bundleId == "com.apple.Safari" && !viewModel.isFullDiskAccessGranted {
                SyncLog.event("Skipping Safari sync: Full Disk Access not granted")
                return nil
            }
            return (config.id, config.bundleId, config.profileName, config.bookmarkFilePath, config.profileSetId!)
        }

        isSyncing = true
        Task { [weak self] in
            let reads = await readProfiles(requests)
            guard let self else { return }
            // No `await`: this Task inherits the engine's main-actor isolation,
            // which is exactly where the SwiftData work below belongs. Only the
            // read above hops off the main thread.
            self.applySync(changedPaths: changedPaths, reads: reads)
        }
    }

    /// Applies already-parsed browser state to the hub and queues any writes.
    /// Runs on the main actor because everything here touches SwiftData.
    private func applySync(changedPaths: [String], reads: [ProfileRead]) {
        defer {
            isSyncing = false
            // Drain any sync request that arrived while this one was reading.
            if hasPendingSync {
                let queued = Array(pendingSyncPaths)
                hasPendingSync = false
                pendingSyncPaths.removeAll()
                triggerSync(changedPaths: queued)
            }
        }

        do {
            let allConfigs = try modelContext.fetch(FetchDescriptor<BrowserConfig>())
            let enabledConfigs = allConfigs.filter { $0.isEnabled && $0.profileSetId != nil && !$0.profileSetId!.isEmpty }

            guard !enabledConfigs.isEmpty else {
                viewModel.syncStatus = "Idle"
                return
            }

            let readsByConfig = Dictionary(reads.map { ($0.configId, $0) }, uniquingKeysWith: { first, _ in first })
            let configsBySet = Dictionary(grouping: enabledConfigs, by: { $0.profileSetId! })
            let allStateNodes = try modelContext.fetch(FetchDescriptor<BookmarkNode>())

            for (currentSetId, activeConfigs) in configsBySet {
                var configCurrentNodes: [String: [ParsedBookmark]] = [:]
                var configParsers: [String: BrowserParser] = [:]

                for config in activeConfigs {
                    guard let read = readsByConfig[config.id] else { continue }
                    configParsers[config.id] = read.parser
                    configCurrentNodes[config.id] = read.nodes
                }
                
                let stateNodes = allStateNodes.filter { $0.profileSetId == currentSetId }
                
                // Populate previousLatestNodes from viewModel cache or fallback to observedStateData
                var previousLatestNodes: [String: [String: ParsedBookmark]] = [:]
                for config in activeConfigs {
                    if let cached = viewModel.latestBrowserNodes[config.id] {
                        previousLatestNodes[config.id] = cached
                    } else if let data = config.observedStateData,
                              let decoded = try? JSONDecoder().decode([String: BookmarkNodeRecord].self, from: data) {
                        var nodeMap: [String: ParsedBookmark] = [:]
                        for (id, record) in decoded {
                            nodeMap[id] = ParsedBookmark(
                                id: id,
                                title: record.title,
                                url: record.url,
                                type: record.type,
                                parentId: record.parentId,
                                mtime: Date(),
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
                                SyncLog.event("\(config.browserName) (\(config.profileName)) changed while app closed (mod: \(fileModDate), last sync: \(lastSync))")
                                isTriggered = true
                            }
                        }
                    }
                    
                    // 3. Initial sync for a new profile
                    if !isTriggered, config.lastSyncTime == nil {
                        SyncLog.event("Initial sync for \(config.browserName) (\(config.profileName)): importing all local bookmarks")
                        isTriggered = true
                    }
                    
                    if isTriggered {
                        triggeringConfigs.append(config)
                    }
                }
                
                // --- IMPORT PHASE (Spoke -> Hub) ---
                // `stateById` is the authoritative index into the hub for this
                // profile set. The previous implementation searched the node
                // array linearly (firstIndex/first/contains) inside a loop over
                // every browser node, making the import O(N^2) — ~9M comparisons
                // per profile at 3k bookmarks. All lookups below are O(1), and
                // the index is kept in step with every insert/delete.
                var stateById = Dictionary(
                    stateNodes.map { ($0.id, $0) },
                    uniquingKeysWith: { first, _ in first }
                )
                /// Titles whose pending diffs must be cancelled. Collected here and
                /// applied once after the loop: `cancelPendingDiffs` rescans the
                /// whole diff history per call, so calling it per node was itself
                /// quadratic.
                var titlesToCancel = Set<String>()
                var hasChanges = false

                for config in triggeringConfigs {
                    guard let currentNodes = configCurrentNodes[config.id] else { continue }
                    let latestDict = previousLatestNodes[config.id] ?? [:]
                    let currentDict = Dictionary(currentNodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

                    // 1. Handle Deletions
                    if config.lastSyncTime != nil {
                        for (id, latestNode) in latestDict {
                            guard currentDict[id] == nil, let stateNode = stateById[id] else { continue }

                            // Conflict check: if stateNode differs from latestNode, another profile updated it!
                            let isModified = stateNode.title != latestNode.title || stateNode.url != latestNode.url || stateNode.parentId != latestNode.parentId

                            if isModified {
                                SyncLog.verbose("[Import] Rejecting deletion of \(latestNode.title) (\(id)): modified by another profile")
                            } else {
                                stateById.removeValue(forKey: id)
                                modelContext.delete(stateNode)
                                hasChanges = true
                                SyncLog.verbose("[Import] Deleted \(stateNode.title) (\(id)) from Hub")

                                // Cancel any pending diffs for this bookmark in the queue!
                                titlesToCancel.insert(stateNode.title)
                            }
                        }
                    }

                    // 2. Handle Additions & Updates
                    for (id, currentNode) in currentDict {
                        if let latestNode = latestDict[id] {
                            guard config.lastSyncTime != nil else { continue }
                            guard currentNode.title != latestNode.title || currentNode.url != latestNode.url || currentNode.parentId != latestNode.parentId || currentNode.index != latestNode.index else { continue }

                            if let stateNode = stateById[id] {
                                if stateNode.title != currentNode.title || stateNode.url != currentNode.url || stateNode.parentId != currentNode.parentId || stateNode.index != currentNode.index {
                                    let oldTitle = stateNode.title
                                    stateNode.title = currentNode.title
                                    stateNode.url = currentNode.url
                                    stateNode.parentId = currentNode.parentId
                                    stateNode.index = currentNode.index
                                    stateNode.mtime = Date()
                                    hasChanges = true
                                    SyncLog.verbose("[Import] Updated \(currentNode.title) (\(id)) in Hub")

                                    // Cancel any pending diffs for the old or new title!
                                    titlesToCancel.insert(oldTitle)
                                    titlesToCancel.insert(currentNode.title)
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
                                stateById[newNode.id] = newNode
                                modelContext.insert(newNode)
                                hasChanges = true
                                SyncLog.verbose("[Import] Resurrected \(newNode.title) (\(newNode.id)) to Hub")

                                titlesToCancel.insert(latestNode.title)
                                titlesToCancel.insert(currentNode.title)
                            }
                        } else if stateById[id] == nil {
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
                            stateById[newNode.id] = newNode
                            modelContext.insert(newNode)
                            hasChanges = true
                            SyncLog.verbose("[Import] Added \(newNode.title) (\(newNode.id)) to Hub")
                        }
                    }
                }

                if !titlesToCancel.isEmpty {
                    viewModel.cancelPendingDiffs(forTitles: titlesToCancel)
                }

                var updatedStateNodes = Array(stateById.values)
                
                // Clean up empty folders from Hub
                let filteredNodes = filterEmptyFolders(nodes: updatedStateNodes)
                if filteredNodes.count < updatedStateNodes.count {
                    let filteredIds = Set(filteredNodes.map { $0.id })
                    for node in updatedStateNodes {
                        if !filteredIds.contains(node.id) {
                            modelContext.delete(node)
                            hasChanges = true
                            SyncLog.verbose("[Import] Filtered out empty folder \(node.title) (\(node.id))")
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
                            SyncLog.verbose("[Import] Normalized index for \(child.title) to \(i)")
                        }
                    }
                }
                
                if hasChanges {
                    try modelContext.save()
                    // Tell views their cached projections are stale: in-place
                    // edits to @Model instances are invisible to onChange.
                    viewModel.noteBookmarkDataChanged()
                }
                
                // --- EXPORT PHASE (Hub -> Spoke) ---
                // Built once rather than per config: `updatedStateNodes` is the
                // same hub snapshot for every profile in this set.
                let stateDict = Dictionary(
                    updatedStateNodes.map { ($0.id, $0) },
                    uniquingKeysWith: { first, _ in first }
                )
                /// The nodes handed to the write queue. Detached value copies are
                /// made at most once per set (not once per profile) and only when
                /// some profile actually needs a write.
                var cleanNodesForWrite: [ParsedBookmark]?

                for config in activeConfigs {
                    guard let currentNodes = configCurrentNodes[config.id] else { continue }
                    let currentDict = Dictionary(currentNodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

                    // One activity row per change, collected here and published in
                    // a single mutation below rather than one at a time.
                    var changeTitles: [String] = []
                    var needsReorder = false
                    var suppressedDeletions = 0

                    @inline(__always)
                    func noteChange(_ title: String) {
                        changeTitles.append(title)
                    }

                    for (id, stateNode) in stateDict {
                        if let currentNode = currentDict[id] {
                            if currentNode.title != stateNode.title || currentNode.url != stateNode.url || currentNode.parentId != stateNode.parentId {
                                noteChange("Update: \(stateNode.title)")
                            } else if currentNode.index != stateNode.index {
                                needsReorder = true
                            }
                        } else {
                            noteChange("Add: \(stateNode.title)")
                        }
                    }

                    for (id, currentNode) in currentDict {
                        if stateDict[id] == nil {
                            // Never cause deletions inside newly added profiles
                            if config.lastSyncTime != nil {
                                noteChange("Delete: \(currentNode.title)")
                            } else {
                                suppressedDeletions += 1
                            }
                        }
                    }

                    if suppressedDeletions > 0 {
                        SyncLog.event("[Export] \(config.browserName) (\(config.profileName)) newly added - keeping \(suppressedDeletions) local item(s) instead of deleting")
                    }

                    let hasMismatch = !changeTitles.isEmpty

                    if hasMismatch || needsReorder {
                        if hasMismatch {
                            SyncLog.event("[Export] \(config.browserName) (\(config.profileName)) out of sync. Changes: \(changeTitles.count)")
                            viewModel.addDiffs(
                                titles: changeTitles,
                                targetBundleId: config.bundleId,
                                targetProfileName: config.profileName,
                                profileSetId: currentSetId
                            )
                        } else {
                            SyncLog.event("[Export] \(config.browserName) (\(config.profileName)) out of order. Triggering Reorder.")
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

                        if viewModel.isWritingEnabled, let parser = configParsers[config.id] {
                            if cleanNodesForWrite == nil {
                                cleanNodesForWrite = updatedStateNodes.map { node in
                                    ParsedBookmark(
                                        id: node.id,
                                        title: node.title,
                                        url: node.url,
                                        type: node.type,
                                        parentId: node.parentId,
                                        mtime: node.mtime,
                                        index: node.index
                                    )
                                }
                            }
                            if let cleanNodes = cleanNodesForWrite {
                                WriteQueue.shared.enqueue(parser: parser, nodes: cleanNodes, bundleId: config.bundleId)
                            }
                        }
                    }

                    // ALWAYS update the observed state to match what was actually read from disk
                    var nodeMap: [String: ParsedBookmark] = [:]
                    nodeMap.reserveCapacity(currentNodes.count)
                    var recordsMap: [String: BookmarkNodeRecord] = [:]
                    recordsMap.reserveCapacity(currentNodes.count)
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

                    if config.lastSyncTime == nil || hasMismatch {
                        config.lastSyncTime = Date()
                        try? modelContext.save()
                    }
                }
            }
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.viewModel.syncStatus = "Idle"
            }
        } catch {
            // Never leave the UI pinned to "Syncing..." after a failure.
            SyncLog.error("Sync failed: \(error)")
            viewModel.syncStatus = "Idle"
        }
    }
}
