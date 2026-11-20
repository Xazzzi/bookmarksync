import XCTest
@testable import BookmarkSync

/// Safari writes keep each entry's iCloud `Sync` state unless the entry was
/// renamed, moved or reordered, and happen under Safari's own lock.
final class SafariSyncMetadataTests: XCTestCase {
    private var dir: URL!
    private var url: URL { dir.appendingPathComponent("Bookmarks.plist") }
    private var lockDir: URL { dir.appendingPathComponent("lock") }
    private var parser: SafariParser { SafariParser(filePath: url) }

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("SafariSync_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func sync(_ id: String) -> [String: Any] {
        ["ServerID": "S-\(id)", "Data": Data(id.utf8)]
    }

    /// Shaped like Safari's own leaves: the title lives in URIDictionary only.
    private func leaf(_ title: String, _ link: String, uuid: String) -> [String: Any] {
        ["WebBookmarkType": "WebBookmarkTypeLeaf", "URLString": link, "WebBookmarkUUID": uuid,
         "URIDictionary": ["title": title], "Sync": sync(uuid), "ReadingListNonSync": ["neverFetchMetadata": false]]
    }

    private func list(_ title: String, uuid: String, _ children: [[String: Any]]) -> [String: Any] {
        ["Title": title, "WebBookmarkType": "WebBookmarkTypeList", "WebBookmarkUUID": uuid,
         "Children": children, "Sync": sync(uuid)]
    }

    private func writeFixture(bar: [[String: Any]]) throws {
        let root: [String: Any] = [
            "Children": [list("BookmarksBar", uuid: "BAR", bar), list("BookmarksMenu", uuid: "MENU", [])],
            "Title": "", "WebBookmarkFileVersion": 1, "WebBookmarkType": "WebBookmarkTypeList",
            "WebBookmarkUUID": "ROOT", "Sync": ["CloudKitMigrationState": 3],
        ]
        try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0).write(to: url)
    }

    private func standardFixture() throws {
        try writeFixture(bar: [
            leaf("A", "https://a.com/", uuid: "A"),
            leaf("B", "https://b.com/", uuid: "B"),
            leaf("C", "https://c.com/", uuid: "C"),
            list("F", uuid: "F", [leaf("D", "https://d.com/", uuid: "D")]),
        ])
    }

    /// Every entry on disk by UUID, depth first.
    private func entries() throws -> [String: [String: Any]] {
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), options: [], format: nil) as! [String: Any]
        var result: [String: [String: Any]] = [:]
        func walk(_ nodes: [[String: Any]]) {
            for node in nodes {
                if let uuid = node["WebBookmarkUUID"] as? String {
                    XCTAssertNil(result[uuid], "duplicate UUID \(uuid)")
                    result[uuid] = node
                }
                walk(node["Children"] as? [[String: Any]] ?? [])
            }
        }
        walk(plist["Children"] as? [[String: Any]] ?? [])
        return result
    }

    private func syncData(_ entry: [String: Any]?) -> Data? {
        (entry?["Sync"] as? [String: Any])?["Data"] as? Data
    }

    private func serverID(_ entry: [String: Any]?) -> String? {
        (entry?["Sync"] as? [String: Any])?["ServerID"] as? String
    }

    private func edited(_ nodes: [ParsedBookmark], _ id: String, title: String? = nil, parentId: String?? = nil,
                        newId: String? = nil, index: Int? = nil) -> [ParsedBookmark] {
        nodes.map { node in
            guard node.id == id else { return node }
            return ParsedBookmark(id: newId ?? node.id, title: title ?? node.title, url: node.url, type: node.type,
                                  parentId: parentId ?? node.parentId, mtime: node.mtime, index: index ?? node.index)
        }
    }

    func testUnchangedWriteKeepsEverySyncEntryAndExtraKey() throws {
        try standardFixture()
        try parser.write(nodes: try parser.read())

        let after = try entries()
        for uuid in ["A", "B", "C", "F", "D"] {
            XCTAssertEqual(syncData(after[uuid]), Data(uuid.utf8), uuid)
            XCTAssertEqual(serverID(after[uuid]), "S-\(uuid)", uuid)
        }
        XCTAssertNotNil(after["A"]?["ReadingListNonSync"])
        XCTAssertNil(after["A"]?["Title"], "leaves keep Safari's shape")
    }

    func testRenameResetsOnlyThatEntry() throws {
        try standardFixture()
        try parser.write(nodes: edited(try parser.read(), "bookmark_bar:b.com", title: "B2"))

        let after = try entries()
        XCTAssertEqual((after["B"]?["URIDictionary"] as? [String: Any])?["title"] as? String, "B2")
        XCTAssertNil(syncData(after["B"]))
        XCTAssertEqual(serverID(after["B"]), "S-B")
        XCTAssertEqual(syncData(after["A"]), Data("A".utf8))
        XCTAssertEqual(syncData(after["C"]), Data("C".utf8))
    }

    func testReorderResetsOnlyTheMovedSibling() throws {
        try standardFixture()
        var nodes = try parser.read()
        // Move A from first to after C: B, C, A, F.
        nodes = edited(nodes, "bookmark_bar:a.com", index: 2)
        nodes = edited(nodes, "bookmark_bar:b.com", index: 0)
        nodes = edited(nodes, "bookmark_bar:c.com", index: 1)
        try parser.write(nodes: nodes)

        let after = try entries()
        XCTAssertNil(syncData(after["A"]))
        XCTAssertEqual(serverID(after["A"]), "S-A")
        for uuid in ["B", "C", "F", "D"] {
            XCTAssertEqual(syncData(after[uuid]), Data(uuid.utf8), uuid)
        }
        XCTAssertEqual(try parser.read().filter { $0.parentId == nil }.map(\.title), ["B", "C", "A", "F"])
    }

    func testMoveIntoFolderKeepsUUIDAndServerID() throws {
        try standardFixture()
        let nodes = edited(try parser.read(), "bookmark_bar:c.com", parentId: .some("bookmark_bar:F"),
                           newId: "bookmark_bar:F:c.com", index: 1)
        try parser.write(nodes: nodes)

        let after = try entries()
        XCTAssertEqual(serverID(after["C"]), "S-C")
        XCTAssertNil(syncData(after["C"]))
        XCTAssertEqual(syncData(after["D"]), Data("D".utf8))
        XCTAssertNil(try entries().values.first { ($0["Title"] as? String) == SafariParser.deletedFolderTitle })
    }

    func testNewBookmarkGetsNoSyncAndLeavesOthersAlone() throws {
        try standardFixture()
        let nodes = try parser.read() + [ParsedBookmark(id: "bookmark_bar:e.com", title: "E", url: "https://e.com/",
                                                        type: .leaf, parentId: nil, mtime: Date(), index: 4)]
        try parser.write(nodes: nodes)

        let after = try entries()
        let added = try XCTUnwrap(after.values.first { $0["URLString"] as? String == "https://e.com/" })
        XCTAssertNil(added["Sync"])
        for uuid in ["A", "B", "C", "F", "D"] {
            XCTAssertEqual(syncData(after[uuid]), Data(uuid.utf8), uuid)
        }
    }

    func testSameURLInTwoPlacesKeepsDistinctEntries() throws {
        try writeFixture(bar: [
            leaf("Top", "https://dup.com/", uuid: "TOP"),
            list("F", uuid: "F", [leaf("Inner", "https://dup.com/", uuid: "INNER")]),
        ])
        // A third copy elsewhere must get a new entry, not one of the existing two.
        let nodes = try parser.read() + [ParsedBookmark(id: "bookmark_bar:G", title: "G", url: nil, type: .folder,
                                                        parentId: nil, mtime: Date(), index: 2),
                                         ParsedBookmark(id: "bookmark_bar:G:dup.com", title: "Third", url: "https://dup.com/",
                                                        type: .leaf, parentId: "bookmark_bar:G", mtime: Date(), index: 0)]
        try parser.write(nodes: nodes)

        let after = try entries()
        XCTAssertEqual(syncData(after["TOP"]), Data("TOP".utf8))
        XCTAssertEqual(syncData(after["INNER"]), Data("INNER".utf8))
        XCTAssertEqual(after.values.filter { $0["URLString"] as? String == "https://dup.com/" }.count, 3)
    }

    func testDeletedFolderDropsChildrenThatMovedOut() throws {
        try standardFixture()
        var nodes = try parser.read().filter { $0.id != "bookmark_bar:F" }
        nodes = edited(nodes, "bookmark_bar:F:d.com", parentId: .some(nil), newId: "bookmark_bar:d.com", index: 3)
        try parser.write(nodes: nodes)

        // `entries()` fails on a duplicate UUID, which the old writer produced here.
        let after = try entries()
        XCTAssertEqual((after["F"]?["Children"] as? [[String: Any]])?.count, 0)
        XCTAssertNil(syncData(after["F"]), "deleted entries lose position state")
        XCTAssertEqual(serverID(after["D"]), "S-D")
    }

    // MARK: - Lock

    func testWriteRemovesItsLock() throws {
        try standardFixture()
        try parser.write(nodes: try parser.read())
        XCTAssertFalse(FileManager.default.fileExists(atPath: lockDir.path))
    }

    private func placeLock(pid: Int32, host: String? = SafariBookmarksLock.hostUUID) throws {
        try FileManager.default.createDirectory(at: lockDir, withIntermediateDirectories: false)
        let details: [String: Any] = ["LockFileProcessID": Int(pid), "LockFileProcessName": "SafariBookmarksSyncAgent",
                                      "LockFileHostname": host ?? "", "LockFileDate": Date(), "LockFileUsername": NSFullUserName()]
        try PropertyListSerialization.data(fromPropertyList: details, format: .binary, options: 0)
            .write(to: lockDir.appendingPathComponent("details.plist"))
    }

    func testWriteIsRefusedWhileALiveProcessHoldsTheLock() throws {
        try standardFixture()
        let before = try Data(contentsOf: url)
        try placeLock(pid: ProcessInfo.processInfo.processIdentifier)

        XCTAssertThrowsError(try parser.write(nodes: try parser.read())) { error in
            guard case SafariBookmarksLock.LockError.held(let holder) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(holder, "SafariBookmarksSyncAgent")
        }
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertTrue(FileManager.default.fileExists(atPath: lockDir.path), "someone else's lock stays")
    }

    func testLockOfADeadProcessIsTakenOver() throws {
        try standardFixture()
        let finished = Process()
        finished.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try finished.run()
        finished.waitUntilExit()
        try placeLock(pid: finished.processIdentifier)

        XCTAssertNoThrow(try parser.write(nodes: try parser.read()))
        XCTAssertFalse(FileManager.default.fileExists(atPath: lockDir.path))
    }

    func testLockFromAnotherMacIsNeverTakenOver() throws {
        try standardFixture()
        try placeLock(pid: 1, host: "OTHER-MAC")
        XCTAssertThrowsError(try parser.write(nodes: try parser.read()))
    }

    func testWriteQueueKeepsAWriteBlockedByTheLock() throws {
        try standardFixture()
        try placeLock(pid: ProcessInfo.processInfo.processIdentifier)

        let queue = WriteQueue(monitorsSystem: false, runningBundleIds: { [] })
        queue.enqueue(parser: parser, nodes: try parser.read(), bundleId: "com.apple.Safari")
        XCTAssertTrue(queue.isWritePending(for: "com.apple.Safari"))

        try FileManager.default.removeItem(at: lockDir)
        queue.flush()
        XCTAssertFalse(queue.isWritePending(for: "com.apple.Safari"))
    }
}
