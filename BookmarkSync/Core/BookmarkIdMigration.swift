import Foundation
import SwiftData

/// Re-keys stored bookmark ids when `normalizeURL` changes.
///
/// A bookmark's id is `<location>:<normalizeURL(url)>` (plus `:dupN` for
/// repeats in one folder). The hub and every profile's observed state store
/// those ids, so changing the normalization without migrating them would make
/// the next sync see every bookmark as deleted and re-added.
///
/// Version 1 lowercased paths and queries and dropped ports; version 2 keeps
/// both. Version 2 only ever tells URLs apart that version 1 merged, never the
/// reverse, so each new group of equal ids is a subset of an old one and keeps
/// its members' old `:dupN` order -- which is the order the parsers meet them in.
enum BookmarkIdMigration {
    static let currentVersion = 2
    static let defaultsKey = "bookmarkIdSchemeVersion"
    /// Temporary prefix while ids are being swapped; see `migrateIfNeeded`.
    static let pendingPrefix = "migrating:"

    struct Item {
        let id: String
        let url: String?
        let parentId: String?
        let type: BookmarkType
    }

    /// Old id -> new id, for every bookmark whose id changes. Folders and
    /// bookmarks without a URL keep their ids.
    static func remap(_ items: [Item]) -> [String: String] {
        var groups: [String: [(id: String, dup: Int)]] = [:]
        for item in items where item.type == .leaf {
            guard let url = item.url else { continue }
            let base = location(of: item) + ":" + normalizeURL(url)
            groups[base, default: []].append((item.id, dupNumber(item.id)))
        }

        var map: [String: String] = [:]
        for (base, members) in groups {
            let ordered = members.sorted { ($0.dup, $0.id) < ($1.dup, $1.id) }
            for (rank, member) in ordered.enumerated() {
                let newId = rank == 0 ? base : "\(base):dup\(rank)"
                if newId != member.id {
                    map[member.id] = newId
                }
            }
        }
        return map
    }

    /// The id prefix a bookmark's own id is built on: its folder's id, or for a
    /// top-level bookmark the (profile-set prefixed) root name.
    static func location(of item: Item) -> String {
        if let parent = item.parentId, !parent.isEmpty {
            return parent
        }
        let stripped = stripProfileSetPrefix(item.id)
        let setPrefix = String(item.id.dropLast(stripped.count))
        let root = stripped.split(separator: ":", maxSplits: 1).first.map(String.init) ?? ""
        return setPrefix + root
    }

    /// The `N` of a trailing `:dupN`, or 0.
    static func dupNumber(_ id: String) -> Int {
        guard let range = id.range(of: #":dup(\d+)$"#, options: .regularExpression) else { return 0 }
        return Int(id[range].dropFirst(4)) ?? 0
    }

    /// Migrates the hub and every profile's observed state to the current id
    /// scheme, once. Throws (and leaves the version unrecorded, so the next
    /// sync retries) if the store cannot be saved; the caller must not sync
    /// with partly migrated ids.
    @MainActor
    static func migrateIfNeeded(context: ModelContext, viewModel: AppViewModel, defaults: UserDefaults = .standard) throws {
        guard defaults.integer(forKey: defaultsKey) < currentVersion else { return }

        let nodes = try context.fetch(FetchDescriptor<BookmarkNode>())

        // Finish a swap an earlier attempt could not save.
        for node in nodes where node.id.hasPrefix(pendingPrefix) {
            node.id = String(node.id.dropFirst(pendingPrefix.count))
        }

        let hubMap = remap(nodes.map { Item(id: $0.id, url: $0.url, parentId: $0.parentId, type: $0.type) })
        let moving = nodes.compactMap { node in hubMap[node.id].map { (node, $0) } }

        if !moving.isEmpty {
            // Two saves, so no intermediate state ever has two nodes with one id
            // (the store enforces uniqueness row by row).
            for (node, newId) in moving {
                node.id = pendingPrefix + newId
            }
            try context.save()
            for (node, newId) in moving {
                node.id = newId
            }
        }

        let configs = try context.fetch(FetchDescriptor<BrowserConfig>())
        for config in configs {
            guard let data = config.observedStateData,
                  let records = try? JSONDecoder().decode([String: BookmarkNodeRecord].self, from: data) else { continue }
            let map = remap(records.values.map { Item(id: $0.id, url: $0.url, parentId: $0.parentId, type: $0.type) })
            guard !map.isEmpty else { continue }

            var migrated: [String: BookmarkNodeRecord] = [:]
            for (id, record) in records {
                var updated = record
                updated.id = map[id] ?? id
                migrated[updated.id] = updated
            }
            config.observedStateData = try JSONEncoder().encode(migrated)
        }

        try context.save()

        // Everything cached in memory still uses the old ids.
        viewModel.latestBrowserNodes = [:]
        viewModel.deletionHolds = [:]
        viewModel.approvedDeletions = [:]
        viewModel.rejectedDeletionHolds = []

        defaults.set(currentVersion, forKey: defaultsKey)
        SyncLog.event("[Migrate] Bookmark ids updated to scheme v\(currentVersion): \(moving.count) hub node(s)")
    }
}
