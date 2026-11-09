import Foundation
import SQLite

/// One `moz_bookmarks` row joined with its place.
struct FirefoxBookmarkRow: Equatable {
    let id: Int64
    /// 1 bookmark, 2 folder, 3 separator.
    let type: Int64
    let fk: Int64?
    let parent: Int64
    let position: Int64
    let title: String?
    let dateAdded: Int64
    let url: String?
    let placeTitle: String?

    /// The title a reader shows: the bookmark's own, else its page's.
    var displayTitle: String { title ?? placeTitle ?? "Unknown" }
}

final class FirefoxParser: BrowserParser {
    let filePath: URL

    /// Fixed `moz_bookmarks` ids of the roots Firefox creates.
    static let rootId: Int64 = 1
    static let menuId: Int64 = 2
    static let toolbarId: Int64 = 3
    static let tagsId: Int64 = 4
    static let unfiledId: Int64 = 5

    init(filePath: URL) {
        self.filePath = filePath
    }

    func read() throws -> [ParsedBookmark] {
        let tempDir = FileManager.default.temporaryDirectory
        let tempId = UUID().uuidString
        let tempDbPath = tempDir.appendingPathComponent("\(tempId)_places.sqlite")
        let tempWalPath = tempDir.appendingPathComponent("\(tempId)_places.sqlite-wal")
        let tempShmPath = tempDir.appendingPathComponent("\(tempId)_places.sqlite-shm")

        let originalDbPath = filePath
        let originalWalPath = URL(fileURLWithPath: filePath.path + "-wal")
        let originalShmPath = URL(fileURLWithPath: filePath.path + "-shm")

        defer {
            try? FileManager.default.removeItem(at: tempDbPath)
            try? FileManager.default.removeItem(at: tempWalPath)
            try? FileManager.default.removeItem(at: tempShmPath)
        }

        // The database itself must be copied; a failure here has to surface as
        // a read error, never as an empty bookmark list. The WAL and SHM files
        // legitimately may not exist.
        try FileManager.default.copyItem(at: originalDbPath, to: tempDbPath)
        try? FileManager.default.copyItem(at: originalWalPath, to: tempWalPath)
        try? FileManager.default.copyItem(at: originalShmPath, to: tempShmPath)

        let db = try Connection(tempDbPath.path, readonly: true)
        return try Self.assignIds(to: Self.loadRows(db)).map { $0.node }
    }

    /// Every bookmark row with its place, read with plain SQL so optional
    /// columns never need to exist.
    static func loadRows(_ db: Connection) throws -> [FirefoxBookmarkRow] {
        let sql = """
        SELECT b.id, b.type, b.fk, b.parent, b.position, b.title, b.dateAdded, p.url, p.title
        FROM moz_bookmarks b LEFT JOIN moz_places p ON b.fk = p.id
        """
        var rows: [FirefoxBookmarkRow] = []
        for r in try db.prepare(sql) {
            rows.append(FirefoxBookmarkRow(
                id: r[0] as? Int64 ?? 0,
                type: r[1] as? Int64 ?? 0,
                fk: r[2] as? Int64,
                parent: r[3] as? Int64 ?? 0,
                position: r[4] as? Int64 ?? 0,
                title: r[5] as? String,
                dateAdded: r[6] as? Int64 ?? 0,
                url: r[7] as? String,
                placeTitle: r[8] as? String
            ))
        }
        return rows
    }

    /// Gives each bookmark and folder under the toolbar, the menu and
    /// "Other Bookmarks" the node id the sync engine uses. Shared by `read` and
    /// the incremental writer so the two can never disagree about identity.
    ///
    /// The menu is read as part of `other` (its top-level items have no
    /// parent id), so an id alone does not say which of the two Firefox roots
    /// an item lives in; the writer keeps it where it is.
    static func assignIds(to rows: [FirefoxBookmarkRow]) throws -> [(row: FirefoxBookmarkRow, node: ParsedBookmark)] {
        let sortedRows = rows.sorted { ($0.parent, $0.position, $0.id) < ($1.parent, $1.position, $1.id) }

        var idToTitle: [Int64: String] = [:]
        var idToParent: [Int64: Int64] = [:]
        for row in sortedRows {
            idToTitle[row.id] = row.displayTitle
            idToParent[row.id] = row.parent
        }

        // Without the toolbar (3) and unfiled (5) roots this is not a profile we
        // understand, and reading it as "no bookmarks" would delete everything.
        guard idToTitle[toolbarId] != nil, idToTitle[unfiledId] != nil else {
            throw BookmarkParseError.unexpectedStructure("Firefox places.sqlite is missing the toolbar or unfiled root")
        }

        var idToPath: [Int64: String] = [toolbarId: "bookmark_bar", unfiledId: "other"]
        var seenKeys: [String: Int] = [:]

        func getPath(for id: Int64) -> String {
            if let path = idToPath[id] { return path }
            if [rootId, menuId, tagsId].contains(id) { return "other" }

            let parent = idToParent[id] ?? unfiledId
            let title = idToTitle[id] ?? "Unknown"

            let baseId = "\(getPath(for: parent)):\(title)"
            let count = seenKeys[baseId, default: 0]
            seenKeys[baseId] = count + 1
            let path = count == 0 ? baseId : "\(baseId):dup\(count)"

            idToPath[id] = path
            return path
        }

        func isInvalid(id: Int64) -> Bool {
            if [rootId, tagsId].contains(id) { return true }
            if let p = idToParent[id] {
                if [rootId, tagsId].contains(p) { return true }
                if p > unfiledId { return isInvalid(id: p) }
            }
            return false
        }

        // Pre-warm paths to ensure deterministic dup counters for folders
        for row in sortedRows where row.type == 2 && !isInvalid(id: row.id) {
            _ = getPath(for: row.id)
        }

        var result: [(row: FirefoxBookmarkRow, node: ParsedBookmark)] = []
        for row in sortedRows {
            if row.id <= unfiledId { continue }   // the fixed roots
            if row.type == 3 { continue }         // separators
            if isInvalid(id: row.id) { continue } // tags and the places root

            let title = row.displayTitle
            let uniqueId: String
            if row.type == 2 {
                uniqueId = getPath(for: row.id)
            } else {
                let normalized = row.url.map(normalizeURL) ?? title
                let baseId = "\(getPath(for: row.parent)):\(normalized)"
                let count = seenKeys[baseId, default: 0]
                seenKeys[baseId] = count + 1
                uniqueId = count == 0 ? baseId : "\(baseId):dup\(count)"
            }

            let node = ParsedBookmark(
                id: uniqueId,
                title: title,
                url: row.url,
                type: row.type == 2 ? .folder : .leaf,
                parentId: row.parent > unfiledId ? getPath(for: row.parent) : nil,
                mtime: Date(timeIntervalSince1970: Double(row.dateAdded) / 1_000_000),
                index: Int(row.position)
            )
            result.append((row, node))
        }
        return result
    }

    func write(nodes: [ParsedBookmark]) throws {
        try performBackup()

        // Only the roots Firefox has here; anything else has nowhere to go.
        let supported = BookmarkRoots.supported(bundleId: "org.mozilla.firefox", profileName: "")
        let targets = nodes.map { node in
            ParsedBookmark(
                id: stripProfileSetPrefix(node.id),
                title: node.title,
                url: node.url,
                type: node.type,
                parentId: node.parentId.map { stripProfileSetPrefix($0) },
                mtime: node.mtime,
                index: node.index
            )
        }.filter { supported.contains(BookmarkRoots.root(of: $0.id)) }

        let db = try Connection(filePath.path, readonly: false)
        try db.execute("PRAGMA journal_mode=WAL;")
        try db.transaction {
            try FirefoxIncrementalWriter(db: db, targets: targets).apply()
        }
    }
}
