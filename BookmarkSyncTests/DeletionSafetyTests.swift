import XCTest
import SwiftData
import SQLite3
@testable import BookmarkSync

// MARK: - DeletionGuard rules

final class DeletionGuardTests: XCTestCase {
    private func ids(_ count: Int) -> Set<String> {
        Set((0..<count).map { "id\($0)" })
    }

    func testNoDeletionIsAllowed() {
        XCTAssertEqual(DeletionGuard.evaluate(previousCount: 100, currentCount: 100, deletedIds: []), .allow)
    }

    func testSmallDeletionIsAllowed() {
        XCTAssertEqual(DeletionGuard.evaluate(previousCount: 100, currentCount: 95, deletedIds: ids(5)), .allow)
        XCTAssertEqual(DeletionGuard.evaluate(previousCount: 100, currentCount: 81, deletedIds: ids(19)), .allow)
        XCTAssertEqual(DeletionGuard.evaluate(previousCount: 4, currentCount: 2, deletedIds: ids(2)), .allow)
    }

    func testMassDeletionIsHeld() {
        XCTAssertEqual(DeletionGuard.evaluate(previousCount: 100, currentCount: 80, deletedIds: ids(20)), .hold(.massDeletion))
        XCTAssertEqual(DeletionGuard.evaluate(previousCount: 4, currentCount: 1, deletedIds: ids(3)), .hold(.massDeletion))
    }

    func testEmptyReadIsHeldWhateverTheSize() {
        XCTAssertEqual(DeletionGuard.evaluate(previousCount: 2, currentCount: 0, deletedIds: ids(2)), .hold(.emptyRead))
        XCTAssertEqual(DeletionGuard.evaluate(previousCount: 500, currentCount: 0, deletedIds: ids(500)), .hold(.emptyRead))
    }

    func testApprovedDeletionsAreNotCountedAgain() {
        let deleted = ids(30)
        XCTAssertEqual(DeletionGuard.evaluate(previousCount: 100, currentCount: 70, deletedIds: deleted, approvedIds: deleted), .allow)
        // Approval covers 25 of 30: the remaining 5 are an ordinary small deletion.
        let approved = Set(deleted.sorted().prefix(25))
        XCTAssertEqual(DeletionGuard.evaluate(previousCount: 100, currentCount: 70, deletedIds: deleted, approvedIds: approved), .allow)
        // An approved empty read lets a deliberate "delete everything" through.
        XCTAssertEqual(DeletionGuard.evaluate(previousCount: 2, currentCount: 0, deletedIds: ids(2), approvedIds: ids(2)), .allow)
    }
}

// MARK: - Parsers refuse to read a malformed file as "no bookmarks"

final class ParserStructureTests: XCTestCase {
    private func tempURL(_ name: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(name)_\(UUID().uuidString)")
    }

    private func writePlist(_ root: [String: Any]) throws -> URL {
        let url = tempURL("SafariStructure").appendingPathExtension("plist")
        try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0).write(to: url)
        return url
    }

    private func assertParseError(_ expression: @autoclosure () throws -> [ParsedBookmark], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try expression(), file: file, line: line) { error in
            XCTAssertTrue(error is BookmarkParseError, "Expected BookmarkParseError, got \(error)", file: file, line: line)
        }
    }

    func testSafariWithoutChildrenThrows() throws {
        let url = try writePlist(["Title": "", "WebBookmarkType": "WebBookmarkTypeList"])
        defer { try? FileManager.default.removeItem(at: url) }
        assertParseError(try SafariParser(filePath: url).read())
    }

    func testSafariWithoutKnownRootsThrows() throws {
        let url = try writePlist(["Children": [["Title": "com.apple.ReadingList", "WebBookmarkType": "WebBookmarkTypeList"]]])
        defer { try? FileManager.default.removeItem(at: url) }
        assertParseError(try SafariParser(filePath: url).read())
    }

    func testSafariMissingProfileFolderThrows() throws {
        let url = try writePlist(["Children": [["Title": "BookmarksBar", "WebBookmarkType": "WebBookmarkTypeList", "Children": [[String: Any]]()]]])
        defer { try? FileManager.default.removeItem(at: url) }
        assertParseError(try SafariParser(filePath: url, profileName: "Work").read())
    }

    func testSafariWithEmptyRootsReadsAsEmpty() throws {
        let url = try writePlist(["Children": [
            ["Title": "BookmarksBar", "WebBookmarkType": "WebBookmarkTypeList", "Children": [[String: Any]]()],
            ["Title": "BookmarksMenu", "WebBookmarkType": "WebBookmarkTypeList", "Children": [[String: Any]]()],
        ]])
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(try SafariParser(filePath: url).read().count, 0)
    }

    /// Builds a minimal places.sqlite with the columns `FirefoxParser` reads.
    private func makeFirefoxFixture(includeToolbar: Bool) throws -> URL {
        let url = tempURL("places").appendingPathExtension("sqlite")
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else {
            throw NSError(domain: "FirefoxFixture", code: 1)
        }
        defer { sqlite3_close(db) }

        var rows = [
            "(1, 2, NULL, 0, 0, '', 0, 0, 'root________')",
            "(2, 2, NULL, 1, 0, 'menu', 0, 0, 'menu________')",
            "(4, 2, NULL, 1, 2, 'tags', 0, 0, 'tags________')",
            "(5, 2, NULL, 1, 3, 'unfiled', 0, 0, 'unfiled_____')",
            "(10, 1, 1, 5, 0, 'Example', 0, 0, 'bookmark0001')",
        ]
        if includeToolbar {
            rows.append("(3, 2, NULL, 1, 1, 'toolbar', 0, 0, 'toolbar_____')")
        }
        let sql = """
        CREATE TABLE moz_places (id INTEGER PRIMARY KEY, url TEXT, title TEXT);
        CREATE TABLE moz_bookmarks (id INTEGER PRIMARY KEY, type INTEGER, fk INTEGER, parent INTEGER, position INTEGER, title TEXT, dateAdded INTEGER, lastModified INTEGER, guid TEXT);
        INSERT INTO moz_places VALUES (1, 'https://example.com/a', 'Example');
        INSERT INTO moz_bookmarks VALUES \(rows.joined(separator: ", "));
        """
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "FirefoxFixture", code: 2, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
        }
        return url
    }

    func testFirefoxMissingDatabaseThrows() {
        let url = tempURL("missing_places").appendingPathExtension("sqlite")
        XCTAssertThrowsError(try FirefoxParser(filePath: url).read())
    }

    func testFirefoxWithoutToolbarRootThrows() throws {
        let url = try makeFirefoxFixture(includeToolbar: false)
        defer { try? FileManager.default.removeItem(at: url) }
        assertParseError(try FirefoxParser(filePath: url).read())
    }

    func testFirefoxWithRootsReadsBookmarks() throws {
        let url = try makeFirefoxFixture(includeToolbar: true)
        defer { try? FileManager.default.removeItem(at: url) }
        let nodes = try FirefoxParser(filePath: url).read()
        XCTAssertEqual(nodes.map(\.url), ["https://example.com/a"])
        XCTAssertEqual(nodes.first?.id, "other:example.com/a")
    }
}

// MARK: - The engine holds suspicious deletions instead of spreading them

final class DeletionHoldIntegrationTests: XCTestCase {
    private struct Harness {
        let container: ModelContainer
        let context: ModelContext
        let viewModel: AppViewModel
        let engine: SyncEngine
        let configA: BrowserConfig
        let fileA: URL
        let fileB: URL
    }

    private var files: [URL] = []

    override func tearDown() {
        for url in files { try? FileManager.default.removeItem(at: url) }
        files = []
        super.tearDown()
    }

    /// Writes a Chrome bookmarks file whose bar holds `https://example.com/<i>` for each index.
    private func writeChrome(_ url: URL, indices: [Int]) throws {
        let children = indices.map { i -> [String: Any] in
            ["id": "\(100 + i)", "name": "Bookmark \(i)", "type": "url", "url": "https://example.com/\(i)",
             "date_added": "13000000000000000", "date_modified": "13000000000000000"]
        }
        let root: [String: Any] = [
            "version": 1,
            "roots": [
                "bookmark_bar": ["id": "1", "name": "Bookmarks bar", "type": "folder", "date_added": "13000000000000000", "children": children],
                "other": ["id": "2", "name": "Other", "type": "folder", "date_added": "13000000000000000", "children": []],
                "synced": ["id": "3", "name": "Synced", "type": "folder", "date_added": "13000000000000000", "children": []],
            ],
        ]
        try JSONSerialization.data(withJSONObject: root, options: []).write(to: url)
    }

    /// Two Chrome profiles in one set, both holding 20 bookmarks, after a first sync.
    @MainActor
    private func makeSyncedHarness() async throws -> Harness {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        let fileA = dir.appendingPathComponent("BookmarksA_\(UUID().uuidString)")
        let fileB = dir.appendingPathComponent("BookmarksB_\(UUID().uuidString)")
        files += [fileA, fileB]
        try writeChrome(fileA, indices: Array(0..<20))
        try writeChrome(fileB, indices: Array(0..<20))

        let schema = Schema([BookmarkNode.self, BrowserConfig.self, ProfileSet.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let context = container.mainContext
        let profileSet = ProfileSet(name: "Set 1")
        context.insert(profileSet)
        let configA = BrowserConfig(id: "com.google.Chrome:A", bundleId: "com.google.Chrome", browserName: "Google Chrome",
                                    profileName: "A", bookmarkFilePath: fileA.path, isEnabled: true, profileSetId: profileSet.id)
        let configB = BrowserConfig(id: "com.google.Chrome:B", bundleId: "com.google.Chrome", browserName: "Google Chrome",
                                    profileName: "B", bookmarkFilePath: fileB.path, isEnabled: true, profileSetId: profileSet.id)
        context.insert(configA)
        context.insert(configB)
        try context.save()

        let viewModel = AppViewModel()
        viewModel.modelContext = context
        // Never write to disk from tests; reads, the hub and the guard are what matter here.
        viewModel.syncState = .readOnly
        let engine = SyncEngine(modelContext: context, viewModel: viewModel)
        viewModel.syncEngine = engine

        let harness = Harness(container: container, context: context, viewModel: viewModel, engine: engine,
                              configA: configA, fileA: fileA, fileB: fileB)
        try await sync(harness)
        XCTAssertEqual(try hubCount(harness), 20, "Initial sync should import the fixture")
        XCTAssertNotNil(configA.lastSyncTime)
        return harness
    }

    @MainActor
    private func waitUntilIdle(_ h: Harness) async throws {
        let deadline = Date().addingTimeInterval(5)
        repeat {
            try await Task.sleep(nanoseconds: 20_000_000)
        } while (h.engine.isSyncing || h.engine.hasPendingSync) && Date() < deadline
        XCTAssertFalse(h.engine.isSyncing, "Sync did not finish in time")
    }

    @MainActor
    private func sync(_ h: Harness, changed: [URL] = []) async throws {
        h.engine.triggerSync(changedPaths: changed.map(\.path), forceImmediate: true)
        try await waitUntilIdle(h)
    }

    @MainActor
    private func hubCount(_ h: Harness) throws -> Int {
        try h.context.fetchCount(FetchDescriptor<BookmarkNode>())
    }

    @MainActor
    func testEmptyReadIsHeldAndClearsWhenTheFileRecovers() async throws {
        let h = try await makeSyncedHarness()
        let observedBefore = h.configA.observedStateData

        try writeChrome(h.fileA, indices: [])
        try await sync(h, changed: [h.fileA])

        XCTAssertEqual(h.viewModel.deletionHolds[h.configA.id]?.reason, .emptyRead)
        XCTAssertEqual(try hubCount(h), 20, "An empty read must not delete anything from the hub")
        XCTAssertEqual(h.configA.observedStateData, observedBefore, "A held profile keeps its last observed state")

        try writeChrome(h.fileA, indices: Array(0..<20))
        try await sync(h, changed: [h.fileA])

        XCTAssertNil(h.viewModel.deletionHolds[h.configA.id], "The hold clears once the file reads normally again")
        XCTAssertEqual(try hubCount(h), 20)
    }

    @MainActor
    func testSmallDeletionStillPropagates() async throws {
        let h = try await makeSyncedHarness()

        try writeChrome(h.fileA, indices: Array(0..<19))
        try await sync(h, changed: [h.fileA])

        XCTAssertTrue(h.viewModel.deletionHolds.isEmpty)
        XCTAssertEqual(try hubCount(h), 19)
    }

    @MainActor
    func testMassDeletionIsHeldUntilApproved() async throws {
        let h = try await makeSyncedHarness()

        try writeChrome(h.fileA, indices: Array(0..<5))
        try await sync(h, changed: [h.fileA])

        let hold = try XCTUnwrap(h.viewModel.deletionHolds[h.configA.id])
        XCTAssertEqual(hold.reason, .massDeletion)
        XCTAssertEqual(hold.deletedIds.count, 15)
        XCTAssertEqual(hold.previousCount, 20)
        XCTAssertEqual(hold.diff.removed.count, 15, "The hold lists every bookmark it would delete")
        XCTAssertEqual(Set(hold.diff.removed.map(\.title)), Set((5..<20).map { "Bookmark \($0)" }))
        XCTAssertTrue(hold.diff.added.isEmpty)
        XCTAssertEqual(try hubCount(h), 20, "A held deletion must not reach the hub")

        // Holding is stable across passes.
        try await sync(h, changed: [h.fileA])
        XCTAssertNotNil(h.viewModel.deletionHolds[h.configA.id])
        XCTAssertEqual(try hubCount(h), 20)

        h.viewModel.approveDeletionHold(configId: h.configA.id)
        try await waitUntilIdle(h)

        XCTAssertNil(h.viewModel.deletionHolds[h.configA.id])
        XCTAssertEqual(try hubCount(h), 5, "Approved deletions are applied")
        XCTAssertNil(h.viewModel.approvedDeletions[h.configA.id], "An approval is consumed once applied")
    }

    @MainActor
    func testRejectedDeletionKeepsTheHubAndIsNotHeldAgain() async throws {
        let h = try await makeSyncedHarness()

        try writeChrome(h.fileA, indices: Array(0..<5))
        try await sync(h, changed: [h.fileA])
        XCTAssertNotNil(h.viewModel.deletionHolds[h.configA.id])

        h.viewModel.rejectDeletionHold(configId: h.configA.id)
        try await waitUntilIdle(h)

        XCTAssertNil(h.viewModel.deletionHolds[h.configA.id])
        XCTAssertEqual(try hubCount(h), 20, "Rejecting keeps every bookmark in the hub")
        XCTAssertEqual(h.viewModel.latestBrowserNodes[h.configA.id]?.count, 5,
                       "The profile's current file becomes the new baseline, so the export can write the rest back")

        try await sync(h, changed: [h.fileA])
        XCTAssertNil(h.viewModel.deletionHolds[h.configA.id], "The same file must not be held again")
        XCTAssertEqual(try hubCount(h), 20)
    }
}
