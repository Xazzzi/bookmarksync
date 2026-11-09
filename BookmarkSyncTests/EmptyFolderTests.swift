import XCTest
import SwiftData
@testable import BookmarkSync

final class EmptyFolderMigrationTests: XCTestCase {
    private func folder(_ id: String, parent: String? = nil) -> ParsedBookmark {
        ParsedBookmark(id: id, title: id, type: .folder, parentId: parent, mtime: Date(timeIntervalSince1970: 0))
    }

    private func leaf(_ id: String, parent: String? = nil) -> ParsedBookmark {
        ParsedBookmark(id: id, title: id, url: "https://\(id)", type: .leaf, parentId: parent, mtime: Date(timeIntervalSince1970: 0))
    }

    func testFindsEmptyAndNestedEmptyFoldersOnly() {
        let nodes = [
            folder("full"), leaf("a", parent: "full"),
            folder("empty"),
            folder("outer"), folder("inner", parent: "outer"),
            folder("deep"), folder("deepChild", parent: "deep"), leaf("b", parent: "deepChild"),
        ]
        XCTAssertEqual(Set(EmptyFolderMigration.emptyFolders(in: nodes).map(\.id)), ["empty", "outer", "inner"])
    }
}

/// An empty folder created in one browser must survive a sync instead of being
/// deleted everywhere (plan item M3).
final class EmptyFolderSyncTests: XCTestCase {
    private struct Harness {
        let container: ModelContainer
        let context: ModelContext
        let viewModel: AppViewModel
        let engine: SyncEngine
        let configA: BrowserConfig
        let configB: BrowserConfig
        let fileA: URL
        let setId: String
    }

    private var files: [URL] = []

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: EmptyFolderMigration.defaultsKey)
    }

    override func tearDown() {
        for url in files { try? FileManager.default.removeItem(at: url) }
        files = []
        UserDefaults.standard.removeObject(forKey: EmptyFolderMigration.defaultsKey)
        super.tearDown()
    }

    /// Five bookmarks on the bar, plus optional empty folders after them.
    private func writeChrome(_ url: URL, emptyFolders: [String] = []) throws {
        var children: [[String: Any]] = (0..<5).map { i in
            ["id": "\(100 + i)", "name": "Bookmark \(i)", "type": "url", "url": "https://example.com/\(i)",
             "date_added": "13000000000000000", "date_modified": "13000000000000000"]
        }
        for (i, name) in emptyFolders.enumerated() {
            children.append(["id": "\(200 + i)", "name": name, "type": "folder",
                             "date_added": "13000000000000000", "children": [[String: Any]]()])
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

    @MainActor
    private func makeHarness(emptyFoldersInA: [String] = []) async throws -> Harness {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        let fileA = dir.appendingPathComponent("EmptyA_\(UUID().uuidString)")
        let fileB = dir.appendingPathComponent("EmptyB_\(UUID().uuidString)")
        files += [fileA, fileB]
        try writeChrome(fileA, emptyFolders: emptyFoldersInA)
        try writeChrome(fileB)

        let schema = Schema([BookmarkNode.self, BrowserConfig.self, ProfileSet.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let context = container.mainContext
        let profileSet = ProfileSet(name: "Set 1")
        context.insert(profileSet)
        let configA = BrowserConfig(id: "com.google.Chrome:EmptyA", bundleId: "com.google.Chrome", browserName: "Google Chrome",
                                    profileName: "EmptyA", bookmarkFilePath: fileA.path, isEnabled: true, profileSetId: profileSet.id)
        let configB = BrowserConfig(id: "com.google.Chrome:EmptyB", bundleId: "com.google.Chrome", browserName: "Google Chrome",
                                    profileName: "EmptyB", bookmarkFilePath: fileB.path, isEnabled: true, profileSetId: profileSet.id)
        context.insert(configA)
        context.insert(configB)
        try context.save()

        let viewModel = AppViewModel()
        viewModel.modelContext = context
        viewModel.syncState = .readOnly
        let engine = SyncEngine(modelContext: context, viewModel: viewModel)
        viewModel.syncEngine = engine

        let h = Harness(container: container, context: context, viewModel: viewModel, engine: engine,
                        configA: configA, configB: configB, fileA: fileA, setId: profileSet.id)
        try await sync(h)
        return h
    }

    @MainActor
    private func sync(_ h: Harness, changed: [URL] = []) async throws {
        h.engine.triggerSync(changedPaths: changed.map(\.path), forceImmediate: true)
        let deadline = Date().addingTimeInterval(5)
        repeat {
            try await Task.sleep(nanoseconds: 20_000_000)
        } while (h.engine.isSyncing || h.engine.hasPendingSync) && Date() < deadline
        XCTAssertFalse(h.engine.isSyncing, "Sync did not finish in time")
    }

    @MainActor
    private func hubIds(_ h: Harness) throws -> Set<String> {
        Set(try h.context.fetch(FetchDescriptor<BookmarkNode>()).map(\.id))
    }

    private func folderId(_ h: Harness, _ name: String) -> String {
        "\(h.setId):bookmark_bar:\(name)"
    }

    @MainActor
    func testNewEmptyFolderIsKeptInTheHub() async throws {
        let h = try await makeHarness()
        XCTAssertEqual(try hubIds(h).count, 5)

        try writeChrome(h.fileA, emptyFolders: ["New Folder"])
        try await sync(h, changed: [h.fileA])
        XCTAssertTrue(try hubIds(h).contains(folderId(h, "New Folder")), "A new empty folder is imported, not filtered out")

        try await sync(h, changed: [h.fileA])
        XCTAssertTrue(try hubIds(h).contains(folderId(h, "New Folder")), "It stays on later passes")
        XCTAssertFalse(
            h.viewModel.diffHistory.contains { $0.bookmarkTitle == "Delete: New Folder" },
            "The browser that created it must not be told to delete it"
        )
    }

    @MainActor
    func testEmptyFoldersMissingFromAnOldHubAreRestoredOnce() async throws {
        let h = try await makeHarness(emptyFoldersInA: ["Legacy"])
        let id = folderId(h, "Legacy")

        // Recreate what an older version left behind: the folder filtered out of
        // the hub, and no migration recorded yet.
        let stale = try h.context.fetch(FetchDescriptor<BookmarkNode>()).filter { $0.id == id }
        stale.forEach { h.context.delete($0) }
        try h.context.save()
        h.viewModel.migratedEmptyFolderConfigIds = []

        try await sync(h)
        XCTAssertTrue(try hubIds(h).contains(id), "The pre-existing empty folder is added back to the hub")
        XCTAssertTrue(h.viewModel.migratedEmptyFolderConfigIds.isSuperset(of: [h.configA.id, h.configB.id]))

        // Once migrated, a folder missing from the hub means it was deleted
        // elsewhere, and must not be resurrected.
        let again = try h.context.fetch(FetchDescriptor<BookmarkNode>()).filter { $0.id == id }
        again.forEach { h.context.delete($0) }
        try h.context.save()
        try await sync(h)
        XCTAssertFalse(try hubIds(h).contains(id), "The one-off restore does not run a second time")
    }
}
