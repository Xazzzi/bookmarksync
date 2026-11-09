import XCTest
import SwiftData
@testable import BookmarkSync

/// Deleting a bookmark in the bookmarks window removes it from the hub; the
/// next sync must plan its removal from every browser and must not import it
/// back from the browsers that still have it.
final class DeleteFromHubTests: XCTestCase {
    private var files: [URL] = []

    override func tearDown() {
        for url in files { try? FileManager.default.removeItem(at: url) }
        files = []
        super.tearDown()
    }

    private func chromeLeaf(_ i: Int) -> [String: Any] {
        ["id": "\(100 + i)", "name": "bar \(i)", "type": "url", "url": "https://example.com/bar/\(i)",
         "date_added": "13000000000000000", "date_modified": "13000000000000000"]
    }

    private func writeChrome(_ url: URL) throws {
        let folder: [String: Any] = ["id": "50", "name": "Folder", "type": "folder", "date_added": "13000000000000000",
                                     "children": [chromeLeaf(3), chromeLeaf(4)]]
        let root: [String: Any] = [
            "version": 1,
            "roots": [
                "bookmark_bar": ["id": "1", "name": "Bookmarks bar", "type": "folder", "date_added": "13000000000000000",
                                 "children": (0..<3).map { chromeLeaf($0) } + [folder]],
                "other": ["id": "2", "name": "Other", "type": "folder", "date_added": "13000000000000000", "children": []],
                "synced": ["id": "3", "name": "Mobile", "type": "folder", "date_added": "13000000000000000", "children": []],
            ],
        ]
        try JSONSerialization.data(withJSONObject: root, options: []).write(to: url)
    }

    private func safariLeaf(_ i: Int) -> [String: Any] {
        ["Title": "bar \(i)", "WebBookmarkType": "WebBookmarkTypeLeaf", "URLString": "https://example.com/bar/\(i)",
         "WebBookmarkUUID": UUID().uuidString, "URIDictionary": ["title": "bar \(i)"]]
    }

    private func writeSafari(_ url: URL) throws {
        let folder: [String: Any] = ["Title": "Folder", "WebBookmarkType": "WebBookmarkTypeList",
                                     "WebBookmarkUUID": UUID().uuidString, "Children": [safariLeaf(3), safariLeaf(4)]]
        let root: [String: Any] = [
            "Children": [
                ["Title": "BookmarksBar", "WebBookmarkType": "WebBookmarkTypeList", "WebBookmarkUUID": UUID().uuidString,
                 "Children": (0..<3).map { safariLeaf($0) } + [folder]],
                ["Title": "BookmarksMenu", "WebBookmarkType": "WebBookmarkTypeList", "WebBookmarkUUID": UUID().uuidString, "Children": [[String: Any]]()],
            ],
            "Title": "", "WebBookmarkFileVersion": 1, "WebBookmarkType": "WebBookmarkTypeList", "WebBookmarkUUID": "ROOT",
        ]
        try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0).write(to: url)
    }

    @MainActor
    private func settle(_ engine: SyncEngine) async throws {
        let deadline = Date().addingTimeInterval(5)
        repeat {
            try await Task.sleep(nanoseconds: 20_000_000)
        } while (engine.isSyncing || engine.hasPendingSync) && Date() < deadline
    }

    @MainActor
    func testDeletingInTheHubPlansRemovalEverywhereAndIsNotReimported() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        let chromeFile = dir.appendingPathComponent("DeleteChrome_\(UUID().uuidString)")
        let safariFile = dir.appendingPathComponent("DeleteSafari_\(UUID().uuidString).plist")
        files += [chromeFile, safariFile]
        try writeChrome(chromeFile)
        try writeSafari(safariFile)

        let schema = Schema([BookmarkNode.self, BrowserConfig.self, ProfileSet.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let context = container.mainContext
        let set = ProfileSet(name: "Set 1")
        context.insert(set)
        context.insert(BrowserConfig(id: "com.google.Chrome:Delete", bundleId: "com.google.Chrome", browserName: "Google Chrome",
                                     profileName: "Delete", bookmarkFilePath: chromeFile.path, isEnabled: true, profileSetId: set.id))
        context.insert(BrowserConfig(id: "com.apple.Safari:Default", bundleId: "com.apple.Safari", browserName: "Safari",
                                     profileName: "Default", bookmarkFilePath: safariFile.path, isEnabled: true, profileSetId: set.id))
        try context.save()

        let viewModel = AppViewModel()
        viewModel.modelContext = context
        viewModel.syncState = .readOnly
        viewModel.isFullDiskAccessGranted = true
        let engine = SyncEngine(modelContext: context, viewModel: viewModel)
        viewModel.syncEngine = engine

        for _ in 0..<2 {
            engine.triggerSync(changedPaths: [], forceImmediate: true)
            try await settle(engine)
        }
        let hubIds = { Set(try context.fetch(FetchDescriptor<BookmarkNode>()).map { stripProfileSetPrefix($0.id) }) }
        XCTAssertTrue(try hubIds().contains("bookmark_bar:example.com/bar/0"))

        // A folder takes its contents with it.
        XCTAssertEqual(viewModel.hubNodesToDelete(forItemId: "bookmark_bar:Folder").count, 3)

        // The global view passes the prefix-stripped id.
        XCTAssertEqual(viewModel.deleteBookmark(itemId: "bookmark_bar:example.com/bar/0"), 1)
        try await settle(engine)
        engine.triggerSync(changedPaths: [], forceImmediate: true)
        try await settle(engine)

        XCTAssertFalse(try hubIds().contains("bookmark_bar:example.com/bar/0"), "Not imported back from the browsers")
        XCTAssertTrue(try hubIds().contains("bookmark_bar:example.com/bar/1"))
        for bundleId in ["com.google.Chrome", "com.apple.Safari"] {
            XCTAssertTrue(viewModel.diffHistory.contains {
                $0.isWaiting && $0.bookmarkTitle == "Delete: bar 0" && $0.targetBundleIds.contains(bundleId)
            }, "Removal planned for \(bundleId)")
        }
    }
}
