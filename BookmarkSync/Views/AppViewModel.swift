import SwiftUI
import SwiftData

struct DiffRecord: Identifiable {
    let id = UUID()
    let bookmarkTitle: String
    let sourceBundleIds: [String]
    var targetBundleIds: [String]
    let sourceProfileNames: [String]
    var targetProfileNames: [String]
    var isWaiting: Bool
    let profileSetId: String?
}

enum SyncState: Int, Codable {
    case stopped = 0
    case readOnly = 1
    case active = 2
}

@MainActor
class AppViewModel: ObservableObject {
    @Published var syncStatus: String = "Idle"
    @Published var diffHistory: [DiffRecord] = []
    @Published var lastSyncTimes: [String: Date] = [:]
    @Published var isFullDiskAccessGranted: Bool = true
    @Published var isWatchingEnabled: Bool = true
    @Published var isWritingEnabled: Bool = true
    @Published var syncOrderEnabled: Bool = false {
        didSet { UserDefaults.standard.set(syncOrderEnabled, forKey: "syncOrderEnabled") }
    }
    @Published var latestBrowserNodes: [String: [String: BookmarkNode]] = [:]
    
    @Published var profileSets: [ProfileSet] = []
    @Published var selectedProfileSetId: String?
    @Published var isActivityFilterGlobal: Bool = true
    @Published var queueError: String?
    
    @Published var syncState: SyncState = .readOnly {
        didSet {
            UserDefaults.standard.set(syncState.rawValue, forKey: "syncState")
            isWatchingEnabled = syncState != .stopped
            isWritingEnabled = syncState == .active
        }
    }
    
    var modelContext: ModelContext?
    var syncEngine: SyncEngine?
    
    init() {
        let raw = UserDefaults.standard.integer(forKey: "syncState")
        let savedState = SyncState(rawValue: raw) ?? .readOnly
        self.syncState = savedState
        self.isWatchingEnabled = savedState != .stopped
        self.isWritingEnabled = savedState == .active
        self.syncOrderEnabled = UserDefaults.standard.bool(forKey: "syncOrderEnabled")
        WriteQueue.shared.viewModel = self
    }
    
    func loadProfileSets() {
        guard let context = modelContext else { return }
        let sets = (try? context.fetch(FetchDescriptor<ProfileSet>())) ?? []
        if sets.isEmpty {
            let defaultSet = ProfileSet(name: "Set 1")
            context.insert(defaultSet)
            try? context.save()
            self.profileSets = [defaultSet]
            self.selectedProfileSetId = defaultSet.id
            UserDefaults.standard.set(defaultSet.id, forKey: "selectedProfileSetId")
        } else {
            self.profileSets = sets.sorted(by: { $0.name < $1.name })
            let savedId = UserDefaults.standard.string(forKey: "selectedProfileSetId")
            if let savedId = savedId, sets.contains(where: { $0.id == savedId }) {
                self.selectedProfileSetId = savedId
            } else {
                self.selectedProfileSetId = sets.first?.id
            }
        }
        
        // Migrate legacy nil/empty profileSetId nodes and configs to the resolved selectedProfileSetId
        let targetSetId = self.selectedProfileSetId ?? ""
        if !targetSetId.isEmpty {
            if let configs = try? context.fetch(FetchDescriptor<BrowserConfig>()) {
                for config in configs {
                    if !config.isEnabled {
                        config.profileSetId = nil
                    } else if config.profileSetId == nil || config.profileSetId == "" {
                        config.profileSetId = targetSetId
                    }
                }
            }
            if let nodes = try? context.fetch(FetchDescriptor<BookmarkNode>()) {
                for node in nodes {
                    if node.profileSetId == nil || node.profileSetId == "" {
                        node.profileSetId = targetSetId
                        // Also prefix its ID and parentId if they are not already prefixed!
                        if !node.id.starts(with: targetSetId + ":") {
                            node.id = "\(targetSetId):\(node.id)"
                        }
                        if let parentId = node.parentId, !parentId.isEmpty, !parentId.starts(with: targetSetId + ":") {
                            node.parentId = "\(targetSetId):\(parentId)"
                        }
                    }
                }
            }
            try? context.save()
        }
    }
    
    func addDiff(_ diff: DiffRecord) {
        if diff.bookmarkTitle != "Reorder" {
            for target in diff.targetBundleIds {
                if let idx = diffHistory.firstIndex(where: { $0.bookmarkTitle == "Reorder" && $0.isWaiting }) {
                    if let tIdx = diffHistory[idx].targetBundleIds.firstIndex(of: target) {
                        diffHistory[idx].targetBundleIds.remove(at: tIdx)
                        if tIdx < diffHistory[idx].targetProfileNames.count {
                            diffHistory[idx].targetProfileNames.remove(at: tIdx)
                        }
                    }
                    if diffHistory[idx].targetBundleIds.isEmpty {
                        diffHistory.remove(at: idx)
                    }
                }
            }
        } else {
            if let idx = diffHistory.firstIndex(where: { $0.bookmarkTitle == "Reorder" && $0.isWaiting }) {
                for (i, target) in diff.targetBundleIds.enumerated() {
                    if !diffHistory[idx].targetBundleIds.contains(target) {
                        diffHistory[idx].targetBundleIds.append(target)
                        diffHistory[idx].targetProfileNames.append(diff.targetProfileNames[i])
                    }
                }
                return
            }
        }
        
        if diffHistory.contains(where: { 
            $0.bookmarkTitle == diff.bookmarkTitle && 
            Set($0.sourceBundleIds) == Set(diff.sourceBundleIds) && 
            Set($0.targetBundleIds) == Set(diff.targetBundleIds) 
        }) {
            return
        }
        diffHistory.insert(diff, at: 0)
    }
    
    func markSynced(diffId: UUID) {
        if let idx = diffHistory.firstIndex(where: { $0.id == diffId }) {
            diffHistory[idx].isWaiting = false
        }
    }
    
    func markBrowserSynced(bundleId: String) {
        for idx in diffHistory.indices {
            if diffHistory[idx].targetBundleIds.contains(bundleId) {
                diffHistory[idx].isWaiting = false
            }
        }
    }
    
    func clearHistory() {
        diffHistory = []
    }
    
    func removeDiffs(for bundleId: String, profileName: String) {
        for idx in diffHistory.indices.reversed() {
            var diff = diffHistory[idx]
            
            var keepTargets = [String]()
            var keepProfiles = [String]()
            for i in 0..<diff.targetBundleIds.count {
                if diff.targetBundleIds[i] == bundleId && diff.targetProfileNames[i] == profileName {
                    continue
                }
                keepTargets.append(diff.targetBundleIds[i])
                keepProfiles.append(diff.targetProfileNames[i])
            }
            
            diff.targetBundleIds = keepTargets
            diff.targetProfileNames = keepProfiles
            diffHistory[idx] = diff
            
            if diffHistory[idx].targetBundleIds.isEmpty {
                diffHistory.remove(at: idx)
            }
        }
    }
    
    func cancelPendingDiffs(for bookmarkTitle: String, bundleId: String? = nil) {
        let cleanTitle = bookmarkTitle
            .replacingOccurrences(of: "Add: ", with: "")
            .replacingOccurrences(of: "Update: ", with: "")
            .replacingOccurrences(of: "Delete: ", with: "")
            
        diffHistory.removeAll { diff in
            let diffCleanTitle = diff.bookmarkTitle
                .replacingOccurrences(of: "Add: ", with: "")
                .replacingOccurrences(of: "Update: ", with: "")
                .replacingOccurrences(of: "Delete: ", with: "")
                
            let matchesBundle = bundleId == nil ? true : diff.targetBundleIds.contains(bundleId!)
            return diff.isWaiting &&
                   matchesBundle &&
                   diffCleanTitle == cleanTitle
        }
    }
    
        func deleteProfileSet(withId id: String) {
        guard let context = modelContext else { return }
        
        // 1. Delete associated BookmarkNode entities
        if let nodes = try? context.fetch(FetchDescriptor<BookmarkNode>()) {
            for node in nodes {
                if node.profileSetId == id {
                    context.delete(node)
                }
            }
        }
        
        // 2. Clear profileSetId and disable associated configs
        if let configs = try? context.fetch(FetchDescriptor<BrowserConfig>()) {
            for config in configs {
                if config.profileSetId == id {
                    config.profileSetId = nil
                    config.isEnabled = false
                    WriteQueue.shared.removePendingWrites(for: config.bookmarkFilePath)
                }
            }
        }
        
        // 3. Delete the ProfileSet itself
        if let sets = try? context.fetch(FetchDescriptor<ProfileSet>()) {
            if let targetSet = sets.first(where: { $0.id == id }) {
                context.delete(targetSet)
            }
        }
        
        try? context.save()
        
        // 4. Clear associated queue/diff history items
        diffHistory.removeAll { $0.profileSetId == id }
        
        // Refresh local lists
        loadProfileSets()
    }
    
    func cleanOrphanedNodes(for profileSetId: String) {
        guard let context = modelContext, !profileSetId.isEmpty else { return }
        
        let allConfigs = (try? context.fetch(FetchDescriptor<BrowserConfig>())) ?? []
        let remainingConfigs = allConfigs.filter { $0.isEnabled && $0.profileSetId == profileSetId }
        
        var validIds = Set<String>()
        for config in remainingConfigs {
            if let data = config.observedStateData,
               let decoded = try? JSONDecoder().decode([String: BookmarkNodeRecord].self, from: data) {
                validIds.formUnion(decoded.keys)
            }
        }
        
        let allNodes = (try? context.fetch(FetchDescriptor<BookmarkNode>())) ?? []
        let setNodes = allNodes.filter { $0.profileSetId == profileSetId }
        
        var deletedCount = 0
        for node in setNodes {
            if !validIds.contains(node.id) {
                context.delete(node)
                cancelPendingDiffs(for: node.title)
                deletedCount += 1
            }
        }
        
        if deletedCount > 0 {
            try? context.save()
            print("Cleaned \(deletedCount) orphaned nodes after profile disable.")
            
            // Clear pending writes for remaining configs so SyncEngine can rebuild diffs cleanly
            for config in remainingConfigs {
                WriteQueue.shared.removePendingWrites(for: config.bookmarkFilePath)
            }
        }
    }
    
    func recordSyncTime(for configId: String) {
        lastSyncTimes[configId] = Date()
    }
    
    func rescanProfiles() {
        guard let context = modelContext else { return }
        let discovered = BrowserDiscoverer.discover()
        self.isFullDiskAccessGranted = BrowserDiscoverer.isSafariAccessGranted
        
        let existing = (try? context.fetch(FetchDescriptor<BrowserConfig>())) ?? []
        let existingIds = Set(existing.map { $0.id })
        let discoveredIds = Set(discovered.map { "\($0.bundleId):\($0.profileName)" })
        
        // Remove configs that no longer exist on disk
        for config in existing {
            if !discoveredIds.contains(config.id) {
                if config.isEnabled {
                    config.isEnabled = false
                    WriteQueue.shared.removePendingWrites(for: config.bookmarkFilePath)
                    removeDiffs(for: config.bundleId, profileName: config.profileName)
                    if let setId = config.profileSetId {
                        cleanOrphanedNodes(for: setId)
                    }
                }
                context.delete(config)
            }
        }
        
        for p in discovered {
            let id = "\(p.bundleId):\(p.profileName)"
            if !existingIds.contains(id) {
                let config = BrowserConfig(
                    id: id,
                    bundleId: p.bundleId,
                    browserName: p.browserName,
                    profileName: p.profileName,
                    bookmarkFilePath: p.bookmarkFilePath,
                    isEnabled: false // Default to off for safety
                )
                context.insert(config)
            }
        }
        try? context.save()
    }
    
    enum NodeSyncStatus: String {
        case synced = "Synced"
        case mismatch = "Mismatch"
        case writePending = "Write Pending"
        case disabled = "Disabled"
        case unknown = "Unknown"
    }
    
    func syncStatus(for nodeId: String, config: BrowserConfig) -> NodeSyncStatus {
        guard config.isEnabled else {
            return .disabled
        }
        
        if WriteQueue.shared.isWritePending(for: config.bundleId) {
            return .writePending
        }
        
        guard let context = modelContext else {
            return .unknown
        }
        
        // Reconstruct the real database ID with this config's profileSetId prefix
        let targetProfileSetId = config.profileSetId ?? ""
        let stripped = stripProfileSetPrefix(nodeId)
        let dbId = targetProfileSetId.isEmpty ? stripped : "\(targetProfileSetId):\(stripped)"
        
        let descriptor = FetchDescriptor<BookmarkNode>(predicate: #Predicate { $0.id == dbId })
        guard let groundTruthNode = (try? context.fetch(descriptor))?.first else {
            return .unknown
        }
        
        guard let browserMap = latestBrowserNodes[config.id],
              let browserNode = browserMap[dbId] else {
            return .mismatch
        }
        
        let titlesMatch = groundTruthNode.title == browserNode.title
        
        let urlsMatch: Bool
        if groundTruthNode.type == .leaf {
            urlsMatch = normalizeURL(groundTruthNode.url ?? "") == normalizeURL(browserNode.url ?? "")
        } else {
            urlsMatch = true
        }
        
        let typesMatch = groundTruthNode.type == browserNode.type
        
        if titlesMatch && urlsMatch && typesMatch {
            return .synced
        } else {
            return .mismatch
        }
    }
}
