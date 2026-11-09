import XCTest
import SwiftData
@testable import BookmarkSync

// MARK: - normalizeURL (plan item M1)

final class NormalizeURLTests: XCTestCase {
    func testFoldsSchemeHostCaseWwwDefaultPortAndTrailingSlash() {
        let same = [
            "https://example.com/a",
            "http://example.com/a",
            "https://EXAMPLE.com/a",
            "https://www.example.com/a",
            "https://example.com/a/",
            "https://example.com:443/a",
            "http://example.com:80/a",
        ]
        XCTAssertEqual(Set(same.map(normalizeURL)), ["example.com/a"])
    }

    func testKeepsNonDefaultPorts() {
        XCTAssertEqual(normalizeURL("http://localhost:3000/"), "localhost:3000")
        XCTAssertNotEqual(normalizeURL("http://localhost:3000/"), normalizeURL("http://localhost:8080/"))
    }

    func testKeepsPathQueryAndFragmentCase() {
        XCTAssertNotEqual(normalizeURL("https://example.com/Docs/A"), normalizeURL("https://example.com/docs/a"))
        XCTAssertNotEqual(normalizeURL("https://example.com/?id=AbC"), normalizeURL("https://example.com/?id=abc"))
        XCTAssertNotEqual(normalizeURL("https://example.com/#Top"), normalizeURL("https://example.com/#top"))
        XCTAssertEqual(normalizeURL("https://example.com/Docs?Q=1#Top"), "example.com/Docs?Q=1#Top")
    }
}

// MARK: - Id migration

final class BookmarkIdMigrationTests: XCTestCase {
    private typealias Item = BookmarkIdMigration.Item

    func testRemapsOnlyBookmarksWhoseIdChanges() {
        let items = [
            Item(id: "S:bookmark_bar:example.com/docs", url: "https://Example.com/Docs", parentId: nil, type: .leaf),
            Item(id: "S:bookmark_bar:example.com/docs:dup1", url: "https://example.com/docs", parentId: nil, type: .leaf),
            Item(id: "S:bookmark_bar:localhost", url: "http://localhost:3000/", parentId: nil, type: .leaf),
            Item(id: "S:bookmark_bar:localhost:dup1", url: "http://localhost:8080/", parentId: nil, type: .leaf),
            Item(id: "S:bookmark_bar:Work", url: nil, parentId: nil, type: .folder),
            Item(id: "S:bookmark_bar:Work:a.com/path?q=1", url: "https://a.com/Path?Q=1", parentId: "S:bookmark_bar:Work", type: .leaf),
            Item(id: "S:bookmark_bar:Work:b.com", url: "https://b.com", parentId: "S:bookmark_bar:Work", type: .leaf),
        ]
        XCTAssertEqual(BookmarkIdMigration.remap(items), [
            "S:bookmark_bar:example.com/docs": "S:bookmark_bar:example.com/Docs",
            "S:bookmark_bar:example.com/docs:dup1": "S:bookmark_bar:example.com/docs",
            "S:bookmark_bar:localhost": "S:bookmark_bar:localhost:3000",
            "S:bookmark_bar:localhost:dup1": "S:bookmark_bar:localhost:8080",
            "S:bookmark_bar:Work:a.com/path?q=1": "S:bookmark_bar:Work:a.com/Path?Q=1",
        ])
    }

    func testDuplicatesKeepTheirOrder() {
        // Three copies of the same page in one folder stay x, x:dup1, x:dup2.
        let items = (0..<3).map { i in
            Item(id: i == 0 ? "bookmark_bar:a.com/x" : "bookmark_bar:a.com/x:dup\(i)",
                 url: "https://a.com/X", parentId: nil, type: .leaf)
        }
        XCTAssertEqual(BookmarkIdMigration.remap(items), [
            "bookmark_bar:a.com/x": "bookmark_bar:a.com/X",
            "bookmark_bar:a.com/x:dup1": "bookmark_bar:a.com/X:dup1",
            "bookmark_bar:a.com/x:dup2": "bookmark_bar:a.com/X:dup2",
        ])
    }

    func testCurrentIdsAreLeftAlone() {
        let items = [Item(id: "other:example.com/Docs", url: "https://example.com/Docs", parentId: nil, type: .leaf)]
        XCTAssertTrue(BookmarkIdMigration.remap(items).isEmpty)
    }
}

/// A hub and observed state written with version-1 ids must line up exactly
/// with what the parsers now read, so the first sync after upgrading changes
/// nothing: no deletions, no additions, no held deletion.
final class BookmarkIdMigrationSyncTests: XCTestCase {
    private var files: [URL] = []

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: BookmarkIdMigration.defaultsKey)
    }

    override func tearDown() {
        for url in files { try? FileManager.default.removeItem(at: url) }
        files = []
        UserDefaults.standard.removeObject(forKey: BookmarkIdMigration.defaultsKey)
        super.tearDown()
    }

    private func writeFixture(_ url: URL) throws {
        func leaf(_ id: String, _ name: String, _ href: String) -> [String: Any] {
            ["id": id, "name": name, "type": "url", "url": href,
             "date_added": "13000000000000000", "date_modified": "13000000000000000"]
        }
        let bar: [[String: Any]] = [
            leaf("10", "Docs upper", "https://Example.com/Docs"),
            leaf("11", "Docs lower", "https://example.com/docs"),
            leaf("12", "Dev 3000", "http://localhost:3000/"),
            leaf("13", "Dev 8080", "http://localhost:8080/"),
            ["id": "14", "name": "Work", "type": "folder", "date_added": "13000000000000000",
             "children": [leaf("15", "Query", "https://a.com/Path?Q=1")]],
        ]
        let root: [String: Any] = [
            "version": 1,
            "roots": [
                "bookmark_bar": ["id": "1", "name": "Bookmarks bar", "type": "folder", "date_added": "13000000000000000", "children": bar],
                "other": ["id": "2", "name": "Other", "type": "folder", "date_added": "13000000000000000", "children": []],
                "synced": ["id": "3", "name": "Synced", "type": "folder", "date_added": "13000000000000000", "children": []],
            ],
        ]
        try JSONSerialization.data(withJSONObject: root, options: []).write(to: url)
    }

    /// What version 1 stored for the fixture (ids before profile-set prefixing).
    private let legacy: [(id: String, title: String, url: String?, type: BookmarkType, parent: String?, index: Int)] = [
        ("bookmark_bar:example.com/docs", "Docs upper", "https://Example.com/Docs", .leaf, nil, 0),
        ("bookmark_bar:example.com/docs:dup1", "Docs lower", "https://example.com/docs", .leaf, nil, 1),
        ("bookmark_bar:localhost", "Dev 3000", "http://localhost:3000/", .leaf, nil, 2),
        ("bookmark_bar:localhost:dup1", "Dev 8080", "http://localhost:8080/", .leaf, nil, 3),
        ("bookmark_bar:Work", "Work", nil, .folder, nil, 4),
        ("bookmark_bar:Work:a.com/path?q=1", "Query", "https://a.com/Path?Q=1", .leaf, "bookmark_bar:Work", 0),
    ]

    @MainActor
    func testFirstSyncAfterUpgradeChangesNothing() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        let fileA = dir.appendingPathComponent("MigrateA_\(UUID().uuidString)")
        let fileB = dir.appendingPathComponent("MigrateB_\(UUID().uuidString)")
        files += [fileA, fileB]
        try writeFixture(fileA)
        try writeFixture(fileB)

        let schema = Schema([BookmarkNode.self, BrowserConfig.self, ProfileSet.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let context = container.mainContext
        let set = ProfileSet(name: "Set 1")
        context.insert(set)
        let p = "\(set.id):"

        // A hub and two observed states exactly as version 1 left them.
        var records: [String: BookmarkNodeRecord] = [:]
        for item in legacy {
            context.insert(BookmarkNode(id: p + item.id, title: item.title, url: item.url, type: item.type,
                                        parentId: item.parent.map { p + $0 }, mtime: Date(), profileSetId: set.id, index: item.index))
            records[p + item.id] = BookmarkNodeRecord(id: p + item.id, title: item.title, url: item.url, type: item.type,
                                                      parentId: item.parent.map { p + $0 }, index: item.index)
        }
        let observed = try JSONEncoder().encode(records)
        var configs: [BrowserConfig] = []
        for (name, file) in [("MigrateA", fileA), ("MigrateB", fileB)] {
            let config = BrowserConfig(id: "com.google.Chrome:\(name)", bundleId: "com.google.Chrome", browserName: "Google Chrome",
                                       profileName: name, bookmarkFilePath: file.path, isEnabled: true, profileSetId: set.id,
                                       lastSyncTime: Date(), observedStateData: observed)
            context.insert(config)
            configs.append(config)
        }
        try context.save()

        let viewModel = AppViewModel()
        viewModel.modelContext = context
        viewModel.syncState = .readOnly
        viewModel.migratedEmptyFolderConfigIds = Set(configs.map(\.id))
        let engine = SyncEngine(modelContext: context, viewModel: viewModel)
        viewModel.syncEngine = engine

        // Both profiles count as changed, so the import compares every node.
        engine.triggerSync(changedPaths: [fileA.path, fileB.path], forceImmediate: true)
        let deadline = Date().addingTimeInterval(5)
        repeat {
            try await Task.sleep(nanoseconds: 20_000_000)
        } while (engine.isSyncing || engine.hasPendingSync) && Date() < deadline

        let expected = Set(try ChromeParser(filePath: fileA).read().map { p + $0.id })
        XCTAssertEqual(Set(try context.fetch(FetchDescriptor<BookmarkNode>()).map(\.id)), expected,
                       "The hub's ids match what the parser reads now")
        for config in configs {
            let decoded = try JSONDecoder().decode([String: BookmarkNodeRecord].self, from: try XCTUnwrap(config.observedStateData))
            XCTAssertEqual(Set(decoded.keys), expected, "\(config.profileName)'s observed state is migrated too")
        }
        XCTAssertTrue(viewModel.deletionHolds.isEmpty, "No deletion is held: nothing looks deleted")
        let churn = viewModel.diffHistory.filter { diff in ["Add: ", "Delete: ", "Update: "].contains { diff.bookmarkTitle.hasPrefix($0) } }
        XCTAssertTrue(churn.isEmpty, "No bookmark is added, deleted or updated: \(churn.map(\.bookmarkTitle))")
        XCTAssertEqual(UserDefaults.standard.integer(forKey: BookmarkIdMigration.defaultsKey), BookmarkIdMigration.currentVersion)
    }
}
