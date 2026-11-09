import XCTest
@testable import BookmarkSync

/// Folders kept at the top level of Safari's bookmarks belong to the default
/// profile, and Chromium's mobile bookmarks go into a top-level folder of
/// their own.
final class SafariRootFolderTests: XCTestCase {
    private var url: URL!

    override func setUpWithError() throws {
        url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("SafariRoot_\(UUID().uuidString).plist")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: url)
    }

    private func leaf(_ title: String, _ link: String) -> [String: Any] {
        ["Title": title, "WebBookmarkType": "WebBookmarkTypeLeaf", "URLString": link,
         "WebBookmarkUUID": UUID().uuidString, "URIDictionary": ["title": title]]
    }

    private func list(_ title: String, _ children: [[String: Any]], extra: [String: Any] = [:]) -> [String: Any] {
        var dict: [String: Any] = ["Title": title, "WebBookmarkType": "WebBookmarkTypeList",
                                   "WebBookmarkUUID": UUID().uuidString, "Children": children]
        dict.merge(extra) { $1 }
        return dict
    }

    private func writeFixture(_ rootChildren: [[String: Any]]) throws {
        let root: [String: Any] = ["Children": rootChildren, "Title": "", "WebBookmarkFileVersion": 1,
                                   "WebBookmarkType": "WebBookmarkTypeList", "WebBookmarkUUID": "ROOT"]
        try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0).write(to: url)
    }

    private func rootChildren() throws -> [[String: Any]] {
        let plist = try PropertyListSerialization.propertyList(from: try Data(contentsOf: url), options: [], format: nil) as! [String: Any]
        return plist["Children"] as! [[String: Any]]
    }

    private func titles(_ entries: [[String: Any]]) -> [String] {
        entries.compactMap { $0["Title"] as? String }
    }

    private func children(of title: String) throws -> [[String: Any]] {
        try rootChildren().first { ($0["Title"] as? String) == title }?["Children"] as? [[String: Any]] ?? []
    }

    /// The layout of a real Bookmarks.plist (2026-10): Safari's fixed entries
    /// followed by folders the user created at the top level.
    private func realisticFixture() throws {
        try writeFixture([
            ["Title": "History", "WebBookmarkType": "WebBookmarkTypeProxy", "WebBookmarkUUID": UUID().uuidString, "WebBookmarkIdentifier": "History"],
            list("BookmarksBar", [leaf("A", "https://a.com/")]),
            list("BookmarksMenu", [leaf("M", "https://m.com/")]),
            list("com.apple.ReadingList", [leaf("R", "https://r.com/")], extra: ["ShouldOmitFromUI": true]),
            list("Top", [leaf("T", "https://t.com/")]),
            list("Empty", []),
        ])
    }

    private var parser: SafariParser { SafariParser(filePath: url) }

    func testTopLevelFoldersAreReadAsOther() throws {
        try realisticFixture()
        XCTAssertEqual(Set(try parser.read().map(\.id)), [
            "bookmark_bar:a.com", "other:m.com", "other:Top", "other:Top:t.com", "other:Empty",
        ])
    }

    func testRewritingKeepsTopLevelFoldersInPlace() throws {
        try realisticFixture()
        let before = try parser.read()
        try parser.write(nodes: before)

        XCTAssertEqual(titles(try rootChildren()),
                       ["History", "BookmarksBar", "BookmarksMenu", "com.apple.ReadingList", "Top", "Empty"])
        XCTAssertEqual(titles(try children(of: "BookmarksMenu")), ["M"])
        XCTAssertEqual(Set(try parser.read().map(\.id)), Set(before.map(\.id)))
    }

    func testDeletingATopLevelFolderMovesItToTheDeletedFolder() throws {
        try realisticFixture()
        try parser.write(nodes: try parser.read().filter { !$0.id.hasPrefix("other:Top") })

        XCTAssertFalse(titles(try rootChildren()).contains("Top"))
        let deleted = try children(of: "BookmarksMenu").first { ($0["Title"] as? String) == "Deleted by BookmarkSync" }
        XCTAssertEqual(titles(deleted?["Children"] as? [[String: Any]] ?? []), ["Top"])
        XCTAssertFalse(Set(try parser.read().map(\.id)).contains("other:Top"))
    }

    func testNewOtherBookmarksGoToTheMenu() throws {
        try realisticFixture()
        var nodes = try parser.read()
        nodes.append(ParsedBookmark(id: "other:n.com", title: "N", url: "https://n.com/", type: .leaf, mtime: Date(), index: 9))
        try parser.write(nodes: nodes)

        XCTAssertEqual(titles(try children(of: "BookmarksMenu")), ["M", "N"])
        XCTAssertEqual(titles(try rootChildren()).filter { $0 == "Top" }, ["Top"])
    }

    func testMobileBookmarksGetATopLevelFolder() throws {
        try realisticFixture()
        var nodes = try parser.read()
        nodes.append(ParsedBookmark(id: "synced:p.com", title: "P", url: "https://p.com/", type: .leaf, mtime: Date(), index: 0))
        try parser.write(nodes: nodes)

        let mobile = try rootChildren().filter(SafariParser.isMobileFolder)
        XCTAssertEqual(mobile.count, 1)
        XCTAssertEqual(mobile.first?["Title"] as? String, "Mobile Bookmarks")
        XCTAssertEqual(titles(mobile.first?["Children"] as? [[String: Any]] ?? []), ["P"])
        XCTAssertTrue(Set(try parser.read().map(\.id)).contains("synced:p.com"))

        // Removing it again leaves the folder, empties it, and keeps a tombstone.
        try parser.write(nodes: try parser.read().filter { !$0.id.hasPrefix("synced:") })
        XCTAssertEqual(try rootChildren().filter(SafariParser.isMobileFolder).count, 1)
        XCTAssertFalse(Set(try parser.read().map(\.id)).contains("synced:p.com"))
    }

    func testAnExistingMobileFolderIsReusedUnderEitherName() throws {
        try writeFixture([
            list("BookmarksBar", []),
            list("BookmarksMenu", []),
            list("Mobile Bookmarks", [leaf("P", "https://p.com/")]),
        ])
        XCTAssertEqual(try parser.read().map(\.id), ["synced:p.com"])

        var nodes = try parser.read()
        nodes.append(ParsedBookmark(id: "synced:q.com", title: "Q", url: "https://q.com/", type: .leaf, mtime: Date(), index: 1))
        try parser.write(nodes: nodes)
        XCTAssertEqual(titles(try rootChildren()), ["BookmarksBar", "BookmarksMenu", "Mobile Bookmarks"])
        XCTAssertEqual(titles(try children(of: "Mobile Bookmarks")), ["P", "Q"])
    }

    func testALegacyChineseMobileFolderIsReused() throws {
        try writeFixture([
            list("BookmarksBar", []),
            list("BookmarksMenu", []),
            list("移动设备书签", [leaf("P", "https://p.com/")]),
        ])
        var nodes = try parser.read()
        nodes.append(ParsedBookmark(id: "synced:q.com", title: "Q", url: "https://q.com/", type: .leaf, mtime: Date(), index: 1))
        try parser.write(nodes: nodes)
        XCTAssertEqual(titles(try rootChildren()), ["BookmarksBar", "BookmarksMenu", "移动设备书签"])
        XCTAssertEqual(titles(try children(of: "移动设备书签")), ["P", "Q"])
    }

    func testNoMobileFolderIsCreatedWithoutMobileBookmarks() throws {
        try realisticFixture()
        try parser.write(nodes: try parser.read())
        XCTAssertTrue(try rootChildren().filter(SafariParser.isMobileFolder).isEmpty)
    }

    func testOnlyTheUsersOwnTopLevelEntriesCount() {
        XCTAssertFalse(SafariParser.isUserRootEntry(["Title": "History", "WebBookmarkType": "WebBookmarkTypeProxy"]))
        XCTAssertFalse(SafariParser.isUserRootEntry(list("com.apple.ReadingList", [], extra: ["ShouldOmitFromUI": true])))
        XCTAssertFalse(SafariParser.isUserRootEntry(list("BookmarksBar", [])))
        XCTAssertFalse(SafariParser.isUserRootEntry(list("移动设备书签", [])))
        XCTAssertFalse(SafariParser.isUserRootEntry(list("Deleted by BookmarkSync", [])))
        XCTAssertTrue(SafariParser.isUserRootEntry(list("Untitled Folder", [])))
        XCTAssertTrue(SafariParser.isUserRootEntry(leaf("Loose", "https://loose.com/")))
    }
}
