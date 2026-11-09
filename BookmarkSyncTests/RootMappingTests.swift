import XCTest
import SwiftData
@testable import BookmarkSync

final class BookmarkRootsTests: XCTestCase {
    func testSupportedRootsPerBrowser() {
        XCTAssertEqual(BookmarkRoots.supported(bundleId: "com.google.Chrome", profileName: "Default"), ["bookmark_bar", "other", "synced"])
        XCTAssertEqual(BookmarkRoots.supported(bundleId: "com.apple.Safari", profileName: "Default"), ["bookmark_bar", "other", "synced"])
        XCTAssertEqual(BookmarkRoots.supported(bundleId: "com.apple.Safari", profileName: "Work"), ["bookmark_bar"])
        XCTAssertEqual(BookmarkRoots.supported(bundleId: "org.mozilla.firefox", profileName: "default-release"), ["bookmark_bar", "other"])
    }

    func testRootOfPrefixedAndPlainIds() {
        XCTAssertEqual(BookmarkRoots.root(of: "SET-1:synced:example.com"), "synced")
        XCTAssertEqual(BookmarkRoots.root(of: "other:Folder:example.com"), "other")
    }
}

/// Chrome's mobile bookmarks have nowhere to go in a named Safari profile (one
/// folder, read as the bar). They must not be reported as missing there, or
/// every pass re-queues the same Safari write (plan item M2).
final class RootMappingSyncTests: XCTestCase {
    private var files: [URL] = []

    override func tearDown() {
        for url in files { try? FileManager.default.removeItem(at: url) }
        files = []
        super.tearDown()
    }

    private func leaf(_ i: Int, _ prefix: String) -> [String: Any] {
        ["id": "\(100 + i)", "name": "\(prefix) \(i)", "type": "url", "url": "https://example.com/\(prefix)/\(i)",
         "date_added": "13000000000000000", "date_modified": "13000000000000000"]
    }

    private func writeChrome(_ url: URL) throws {
        let root: [String: Any] = [
            "version": 1,
            "roots": [
                "bookmark_bar": ["id": "1", "name": "Bookmarks bar", "type": "folder", "date_added": "13000000000000000",
                                 "children": (0..<5).map { leaf($0, "bar") }],
                "other": ["id": "2", "name": "Other", "type": "folder", "date_added": "13000000000000000", "children": []],
                "synced": ["id": "3", "name": "Mobile", "type": "folder", "date_added": "13000000000000000",
                           "children": (5..<7).map { leaf($0, "mobile") }],
            ],
        ]
        try JSONSerialization.data(withJSONObject: root, options: []).write(to: url)
    }

    private func writeSafari(_ url: URL) throws {
        let bar: [[String: Any]] = (0..<5).map { i in
            ["Title": "bar \(i)", "WebBookmarkType": "WebBookmarkTypeLeaf", "URLString": "https://example.com/bar/\(i)",
             "WebBookmarkUUID": UUID().uuidString, "URIDictionary": ["title": "bar \(i)"]]
        }
        let root: [String: Any] = [
            "Children": [
                ["Title": "BookmarksBar", "WebBookmarkType": "WebBookmarkTypeList", "WebBookmarkUUID": UUID().uuidString, "Children": [[String: Any]]()],
                ["Title": "BookmarksMenu", "WebBookmarkType": "WebBookmarkTypeList", "WebBookmarkUUID": UUID().uuidString, "Children": [[String: Any]]()],
                ["Title": "Work", "WebBookmarkType": "WebBookmarkTypeList", "WebBookmarkUUID": UUID().uuidString, "Children": bar],
            ],
            "Title": "", "WebBookmarkFileVersion": 1, "WebBookmarkType": "WebBookmarkTypeList", "WebBookmarkUUID": "ROOT",
        ]
        try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0).write(to: url)
    }

    @MainActor
    func testRootsATargetLacksAreNotReportedMissing() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        let chromeFile = dir.appendingPathComponent("RootsChrome_\(UUID().uuidString)")
        let safariFile = dir.appendingPathComponent("RootsSafari_\(UUID().uuidString).plist")
        files += [chromeFile, safariFile]
        try writeChrome(chromeFile)
        try writeSafari(safariFile)

        let schema = Schema([BookmarkNode.self, BrowserConfig.self, ProfileSet.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let context = container.mainContext
        let set = ProfileSet(name: "Set 1")
        context.insert(set)
        let chrome = BrowserConfig(id: "com.google.Chrome:Roots", bundleId: "com.google.Chrome", browserName: "Google Chrome",
                                   profileName: "Roots", bookmarkFilePath: chromeFile.path, isEnabled: true, profileSetId: set.id)
        let safari = BrowserConfig(id: "com.apple.Safari:Work", bundleId: "com.apple.Safari", browserName: "Safari",
                                   profileName: "Work", bookmarkFilePath: safariFile.path, isEnabled: true, profileSetId: set.id)
        context.insert(chrome)
        context.insert(safari)
        try context.save()

        let viewModel = AppViewModel()
        viewModel.modelContext = context
        viewModel.syncState = .readOnly
        viewModel.isFullDiskAccessGranted = true
        let engine = SyncEngine(modelContext: context, viewModel: viewModel)
        viewModel.syncEngine = engine

        for _ in 0..<2 {
            engine.triggerSync(changedPaths: [], forceImmediate: true)
            let deadline = Date().addingTimeInterval(5)
            repeat {
                try await Task.sleep(nanoseconds: 20_000_000)
            } while (engine.isSyncing || engine.hasPendingSync) && Date() < deadline
        }

        let hub = try context.fetch(FetchDescriptor<BookmarkNode>())
        XCTAssertEqual(hub.filter { BookmarkRoots.root(of: $0.id) == "synced" }.count, 2,
                       "Chrome's mobile bookmarks are still kept in the hub")
        let safariChanges = viewModel.diffHistory.filter { $0.targetBundleIds.contains("com.apple.Safari") }
        XCTAssertTrue(safariChanges.isEmpty, "Safari has nothing to receive: \(safariChanges.map(\.bookmarkTitle))")

        let mobileNode = try XCTUnwrap(hub.first { BookmarkRoots.root(of: $0.id) == "synced" })
        XCTAssertEqual(viewModel.syncStatus(for: mobileNode.id, config: safari), .notSyncedHere)
    }
}
