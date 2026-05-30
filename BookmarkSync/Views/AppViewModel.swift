import SwiftUI
import SwiftData



@MainActor
class AppViewModel: ObservableObject {
    @Published var syncStatus: String = "Idle"
    @Published var diffHistory: [DiffRecord] = []
    @Published var lastSyncTimes: [String: Date] = [:]
    @Published var isFullDiskAccessGranted: Bool = true
    @Published var isWatchingEnabled: Bool = true
    @Published var isWritingEnabled: Bool = true
    @Published var latestBrowserNodes: [String: [String: BookmarkNode]] = [:]

    @Published var profileSets: [ProfileSet] = []
    @Published var selectedProfileSetId: String?
    @Published var isActivityFilterGlobal: Bool = true
    @Published var queueError: String?

    var tombstonedIds: [String] {
        get { UserDefaults.standard.stringArray(forKey: "tombstonedIds") ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: "tombstonedIds") }
    }

    func addTombstone(_ id: String) {
        var current = tombstonedIds
        if !current.contains(id) {
            current.append(id)
            tombstonedIds = current
        }
    }

    func isTombstoned(_ id: String) -> Bool {
        return tombstonedIds.contains(id)
    }

    @Published var syncState: SyncState = .readOnly {
        didSet {
            UserDefaults.standard.set(syncState.rawValue, forKey: "syncState")
            isWatchingEnabled = syncState != .stopped
            isWritingEnabled = syncState == .active

            if syncState == .active {
                syncEngine?.triggerSync(changedPaths: [], forceImmediate: true)
            }
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
        WriteQueue.shared.viewModel = self
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
