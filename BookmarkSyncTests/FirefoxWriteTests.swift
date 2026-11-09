import XCTest
import SQLite3
@testable import BookmarkSync

/// The Firefox writer must change only what differs (plan items S3, S4).
final class FirefoxIncrementalWriteTests: XCTestCase {
    private var dir: URL!
    private var places: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("FirefoxWrite_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        places = dir.appendingPathComponent("places.sqlite")
        try exec("""
        CREATE TABLE moz_places (id INTEGER PRIMARY KEY, url TEXT, title TEXT, rev_host TEXT, guid TEXT,
            hidden INTEGER DEFAULT 0, frecency INTEGER DEFAULT -1, url_hash INTEGER DEFAULT 0, foreign_count INTEGER DEFAULT 0);
        CREATE TABLE moz_bookmarks (id INTEGER PRIMARY KEY, type INTEGER, fk INTEGER, parent INTEGER, position INTEGER,
            title TEXT, dateAdded INTEGER, lastModified INTEGER, guid TEXT, syncStatus INTEGER DEFAULT 0, syncChangeCounter INTEGER DEFAULT 1);
        CREATE TABLE moz_bookmarks_deleted (guid TEXT PRIMARY KEY, dateRemoved INTEGER);
        INSERT INTO moz_places (id, url, title, foreign_count) VALUES
            (1, 'https://a.com/', 'A', 2), (2, 'https://b.com/', 'B', 1), (3, 'https://c.com/', 'C', 1),
            (4, 'https://m.com/', 'M', 1), (5, 'https://u.com/', 'U', 1);
        INSERT INTO moz_bookmarks (id, type, fk, parent, position, title, dateAdded, lastModified, guid, syncStatus, syncChangeCounter) VALUES
            (1, 2, NULL, 0, 0, '', 0, 0, 'root________', 2, 0),
            (2, 2, NULL, 1, 0, 'menu', 0, 0, 'menu________', 2, 0),
            (3, 2, NULL, 1, 1, 'toolbar', 0, 0, 'toolbar_____', 2, 0),
            (4, 2, NULL, 1, 2, 'tags', 0, 0, 'tags________', 2, 0),
            (5, 2, NULL, 1, 3, 'unfiled', 0, 0, 'unfiled_____', 2, 0),
            (10, 1, 1, 3, 0, 'A', 0, 0, 'guidA0000000', 2, 0),
            (11, 3, NULL, 3, 1, NULL, 0, 0, 'guidSep00000', 2, 0),
            (12, 1, 2, 3, 2, 'B', 0, 0, 'guidB0000000', 2, 0),
            (13, 2, NULL, 3, 3, 'F', 0, 0, 'guidF0000000', 2, 0),
            (14, 1, 3, 13, 0, 'C', 0, 0, 'guidC0000000', 2, 0),
            (20, 1, 4, 2, 0, 'M', 0, 0, 'guidM0000000', 2, 0),
            (30, 1, 5, 5, 0, 'U', 0, 0, 'guidU0000000', 2, 0),
            (40, 2, NULL, 4, 0, 'tag', 0, 0, 'guidTag00000', 2, 0),
            (41, 1, 1, 40, 0, NULL, 0, 0, 'guidTagE0000', 2, 0);
        """)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: SQLite helpers

    private func exec(_ sql: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(places.path, &db) == SQLITE_OK else { throw NSError(domain: "fixture", code: 1) }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "fixture", code: 2, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
        }
    }

    private func query(_ sql: String) throws -> [[String?]] {
        var db: OpaquePointer?
        guard sqlite3_open(places.path, &db) == SQLITE_OK else { throw NSError(domain: "fixture", code: 1) }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw NSError(domain: "fixture", code: 3, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
        }
        defer { sqlite3_finalize(stmt) }
        var rows: [[String?]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            var row: [String?] = []
            for i in 0..<sqlite3_column_count(stmt) {
                row.append(sqlite3_column_text(stmt, i).map { String(cString: $0) })
            }
            rows.append(row)
        }
        return rows
    }

    private func snapshot() throws -> [[String?]] {
        try query("SELECT id, type, fk, parent, position, title, guid, syncStatus, syncChangeCounter, lastModified FROM moz_bookmarks ORDER BY id")
            + query("SELECT id, url, foreign_count FROM moz_places ORDER BY id")
    }

    private var parser: FirefoxParser { FirefoxParser(filePath: places) }

    // MARK: Tests

    func testReadAssignsTheExpectedIds() throws {
        XCTAssertEqual(Set(try parser.read().map(\.id)), [
            "bookmark_bar:a.com", "bookmark_bar:b.com", "bookmark_bar:F", "bookmark_bar:F:c.com",
            "other:m.com", "other:u.com",
        ])
    }

    func testWritingAnUnchangedTreeChangesNothing() throws {
        let before = try snapshot()
        try parser.write(nodes: try parser.read())
        XCTAssertEqual(try snapshot(), before, "No row, GUID, position or sync counter may change")
    }

    func testChangesAreAppliedInPlace() throws {
        var nodes = try parser.read()
        nodes = nodes.filter { $0.id != "bookmark_bar:b.com" }.map { node in
            guard node.id == "bookmark_bar:a.com" else { return node }
            return ParsedBookmark(id: node.id, title: "A2", url: node.url, type: node.type,
                                  parentId: node.parentId, mtime: node.mtime, index: node.index)
        }
        nodes.append(ParsedBookmark(id: "bookmark_bar:d.com", title: "D", url: "https://d.com/", type: .leaf, mtime: Date(), index: 4))
        nodes.append(ParsedBookmark(id: "other:n.com", title: "N", url: "https://n.com/", type: .leaf, mtime: Date(), index: 5))

        try parser.write(nodes: nodes)

        // Renamed in place: same row, same GUID, change counted for Sync.
        XCTAssertEqual(try query("SELECT title, guid, syncChangeCounter FROM moz_bookmarks WHERE id = 10"),
                       [["A2", "guidA0000000", "1"]])
        // Deleted, with a tombstone for Firefox Sync.
        XCTAssertTrue(try query("SELECT id FROM moz_bookmarks WHERE id = 12").isEmpty)
        XCTAssertEqual(try query("SELECT guid FROM moz_bookmarks_deleted"), [["guidB0000000"]])
        // Toolbar order: the separator keeps its slot; the new bookmark goes last.
        XCTAssertEqual(try query("SELECT id, title, position FROM moz_bookmarks WHERE parent = 3 ORDER BY position").map { $0[1] },
                       ["A2", nil, "F", "D"])
        XCTAssertEqual(try query("SELECT position FROM moz_bookmarks WHERE parent = 3 ORDER BY position").map { $0[0] },
                       ["0", "1", "2", "3"])
        // The menu item stays in the menu and is not copied into "Other Bookmarks" (S4).
        XCTAssertEqual(try query("SELECT parent FROM moz_bookmarks WHERE guid = 'guidM0000000'"), [["2"]])
        XCTAssertEqual(try query("SELECT b.title FROM moz_bookmarks b WHERE b.parent = 5 ORDER BY position").map { $0[0] }, ["U", "N"])
        // Tags are never touched.
        XCTAssertEqual(try query("SELECT id FROM moz_bookmarks WHERE id IN (40, 41) ORDER BY id"), [["40"], ["41"]])
        // Reading back gives exactly the target.
        XCTAssertEqual(Set(try parser.read().map(\.id)), Set(nodes.map(\.id)))

        // And writing the same tree again is a no-op.
        let after = try snapshot()
        try parser.write(nodes: nodes)
        XCTAssertEqual(try snapshot(), after)
    }

    func testDeletingAFolderRemovesItsContents() throws {
        let nodes = try parser.read().filter { !$0.id.hasPrefix("bookmark_bar:F") }
        try parser.write(nodes: nodes)
        XCTAssertTrue(try query("SELECT id FROM moz_bookmarks WHERE id IN (13, 14)").isEmpty)
        XCTAssertEqual(Set(try query("SELECT guid FROM moz_bookmarks_deleted").compactMap { $0[0] }),
                       ["guidF0000000", "guidC0000000"])
        XCTAssertEqual(try query("SELECT foreign_count FROM moz_places WHERE id = 3"), [["0"]])
    }
}
