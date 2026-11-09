import Foundation
import SQLite

/// Applies the hub's tree to `places.sqlite` as the smallest set of row
/// changes (plan items S3, S4).
///
/// The previous writer deleted every row under the toolbar and "Other
/// Bookmarks" and re-inserted the tree with new random GUIDs on every write.
/// To Firefox Sync that looked like every bookmark being deleted and a new set
/// created; separators were lost; and items in the bookmarks menu, which are
/// read as part of `other`, were re-inserted into "Other Bookmarks" while the
/// originals stayed in the menu, so they multiplied.
///
/// Here every existing row is matched to its node id the same way `read` does
/// it (`FirefoxParser.assignIds`), and then:
/// - rows whose node is gone are deleted with their subtree, leaving a
///   tombstone for Firefox Sync if the row had been synced;
/// - rows whose node is still there keep their id and GUID and are updated in
///   place, wherever they live (menu items stay in the menu);
/// - new nodes are inserted;
/// - positions are recomputed only in folders that were touched, keeping
///   separators in their slot.
/// Rows outside the toolbar, menu and "Other Bookmarks" (tags, the root,
/// mobile) are never touched. Writing a tree that already matches changes
/// nothing.
final class FirefoxIncrementalWriter {
    private let db: Connection
    private let targets: [ParsedBookmark]
    private let now = Int64(Date().timeIntervalSince1970 * 1_000_000)

    private var bookmarkColumns: Set<String> = []
    private var placeColumns: Set<String> = []
    private var hasTombstoneTable = false

    private var rowById: [Int64: FirefoxBookmarkRow] = [:]
    private var dbIdByNode: [String: Int64] = [:]
    private var nodeByDbId: [Int64: String] = [:]
    private var targetById: [String: ParsedBookmark] = [:]
    /// Parents whose children changed (insert, delete, move) or need ordering.
    private var touchedParents = Set<Int64>()
    /// Parents whose child list or order actually changed, for Sync.
    private var structureChanged = Set<Int64>()

    init(db: Connection, targets: [ParsedBookmark]) {
        self.db = db
        self.targets = targets
    }

    func apply() throws {
        bookmarkColumns = try columns(of: "moz_bookmarks")
        placeColumns = try columns(of: "moz_places")
        hasTombstoneTable = try tableExists("moz_bookmarks_deleted")

        let rows = try FirefoxParser.loadRows(db)
        rowById = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for (row, node) in try FirefoxParser.assignIds(to: rows) {
            dbIdByNode[node.id] = row.id
            nodeByDbId[row.id] = node.id
        }
        targetById = Dictionary(targets.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        try deleteRemovedRows()
        try upsertTargets()
        for parent in touchedParents {
            try reorderChildren(of: parent)
        }
        try markStructureChanged()
    }

    // MARK: Deletions

    private func deleteRemovedRows() throws {
        let doomed = Set(nodeByDbId.compactMap { dbId, nodeId in targetById[nodeId] == nil ? dbId : nil })

        func hasDoomedAncestor(_ id: Int64) -> Bool {
            var visited = Set<Int64>()
            var current = rowById[id]?.parent
            while let parent = current, visited.insert(parent).inserted {
                if doomed.contains(parent) { return true }
                current = rowById[parent]?.parent
            }
            return false
        }

        // Only the topmost removed row of each subtree; its descendants go with
        // it. Decided before anything is deleted, while every parent link exists.
        let topmost = doomed.filter { !hasDoomedAncestor($0) }
        for id in topmost {
            if let parent = rowById[id]?.parent {
                touchedParents.insert(parent)
                structureChanged.insert(parent)
            }
            try deleteSubtree(id)
        }
    }

    private func deleteSubtree(_ id: Int64) throws {
        var children: [Int64] = []
        for r in try db.prepare("SELECT id FROM moz_bookmarks WHERE parent = ?", id) {
            if let child = r[0] as? Int64 { children.append(child) }
        }
        for child in children {
            try deleteSubtree(child)
        }

        let tracksSync = bookmarkColumns.contains("syncStatus")
        let sql = "SELECT fk, guid\(tracksSync ? ", syncStatus" : "") FROM moz_bookmarks WHERE id = ?"
        var fk: Int64?
        var guid: String?
        var syncStatus: Int64?
        for r in try db.prepare(sql, id) {
            fk = r[0] as? Int64
            guid = r[1] as? String
            syncStatus = tracksSync ? r[2] as? Int64 : nil
        }

        try releasePlace(fk)
        // Firefox Sync only needs a tombstone for an item the server has seen
        // (SYNC_STATUS_NORMAL).
        if hasTombstoneTable, let guid, syncStatus == 2 {
            try db.run("INSERT OR REPLACE INTO moz_bookmarks_deleted (guid, dateRemoved) VALUES (?, ?)", guid, now)
        }
        try db.run("DELETE FROM moz_bookmarks WHERE id = ?", id)

        if let nodeId = nodeByDbId.removeValue(forKey: id) {
            dbIdByNode.removeValue(forKey: nodeId)
        }
        rowById.removeValue(forKey: id)
    }

    // MARK: Updates and insertions

    private func depth(of node: ParsedBookmark) -> Int {
        var depth = 0
        var visited = Set<String>()
        var parent = node.parentId
        while let pid = parent, !pid.isEmpty, visited.insert(pid).inserted, let next = targetById[pid] {
            depth += 1
            parent = next.parentId
        }
        return depth
    }

    private func upsertTargets() throws {
        // Parents before children, so every folder exists before its contents.
        let ordered = targets
            .map { (node: $0, depth: depth(of: $0)) }
            .sorted { ($0.depth, $0.node.index, $0.node.id) < ($1.depth, $1.node.index, $1.node.id) }
            .map { $0.node }

        for node in ordered {
            guard let parent = parentRow(for: node) else {
                SyncLog.error("[Firefox] No parent folder for \(node.id); skipping")
                continue
            }
            if let dbId = dbIdByNode[node.id], let row = rowById[dbId] {
                try update(row, to: node, parent: parent)
            } else {
                try insert(node, parent: parent)
            }
            touchedParents.insert(parent)
        }
    }

    /// The `moz_bookmarks` id a node belongs under.
    private func parentRow(for node: ParsedBookmark) -> Int64? {
        if let pid = node.parentId, !pid.isEmpty {
            return dbIdByNode[pid]
        }
        if BookmarkRoots.root(of: node.id) == BookmarkRoots.bar {
            return FirefoxParser.toolbarId
        }
        // Top-level `other`: the menu and "Other Bookmarks" read alike, so an
        // existing item stays where it is and a new one goes to "Other Bookmarks".
        if let dbId = dbIdByNode[node.id], let current = rowById[dbId]?.parent,
           current == FirefoxParser.menuId || current == FirefoxParser.unfiledId {
            return current
        }
        return FirefoxParser.unfiledId
    }

    private func update(_ row: FirefoxBookmarkRow, to node: ParsedBookmark, parent: Int64) throws {
        var changed = false

        if node.title != row.displayTitle {
            try db.run("UPDATE moz_bookmarks SET title = ? WHERE id = ?", node.title, row.id)
            changed = true
        }
        if node.type == .leaf, let url = node.url, url != row.url {
            let fk = try placeId(for: url, title: node.title)
            try db.run("UPDATE moz_bookmarks SET fk = ? WHERE id = ?", fk, row.id)
            try releasePlace(row.fk)
            changed = true
        }
        if parent != row.parent {
            try db.run("UPDATE moz_bookmarks SET parent = ? WHERE id = ?", parent, row.id)
            touchedParents.insert(row.parent)
            structureChanged.insert(row.parent)
            structureChanged.insert(parent)
            changed = true
        }
        if changed {
            try markChanged(row.id)
        }
    }

    private func insert(_ node: ParsedBookmark, parent: Int64) throws {
        var fk: Int64?
        if node.type == .leaf, let url = node.url {
            fk = try placeId(for: url, title: node.title)
        }

        var columns = ["type", "fk", "parent", "position", "title", "dateAdded", "lastModified", "guid"]
        var values: [Binding?] = [
            node.type == .folder ? Int64(2) : Int64(1),
            fk,
            parent,
            Int64(Int32.max),   // placed properly by reorderChildren
            node.title,
            Int64(node.mtime.timeIntervalSince1970 * 1_000_000),
            now,
            Self.newGuid(),
        ]
        if bookmarkColumns.contains("syncStatus") {
            columns.append("syncStatus")
            values.append(Int64(1))      // SYNC_STATUS_NEW
        }
        if bookmarkColumns.contains("syncChangeCounter") {
            columns.append("syncChangeCounter")
            values.append(Int64(1))
        }

        let placeholders = Array(repeating: "?", count: columns.count).joined(separator: ", ")
        try db.run("INSERT INTO moz_bookmarks (\(columns.joined(separator: ", "))) VALUES (\(placeholders))", values)
        let newId = db.lastInsertRowid

        dbIdByNode[node.id] = newId
        nodeByDbId[newId] = node.id
        rowById[newId] = FirefoxBookmarkRow(
            id: newId, type: node.type == .folder ? 2 : 1, fk: fk, parent: parent, position: Int64(Int32.max),
            title: node.title, dateAdded: now, url: node.url, placeTitle: nil
        )
        structureChanged.insert(parent)
    }

    // MARK: Order

    /// Orders a folder's synced children by the hub's index, keeping anything
    /// the engine does not manage (separators) at its previous position.
    private func reorderChildren(of parent: Int64) throws {
        var managed: [(id: Int64, index: Int)] = []
        var unmanaged: [(id: Int64, position: Int64)] = []
        var currentPosition: [Int64: Int64] = [:]

        for r in try db.prepare("SELECT id, position FROM moz_bookmarks WHERE parent = ? ORDER BY position, id", parent) {
            guard let id = r[0] as? Int64 else { continue }
            let position = r[1] as? Int64 ?? 0
            currentPosition[id] = position
            if let nodeId = nodeByDbId[id], let target = targetById[nodeId] {
                managed.append((id, target.index))
            } else {
                unmanaged.append((id, position))
            }
        }

        var order = managed.sorted { ($0.index, $0.id) < ($1.index, $1.id) }.map { $0.id }
        for item in unmanaged.sorted(by: { ($0.position, $0.id) < ($1.position, $1.id) }) {
            order.insert(item.id, at: min(Int(max(item.position, 0)), order.count))
        }

        for (position, id) in order.enumerated() where currentPosition[id] != Int64(position) {
            try db.run("UPDATE moz_bookmarks SET position = ? WHERE id = ?", Int64(position), id)
            if !(currentPosition[id] == Int64(Int32.max)) {
                structureChanged.insert(parent)
            }
        }
    }

    // MARK: Sync bookkeeping

    private func markChanged(_ id: Int64) throws {
        try db.run("UPDATE moz_bookmarks SET lastModified = ? WHERE id = ?", now, id)
        if bookmarkColumns.contains("syncChangeCounter") {
            try db.run("UPDATE moz_bookmarks SET syncChangeCounter = syncChangeCounter + 1 WHERE id = ?", id)
        }
    }

    /// A folder whose children changed is re-uploaded by Firefox Sync with its
    /// new child list, so its change counter is bumped too.
    private func markStructureChanged() throws {
        for parent in structureChanged where rowById[parent] != nil || parent <= FirefoxParser.unfiledId {
            try markChanged(parent)
        }
    }

    // MARK: Places

    private func placeId(for url: String, title: String) throws -> Int64 {
        var existing: Int64?
        for r in try db.prepare("SELECT id FROM moz_places WHERE url = ? LIMIT 1", url) {
            existing = r[0] as? Int64
        }
        if let existing {
            if placeColumns.contains("foreign_count") {
                try db.run("UPDATE moz_places SET foreign_count = foreign_count + 1 WHERE id = ?", existing)
            }
            return existing
        }

        var columns = ["url", "title"]
        var values: [Binding?] = [url, title]
        let optional: [(String, Binding?)] = [
            ("rev_host", String((URL(string: url)?.host ?? "").reversed()) + "."),
            ("guid", Self.newGuid()),
            ("hidden", Int64(0)),
            ("frecency", Int64(-1)),
            ("url_hash", Self.hashURL(url)),
            ("foreign_count", Int64(1)),
        ]
        for (column, value) in optional where placeColumns.contains(column) {
            columns.append(column)
            values.append(value)
        }
        let placeholders = Array(repeating: "?", count: columns.count).joined(separator: ", ")
        try db.run("INSERT INTO moz_places (\(columns.joined(separator: ", "))) VALUES (\(placeholders))", values)
        return db.lastInsertRowid
    }

    private func releasePlace(_ fk: Int64?) throws {
        guard let fk, placeColumns.contains("foreign_count") else { return }
        try db.run("UPDATE moz_places SET foreign_count = MAX(foreign_count - 1, 0) WHERE id = ?", fk)
    }

    // MARK: Helpers

    private func columns(of table: String) throws -> Set<String> {
        var names = Set<String>()
        for r in try db.prepare("PRAGMA table_info(\(table))") {
            if let name = r[1] as? String { names.insert(name) }
        }
        return names
    }

    private func tableExists(_ table: String) throws -> Bool {
        for _ in try db.prepare("SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?", table) {
            return true
        }
        return false
    }

    /// Firefox GUIDs: 12 characters of the URL-safe base64 alphabet.
    static func newGuid() -> String {
        let charset = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        return String((0..<12).map { _ in charset.randomElement()! })
    }

    static func hashURL(_ url: String) -> Int64 {
        var hash: UInt64 = 0
        for char in url.utf16 {
            hash = (hash &<< 5) &+ hash &+ UInt64(char)
        }
        return Int64(bitPattern: hash & 0x0000FFFFFFFFFFFF)
    }
}
