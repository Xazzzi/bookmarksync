import SwiftUI
import SwiftData



@MainActor
class AppViewModel: ObservableObject {
    @Published var syncStatus: String = "Idle"
    @Published var diffHistory: [DiffRecord] = []
    @Published var isFullDiskAccessGranted: Bool = true
    @Published var isWatchingEnabled: Bool = true
    @Published var isWritingEnabled: Bool = true
    @Published var unavailableProfileIds: Set<String> = []
    @Published var latestBrowserNodes: [String: [String: ParsedBookmark]] = [:]

    /// Profiles whose bookmark file could not be read on the last pass.
    @Published var readFailedConfigIds: Set<String> = []
    /// Browsers with writes queued until the user quits them.
    @Published var browsersAwaitingQuit: Set<String> = []

    /// Profiles whose pre-existing empty folders have been added to the hub.
    var migratedEmptyFolderConfigIds: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: EmptyFolderMigration.defaultsKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: EmptyFolderMigration.defaultsKey) }
    }

    /// Profiles whose deletions `DeletionGuard` is holding, by config id.
    @Published var deletionHolds: [String: PendingDeletionHold] = [:]
    /// Deletions the user confirmed, by config id; consumed once applied.
    var approvedDeletions: [String: Set<String>] = [:]
    /// Profiles whose held deletion the user rejected. The next pass keeps the
    /// hub as it is and adopts the profile's current file as observed, so the
    /// export writes the missing bookmarks back.
    var rejectedDeletionHolds: Set<String> = []

    func approveDeletionHold(configId: String) {
        guard let hold = deletionHolds.removeValue(forKey: configId) else { return }
        approvedDeletions[configId] = hold.deletedIds
        rejectedDeletionHolds.remove(configId)
        syncEngine?.triggerSync(changedPaths: [], forceImmediate: true)
    }

    func rejectDeletionHold(configId: String) {
        guard deletionHolds.removeValue(forKey: configId) != nil else { return }
        approvedDeletions[configId] = nil
        rejectedDeletionHolds.insert(configId)
        syncEngine?.triggerSync(changedPaths: [], forceImmediate: true)
    }

    /// Bumped whenever the sync engine commits bookmark changes.
    ///
    /// `@Model` instances compare by identity, so an in-place edit to a node's
    /// title leaves the `@Query` array "equal" and cannot be detected with
    /// `onChange(of:)`. Views observe this counter instead to know when their
    /// cached projections are stale.
    @Published var bookmarkDataRevision: Int = 0

    func noteBookmarkDataChanged() {
        bookmarkDataRevision &+= 1
    }

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



    func rescanProfiles() {
        guard let context = modelContext else { return }
        let discovered = BrowserDiscoverer.discover()
        self.isFullDiskAccessGranted = BrowserDiscoverer.isSafariAccessGranted

        reconcileProfiles(discovered)
    }

    /// Discovery can be incomplete after an app replacement or permission change.
    /// Absence is not evidence that a user deleted a profile or its bookmarks.
    func reconcileProfiles(_ discovered: [DiscoveredProfile]) {
        guard let context = modelContext,
              let existing = try? context.fetch(FetchDescriptor<BrowserConfig>()) else { return }
        var matchedIds = Set<String>()

        for profile in discovered {
            let id = "\(profile.bundleId):\(profile.profileName)"
            // Chromium/Firefox display names can change when Local State or
            // account metadata is temporarily unreadable. Their file path is
            // stable. Safari profiles share a plist, so match those by name.
            let config = existing.first { config in
                !matchedIds.contains(config.id) && config.bundleId == profile.bundleId &&
                (profile.bundleId == "com.apple.Safari"
                    ? config.id == id
                    : config.bookmarkFilePath == profile.bookmarkFilePath)
            } ?? existing.first { !matchedIds.contains($0.id) && $0.id == id }

            if let config {
                matchedIds.insert(config.id)
                config.browserName = profile.browserName
                config.profileName = profile.profileName
                config.bookmarkFilePath = profile.bookmarkFilePath
            } else {
                let config = BrowserConfig(
                    id: id,
                    bundleId: profile.bundleId,
                    browserName: profile.browserName,
                    profileName: profile.profileName,
                    bookmarkFilePath: profile.bookmarkFilePath,
                    isEnabled: false
                )
                context.insert(config)
                matchedIds.insert(id)
            }
        }

        // A profile that is gone and was never synced has nothing to preserve:
        // drop it instead of listing it as unavailable forever (for example a
        // Safari top-level folder that older versions listed as a profile).
        var unavailable = Set(existing.map { $0.id }).subtracting(matchedIds)
        for config in existing where unavailable.contains(config.id) && Self.isUnused(config) {
            unavailable.remove(config.id)
            context.delete(config)
        }
        unavailableProfileIds = unavailable
        for config in existing where unavailableProfileIds.contains(config.id) {
            WriteQueue.shared.removePendingWrites(for: config.bookmarkFilePath)
        }
        try? context.save()
    }

    static func isUnused(_ config: BrowserConfig) -> Bool {
        !config.isEnabled && (config.profileSetId ?? "").isEmpty && config.observedStateData == nil
    }

    /// Forgets a profile that can no longer be found. Only the app's record is
    /// removed; no bookmark file is touched.
    func removeUnavailableProfile(_ config: BrowserConfig) {
        guard let context = modelContext, unavailableProfileIds.contains(config.id) else { return }
        let setId = config.profileSetId
        WriteQueue.shared.removePendingWrites(for: config.bookmarkFilePath)
        removeDiffs(for: config.bundleId, profileName: config.profileName)
        latestBrowserNodes[config.id] = nil
        unavailableProfileIds.remove(config.id)
        context.delete(config)
        try? context.save()
        if let setId, !setId.isEmpty {
            cleanOrphanedNodes(for: setId)
        }
        syncEngine?.triggerSync(changedPaths: [], forceImmediate: true)
    }

    enum NodeSyncStatus: String {
        case synced = "Synced"
        case mismatch = "Mismatch"
        case writePending = "Write Pending"
        case disabled = "Disabled"
        case notSyncedHere = "Not Synced Here"
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

        // A bookmark under a root this browser lacks is never written to it.
        guard BookmarkRoots.supported(bundleId: config.bundleId, profileName: config.profileName)
            .contains(BookmarkRoots.root(of: nodeId)) else {
            return .notSyncedHere
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
