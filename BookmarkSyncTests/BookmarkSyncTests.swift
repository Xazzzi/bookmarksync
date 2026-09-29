import XCTest
import SwiftData
@testable import BookmarkSync

final class BookmarkSyncTests: XCTestCase {
    
    @MainActor
    func testNWayMergeInsert() throws {
        let schema = Schema([BookmarkNode.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        
        let viewModel = AppViewModel()
        let engine = SyncEngine(modelContext: container.mainContext, viewModel: viewModel)
        
        let b1 = BookmarkNode(id: "bookmark_bar:https://google.com", title: "Google", url: "https://google.com", type: .leaf, mtime: Date())
        
        let state: [BookmarkNode] = []
        let chrome: [BookmarkNode] = [b1]
        let safari: [BookmarkNode] = []
        
        let c1 = BrowserConfig(id: "c1", bundleId: "com.google.Chrome", browserName: "Google Chrome", profileName: "Synctest", bookmarkFilePath: "")
        let c2 = BrowserConfig(id: "c2", bundleId: "com.apple.Safari", browserName: "Safari", profileName: "Default", bookmarkFilePath: "")
        
        let (merged, _) = engine.merge(state: state, browsers: [chrome, safari], activeConfigs: [c1, c2])
        
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.id, "bookmark_bar:https://google.com")
    }
    
    @MainActor
    func testNWayMergeDelete() throws {
        let schema = Schema([BookmarkNode.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        
        let viewModel = AppViewModel()
        let engine = SyncEngine(modelContext: container.mainContext, viewModel: viewModel)
        
        let b1 = BookmarkNode(id: "bookmark_bar:https://google.com", title: "Google", url: "https://google.com", type: .leaf, mtime: Date())
        
        let state: [BookmarkNode] = [b1]
        let chrome: [BookmarkNode] = [] // Deleted in chrome
        let safari: [BookmarkNode] = [b1] // Still in safari
        
        let c1 = BrowserConfig(id: "c1", bundleId: "com.google.Chrome", browserName: "Google Chrome", profileName: "Synctest", bookmarkFilePath: "")
        let c2 = BrowserConfig(id: "c2", bundleId: "com.apple.Safari", browserName: "Safari", profileName: "Default", bookmarkFilePath: "")
        c1.lastSyncTime = Date()
        c2.lastSyncTime = Date()
        
        // A deletion is only detectable against previously observed browser
        // state: "was here last time, gone now" is what distinguishes a user
        // deletion from a profile that simply never had the bookmark. Without
        // this the deletion pass has nothing to iterate.
        let observed = ParsedBookmark(id: b1.id, title: b1.title, url: b1.url, type: b1.type, parentId: b1.parentId, mtime: b1.mtime, index: b1.index)
        viewModel.latestBrowserNodes[c1.id] = [b1.id: observed]
        viewModel.latestBrowserNodes[c2.id] = [b1.id: observed]
        
        let (merged, _) = engine.merge(state: state, browsers: [chrome, safari], activeConfigs: [c1, c2])
        
        XCTAssertEqual(merged.count, 0, "Bookmark should be deleted from all if missing in one compared to state")
    }
    
    func testSafariParserCustomProfile() throws {
        let tempDir = NSTemporaryDirectory()
        let uniqueName = "MockBookmarks_\(UUID().uuidString)"
        let tempPlistURL = URL(fileURLWithPath: tempDir).appendingPathComponent("\(uniqueName).plist")
        
        let initialPlist: [String: Any] = [
            "Children": [
                [
                    "Title": "BookmarksBar",
                    "WebBookmarkType": "WebBookmarkTypeList",
                    "Children": []
                ],
                [
                    "Title": "MySafariProfile",
                    "WebBookmarkType": "WebBookmarkTypeList",
                    "Children": [
                        [
                            "Title": "Google",
                            "WebBookmarkType": "WebBookmarkTypeLeaf",
                            "URLString": "https://google.com",
                            "WebBookmarkUUID": "UUID1"
                        ]
                    ]
                ]
            ],
            "Title": "",
            "WebBookmarkFileVersion": 1,
            "WebBookmarkType": "WebBookmarkTypeList",
            "WebBookmarkUUID": "ROOT"
        ]
        
        let data = try PropertyListSerialization.data(fromPropertyList: initialPlist, format: .binary, options: 0)
        try data.write(to: tempPlistURL)
        
        defer {
            let fm = FileManager.default
            try? fm.removeItem(at: tempPlistURL)
            if let files = try? fm.contentsOfDirectory(atPath: tempDir) {
                for file in files {
                    if file.hasPrefix(uniqueName) {
                        try? fm.removeItem(at: URL(fileURLWithPath: tempDir).appendingPathComponent(file))
                    }
                }
            }
        }
        
        // 1. Read
        let parser = SafariParser(filePath: tempPlistURL, profileName: "MySafariProfile")
        let nodes = try parser.read()
        
        XCTAssertEqual(nodes.count, 1)
        XCTAssertEqual(nodes.first?.title, "Google")
        XCTAssertEqual(nodes.first?.url, "https://google.com")
        XCTAssertTrue(nodes.first!.id.starts(with: "bookmark_bar:"))
        
        // 2. Write
        let newNode = ParsedBookmark(id: "bookmark_bar:https://apple.com", title: "Apple", url: "https://apple.com", type: .leaf, mtime: Date())
        try parser.write(nodes: [newNode])
        
        let updatedData = try Data(contentsOf: tempPlistURL)
        let updatedPlist = try PropertyListSerialization.propertyList(from: updatedData, options: [], format: nil) as! [String: Any]
        let rootChildren = updatedPlist["Children"] as! [[String: Any]]
        
        let profileNode = rootChildren.first(where: { ($0["Title"] as? String) == "MySafariProfile" })!
        let profileChildren = profileNode["Children"] as! [[String: Any]]
        
        XCTAssertEqual(profileChildren.count, 1)
        XCTAssertEqual(profileChildren.first?["Title"] as? String, "Apple")
        XCTAssertEqual(profileChildren.first?["URLString"] as? String, "https://apple.com")
    }
    
    func testChromeParserTargetedUpdate() throws {
        let tempDir = NSTemporaryDirectory()
        let uniqueName = "MockChromeBookmarks_\(UUID().uuidString)"
        let tempJSONURL = URL(fileURLWithPath: tempDir).appendingPathComponent("\(uniqueName).json")
        
        let initialJSON: [String: Any] = [
            "checksum": "1234567890abcdef",
            "version": 1,
            "myCustomKey": "preserveMe",
            "roots": [
                "bookmark_bar": [
                    "id": "1",
                    "name": "Bookmarks bar",
                    "type": "folder",
                    "children": []
                ],
                "other": [
                    "id": "2",
                    "name": "Other bookmarks",
                    "type": "folder",
                    "children": []
                ],
                "synced": [
                    "id": "3",
                    "name": "Mobile bookmarks",
                    "type": "folder",
                    "children": []
                ]
            ]
        ]
        
        let data = try JSONSerialization.data(withJSONObject: initialJSON, options: .prettyPrinted)
        try data.write(to: tempJSONURL)
        
        defer {
            let fm = FileManager.default
            try? fm.removeItem(at: tempJSONURL)
            if let files = try? fm.contentsOfDirectory(atPath: tempDir) {
                for file in files {
                    if file.hasPrefix(uniqueName) {
                        try? fm.removeItem(at: URL(fileURLWithPath: tempDir).appendingPathComponent(file))
                    }
                }
            }
        }
        
        // Write targeted update
        let parser = ChromeParser(filePath: tempJSONURL)
        let newNode = ParsedBookmark(id: "bookmark_bar:https://google.com", title: "Google", url: "https://google.com", type: .leaf, mtime: Date())
        try parser.write(nodes: [newNode])
        
        // Validate
        let updatedData = try Data(contentsOf: tempJSONURL)
        let updatedJSON = try JSONSerialization.jsonObject(with: updatedData, options: []) as! [String: Any]
        
        // 1. "checksum" should be deleted
        XCTAssertNil(updatedJSON["checksum"])
        
        // 2. "version" and "myCustomKey" should be preserved
        XCTAssertEqual(updatedJSON["version"] as? Int, 1)
        XCTAssertEqual(updatedJSON["myCustomKey"] as? String, "preserveMe")
        
        // 3. New bookmark should be written under roots.bookmark_bar.children
        let roots = updatedJSON["roots"] as! [String: Any]
        let bookmarkBar = roots["bookmark_bar"] as! [String: Any]
        let children = bookmarkBar["children"] as! [[String: Any]]
        XCTAssertEqual(children.count, 1)
        XCTAssertEqual(children.first?["name"] as? String, "Google")
        
        // 4. Backup should have been created
        let backupURL = tempJSONURL.deletingLastPathComponent().appendingPathComponent("\(uniqueName).json.backup.1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.path))
    }
    
    @MainActor
    func testFilterEmptyFolders() throws {
        let schema = Schema([BookmarkNode.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        
        let viewModel = AppViewModel()
        let engine = SyncEngine(modelContext: container.mainContext, viewModel: viewModel)
        
        // 1. Non-empty folder structure
        let f1 = BookmarkNode(id: "bookmark_bar:folder1", title: "Folder 1", url: nil, type: .folder, parentId: nil, mtime: Date())
        let b1 = BookmarkNode(id: "bookmark_bar:https://google.com", title: "Google", url: "https://google.com", type: .leaf, parentId: "bookmark_bar:folder1", mtime: Date())
        
        // 2. Empty folder structure
        let f2 = BookmarkNode(id: "bookmark_bar:folder2", title: "Folder 2", url: nil, type: .folder, parentId: nil, mtime: Date())
        
        // 3. Nested empty folder structure
        let f3 = BookmarkNode(id: "bookmark_bar:folder3", title: "Folder 3", url: nil, type: .folder, parentId: nil, mtime: Date())
        let f4 = BookmarkNode(id: "bookmark_bar:folder4", title: "Folder 4", url: nil, type: .folder, parentId: "bookmark_bar:folder3", mtime: Date())
        
        let browsers: [[BookmarkNode]] = [
            [f1, b1, f2, f3, f4]
        ]
        
        let c1 = BrowserConfig(id: "c1", bundleId: "com.apple.Safari", browserName: "Safari", profileName: "Default", bookmarkFilePath: "")
        
        let (merged, _) = engine.merge(state: [], browsers: browsers, activeConfigs: [c1])
        
        // Validate:
        // f1 and b1 should remain
        // f2, f3, and f4 should be removed because they are empty or contain only other empty folders
        let ids = Set(merged.map { $0.id })
        
        XCTAssertTrue(ids.contains("bookmark_bar:folder1"))
        XCTAssertTrue(ids.contains("bookmark_bar:https://google.com"))
        
        XCTAssertFalse(ids.contains("bookmark_bar:folder2"))
        XCTAssertFalse(ids.contains("bookmark_bar:folder3"))
        XCTAssertFalse(ids.contains("bookmark_bar:folder4"))
        
        XCTAssertEqual(merged.count, 2)
    }
    
    @MainActor
    func testNewlyEnabledProfileImports() throws {
        let schema = Schema([BookmarkNode.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        
        let viewModel = AppViewModel()
        let engine = SyncEngine(modelContext: container.mainContext, viewModel: viewModel)
        
        // Unified state has Google and Apple
        let b1 = BookmarkNode(id: "bookmark_bar:https://google.com", title: "Google", url: "https://google.com", type: .leaf, mtime: Date())
        let b2 = BookmarkNode(id: "bookmark_bar:https://apple.com", title: "Apple", url: "https://apple.com", type: .leaf, mtime: Date())
        let state: [BookmarkNode] = [b1, b2]
        
        // Newly enabled chrome profile:
        // - Missing "Google" (would be a delete if it wasn't newly enabled)
        // - Renamed "Apple" -> "Apple Inc" (would be an update if it wasn't newly enabled)
        // - Added new link "GitHub" (newly seen)
        let chromeApple = BookmarkNode(id: "bookmark_bar:https://apple.com", title: "Apple Inc", url: "https://apple.com", type: .leaf, mtime: Date())
        let chromeGitHub = BookmarkNode(id: "bookmark_bar:https://github.com", title: "GitHub", url: "https://github.com", type: .leaf, mtime: Date())
        let chrome: [BookmarkNode] = [chromeApple, chromeGitHub]
        
        let c1 = BrowserConfig(id: "c1", bundleId: "com.google.Chrome", browserName: "Google Chrome", profileName: "Synctest", bookmarkFilePath: "")
        c1.lastSyncTime = nil // newly enabled!
        
        let (merged, _) = engine.merge(
            state: state,
            browsers: [chrome],
            activeConfigs: [c1],
            initialSyncMap: ["c1": true]
        )
        
        // Assert:
        // 1. Google must NOT be deleted!
        XCTAssertTrue(merged.contains(where: { $0.id == "bookmark_bar:https://google.com" && $0.title == "Google" }))
        
        // 2. Apple must NOT be updated to "Apple Inc"!
        XCTAssertTrue(merged.contains(where: { $0.id == "bookmark_bar:https://apple.com" && $0.title == "Apple" }))
        XCTAssertFalse(merged.contains(where: { $0.title == "Apple Inc" }))
        
        // 3. GitHub must be added!
        XCTAssertTrue(merged.contains(where: { $0.id == "bookmark_bar:https://github.com" && $0.title == "GitHub" }))
        
        // 4. Total count should be 3 (Google, Apple, GitHub)
        XCTAssertEqual(merged.count, 3)
    }
}




// MARK: - BookmarkTreeSnapshot (UI projection)

final class BookmarkTreeSnapshotTests: XCTestCase {

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([BookmarkNode.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    }

    @MainActor
    func testBuildsHierarchyAndRoots() throws {
        let setId = "S1"
        let folder = BookmarkNode(id: "\(setId):bookmark_bar:Dev", title: "Dev", type: .folder, mtime: Date(), profileSetId: setId, index: 0)
        let leafIn = BookmarkNode(id: "\(setId):bookmark_bar:Dev:a", title: "Apple", url: "https://apple.com", type: .leaf, parentId: folder.id, mtime: Date(), profileSetId: setId, index: 0)
        let leafRoot = BookmarkNode(id: "\(setId):bookmark_bar:g", title: "Google", url: "https://google.com", type: .leaf, mtime: Date(), profileSetId: setId, index: 1)

        let snap = BookmarkTreeSnapshot(nodes: [folder, leafIn, leafRoot], profileSetFilter: setId)

        XCTAssertEqual(snap.items.count, 3)
        XCTAssertEqual(snap.roots.map { $0.id }, [folder.id, leafRoot.id])
        XCTAssertEqual(snap.children(of: folder.id).map { $0.id }, [leafIn.id])
        XCTAssertTrue(snap.hasChildren(folder.id))
        XCTAssertFalse(snap.hasChildren(leafRoot.id))
    }

    @MainActor
    func testProfileSetFilterExcludesOtherSets() throws {
        let a = BookmarkNode(id: "A:bookmark_bar:x", title: "X", url: "https://x.com", type: .leaf, mtime: Date(), profileSetId: "A", index: 0)
        let b = BookmarkNode(id: "B:bookmark_bar:y", title: "Y", url: "https://y.com", type: .leaf, mtime: Date(), profileSetId: "B", index: 0)

        let snap = BookmarkTreeSnapshot(nodes: [a, b], profileSetFilter: "A")

        XCTAssertEqual(snap.items.map { $0.id }, [a.id])
    }

    @MainActor
    func testGlobalViewMergesSetsByStrippedIdKeepingNewest() throws {
        let old = Date(timeIntervalSince1970: 1_000)
        let recent = Date(timeIntervalSince1970: 2_000)

        // Same logical bookmark present in two profile sets.
        let inA = BookmarkNode(id: "A:bookmark_bar:g", title: "Google Old", url: "https://google.com", type: .leaf, mtime: old, profileSetId: "A", index: 0)
        let inB = BookmarkNode(id: "B:bookmark_bar:g", title: "Google New", url: "https://google.com", type: .leaf, mtime: recent, profileSetId: "B", index: 0)

        let snap = BookmarkTreeSnapshot(nodes: [inA, inB], profileSetFilter: nil)

        XCTAssertEqual(snap.items.count, 1, "Both sets collapse into one global row")
        XCTAssertEqual(snap.items.first?.id, "bookmark_bar:g", "Global ids are prefix-stripped")
        XCTAssertEqual(snap.items.first?.title, "Google New", "Newest mtime wins")
    }

    @MainActor
    func testGlobalViewStripsParentIdsSoHierarchySurvives() throws {
        let setId = "A"
        let folder = BookmarkNode(id: "\(setId):bookmark_bar:Dev", title: "Dev", type: .folder, mtime: Date(), profileSetId: setId, index: 0)
        let leaf = BookmarkNode(id: "\(setId):bookmark_bar:Dev:a", title: "Apple", url: "https://apple.com", type: .leaf, parentId: folder.id, mtime: Date(), profileSetId: setId, index: 0)

        let snap = BookmarkTreeSnapshot(nodes: [folder, leaf], profileSetFilter: nil)

        XCTAssertEqual(snap.roots.map { $0.id }, ["bookmark_bar:Dev"], "Folder is the only root")
        XCTAssertEqual(snap.children(of: "bookmark_bar:Dev").map { $0.id }, ["bookmark_bar:Dev:a"])
    }

    @MainActor
    func testOrphanWithMissingParentIsTreatedAsRoot() throws {
        let setId = "A"
        let orphan = BookmarkNode(id: "\(setId):bookmark_bar:orphan", title: "Orphan", url: "https://o.com", type: .leaf, parentId: "\(setId):bookmark_bar:ghost", mtime: Date(), profileSetId: setId, index: 0)

        let snap = BookmarkTreeSnapshot(nodes: [orphan], profileSetFilter: setId)

        XCTAssertEqual(snap.roots.map { $0.id }, [orphan.id], "Node whose parent is absent must stay reachable")
    }

    @MainActor
    func testSiblingOrderingIndexThenFolderThenTitle() throws {
        let setId = "A"
        let now = Date()
        // Equal index: folders sort before leaves, then by title.
        let leafB = BookmarkNode(id: "\(setId):bookmark_bar:b", title: "Bravo", url: "https://b.com", type: .leaf, mtime: now, profileSetId: setId, index: 0)
        let folderA = BookmarkNode(id: "\(setId):bookmark_bar:A", title: "Alpha", type: .folder, mtime: now, profileSetId: setId, index: 0)
        let trash = BookmarkNode(id: "\(setId):bookmark_bar:trash", title: "Deleted by BookmarkSync", type: .folder, mtime: now, profileSetId: setId, index: 0)
        let leafLater = BookmarkNode(id: "\(setId):bookmark_bar:z", title: "Zulu", url: "https://z.com", type: .leaf, mtime: now, profileSetId: setId, index: 5)

        let snap = BookmarkTreeSnapshot(nodes: [trash, leafB, leafLater, folderA], profileSetFilter: setId)

        XCTAssertEqual(
            snap.roots.map { $0.title },
            ["Alpha", "Bravo", "Zulu", "Deleted by BookmarkSync"],
            "Folder-before-leaf at equal index, index ordering respected, trash folder last"
        )
    }

    @MainActor
    func testFlattenVisibleRespectsExpansionAndDepth() throws {
        let setId = "A"
        let outer = BookmarkNode(id: "\(setId):bookmark_bar:Outer", title: "Outer", type: .folder, mtime: Date(), profileSetId: setId, index: 0)
        let inner = BookmarkNode(id: "\(setId):bookmark_bar:Outer:Inner", title: "Inner", type: .folder, parentId: outer.id, mtime: Date(), profileSetId: setId, index: 0)
        let deep = BookmarkNode(id: "\(setId):bookmark_bar:Outer:Inner:leaf", title: "Deep", url: "https://d.com", type: .leaf, parentId: inner.id, mtime: Date(), profileSetId: setId, index: 0)

        let snap = BookmarkTreeSnapshot(nodes: [outer, inner, deep], profileSetFilter: setId)

        XCTAssertEqual(snap.flattenVisible(expandedIds: []).map { $0.item.title }, ["Outer"])

        let oneLevel = snap.flattenVisible(expandedIds: [outer.id])
        XCTAssertEqual(oneLevel.map { $0.item.title }, ["Outer", "Inner"])
        XCTAssertEqual(oneLevel.map { $0.depth }, [0, 1])
        XCTAssertTrue(oneLevel[1].hasChildren)

        let twoLevels = snap.flattenVisible(expandedIds: [outer.id, inner.id])
        XCTAssertEqual(twoLevels.map { $0.item.title }, ["Outer", "Inner", "Deep"])
        XCTAssertEqual(twoLevels.map { $0.depth }, [0, 1, 2])
    }

    @MainActor
    func testBreadcrumbsAndPath() throws {
        let setId = "A"
        let outer = BookmarkNode(id: "\(setId):bookmark_bar:Outer", title: "Outer", type: .folder, mtime: Date(), profileSetId: setId, index: 0)
        let inner = BookmarkNode(id: "\(setId):bookmark_bar:Outer:Inner", title: "Inner", type: .folder, parentId: outer.id, mtime: Date(), profileSetId: setId, index: 0)
        let deep = BookmarkNode(id: "\(setId):bookmark_bar:Outer:Inner:leaf", title: "Deep", url: "https://d.com", type: .leaf, parentId: inner.id, mtime: Date(), profileSetId: setId, index: 0)

        let snap = BookmarkTreeSnapshot(nodes: [outer, inner, deep], profileSetFilter: setId)

        XCTAssertEqual(snap.breadcrumbs(for: deep.id).map { $0.title }, ["Outer", "Inner"])
        XCTAssertEqual(snap.breadcrumbPath(for: deep.id), "Outer > Inner")
        XCTAssertEqual(snap.breadcrumbPath(for: outer.id), "Root", "A root node reports Root")
    }

    @MainActor
    func testBreadcrumbsTerminatesOnParentCycle() throws {
        let setId = "A"
        // A malformed store could contain a parent cycle; the walk must not hang.
        let x = BookmarkNode(id: "\(setId):bookmark_bar:x", title: "X", type: .folder, parentId: "\(setId):bookmark_bar:y", mtime: Date(), profileSetId: setId, index: 0)
        let y = BookmarkNode(id: "\(setId):bookmark_bar:y", title: "Y", type: .folder, parentId: "\(setId):bookmark_bar:x", mtime: Date(), profileSetId: setId, index: 0)

        let snap = BookmarkTreeSnapshot(nodes: [x, y], profileSetFilter: setId)

        XCTAssertLessThanOrEqual(snap.breadcrumbs(for: x.id).count, 512)
    }

    @MainActor
    func testSearchMatchesTitleAndURLCaseInsensitively() throws {
        let setId = "A"
        let g = BookmarkNode(id: "\(setId):bookmark_bar:g", title: "Google Search", url: "https://google.com", type: .leaf, mtime: Date(), profileSetId: setId, index: 0)
        let a = BookmarkNode(id: "\(setId):bookmark_bar:a", title: "Apple", url: "https://apple.com/store", type: .leaf, mtime: Date(), profileSetId: setId, index: 1)

        let snap = BookmarkTreeSnapshot(nodes: [g, a], profileSetFilter: setId)

        XCTAssertEqual(snap.search(query: "GOOGLE").map { $0.id }, [g.id], "Title match ignores case")
        XCTAssertEqual(snap.search(query: "apple.com/store").map { $0.id }, [a.id], "URL substring matches")
        XCTAssertEqual(snap.search(query: "  ").count, 2, "Blank query returns everything")
        XCTAssertTrue(snap.search(query: "nonexistent").isEmpty)
    }

    @MainActor
    func testFolderIdsOnlyReturnsFolders() throws {
        let setId = "A"
        let folder = BookmarkNode(id: "\(setId):bookmark_bar:F", title: "F", type: .folder, mtime: Date(), profileSetId: setId, index: 0)
        let leaf = BookmarkNode(id: "\(setId):bookmark_bar:l", title: "L", url: "https://l.com", type: .leaf, mtime: Date(), profileSetId: setId, index: 1)

        let snap = BookmarkTreeSnapshot(nodes: [folder, leaf], profileSetFilter: setId)

        XCTAssertEqual(snap.folderIds, [folder.id])
    }

    @MainActor
    func testEmptySnapshot() throws {
        XCTAssertTrue(BookmarkTreeSnapshot.empty.isEmpty)
        XCTAssertTrue(BookmarkTreeSnapshot(nodes: [], profileSetFilter: nil).isEmpty)
        XCTAssertNil(BookmarkTreeSnapshot.empty.item(id: nil))
    }

    /// Guards the regression this refactor addressed: building the projection and
    /// flattening a fully expanded 3k-node tree must be far cheaper than the old
    /// per-frame rebuild, which allocated thousands of `@Model` objects.
    @MainActor
    func testLargeTreePerformanceBudget() throws {
        let setId = "A"
        var nodes: [BookmarkNode] = []
        let now = Date()
        // 30 folders x 100 leaves = 3030 nodes, the reported problem size.
        for f in 0..<30 {
            let folderId = "\(setId):bookmark_bar:F\(f)"
            nodes.append(BookmarkNode(id: folderId, title: "Folder \(f)", type: .folder, mtime: now, profileSetId: setId, index: f))
            for l in 0..<100 {
                nodes.append(BookmarkNode(
                    id: "\(folderId):l\(l)",
                    title: "Leaf \(f)-\(l)",
                    url: "https://example.com/\(f)/\(l)",
                    type: .leaf,
                    parentId: folderId,
                    mtime: now,
                    profileSetId: setId,
                    index: l
                ))
            }
        }

        let start = Date()
        let snap = BookmarkTreeSnapshot(nodes: nodes, profileSetFilter: setId)
        let allExpanded = Set(snap.folderIds)
        let rows = snap.flattenVisible(expandedIds: allExpanded)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(snap.items.count, 3030)
        XCTAssertEqual(rows.count, 3030, "Every node is visible when all folders are expanded")
        XCTAssertLessThan(elapsed, 1.0, "Snapshot build + flatten for 3k nodes took \(elapsed)s")
    }
}

// MARK: - BookmarkChildIndex (writer sibling grouping)

final class BookmarkChildIndexTests: XCTestCase {

    private func node(_ id: String, parent: String? = nil, index: Int, type: BookmarkType = .leaf) -> ParsedBookmark {
        ParsedBookmark(
            id: id,
            title: id,
            url: type == .leaf ? "https://example.com/\(id)" : nil,
            type: type,
            parentId: parent,
            mtime: Date(),
            index: index
        )
    }

    func testRootsAreBucketedByPrefixAndSortedByIndex() {
        let nodes = [
            node("bookmark_bar:b", index: 1),
            node("bookmark_bar:a", index: 0),
            node("other:x", index: 0),
        ]
        let idx = BookmarkChildIndex(strippedNodes: nodes)

        XCTAssertEqual(idx.children(prefix: "bookmark_bar", parentId: nil).map { $0.id },
                       ["bookmark_bar:a", "bookmark_bar:b"])
        XCTAssertEqual(idx.children(prefix: "other", parentId: nil).map { $0.id }, ["other:x"])
        XCTAssertTrue(idx.children(prefix: "synced", parentId: nil).isEmpty)
    }

    func testChildrenSortedByIndex() {
        let folder = "bookmark_bar:F"
        let nodes = [
            node(folder, index: 0, type: .folder),
            node("\(folder):third", parent: folder, index: 2),
            node("\(folder):first", parent: folder, index: 0),
            node("\(folder):second", parent: folder, index: 1),
        ]
        let idx = BookmarkChildIndex(strippedNodes: nodes)

        XCTAssertEqual(
            idx.children(prefix: "bookmark_bar", parentId: folder).map { $0.id },
            ["\(folder):first", "\(folder):second", "\(folder):third"]
        )
    }

    /// The index must preserve the original predicate's prefix scoping: a child
    /// is only written under the root tree whose prefix its id carries.
    func testChildrenAreScopedByRootPrefix() {
        let nodes = [
            node("bookmark_bar:F", index: 0, type: .folder),
            node("bookmark_bar:F:in", parent: "bookmark_bar:F", index: 0),
            // Same parent id, but belongs to a different root tree.
            node("other:F:foreign", parent: "bookmark_bar:F", index: 1),
        ]
        let idx = BookmarkChildIndex(strippedNodes: nodes)

        XCTAssertEqual(idx.children(prefix: "bookmark_bar", parentId: "bookmark_bar:F").map { $0.id },
                       ["bookmark_bar:F:in"])
        XCTAssertEqual(idx.children(prefix: "other", parentId: "bookmark_bar:F").map { $0.id },
                       ["other:F:foreign"])
    }

    func testEmptyParentIdIsTreatedAsRoot() {
        let nodes = [node("bookmark_bar:a", parent: "", index: 0)]
        let idx = BookmarkChildIndex(strippedNodes: nodes)

        XCTAssertEqual(idx.children(prefix: "bookmark_bar", parentId: nil).map { $0.id }, ["bookmark_bar:a"])
        XCTAssertEqual(idx.children(prefix: "bookmark_bar", parentId: "").map { $0.id }, ["bookmark_bar:a"])
    }

    func testUnknownParentReturnsEmpty() {
        let idx = BookmarkChildIndex(strippedNodes: [node("bookmark_bar:a", index: 0)])
        XCTAssertTrue(idx.children(prefix: "bookmark_bar", parentId: "bookmark_bar:ghost").isEmpty)
    }

    /// Equivalence check against the linear predicate the writers used before,
    /// over a tree large enough that the old form was the write bottleneck.
    func testMatchesLegacyFilterPredicateOnLargeTree() {
        var nodes: [ParsedBookmark] = []
        for f in 0..<30 {
            let folderId = "bookmark_bar:F\(f)"
            nodes.append(node(folderId, index: f, type: .folder))
            for l in 0..<100 {
                nodes.append(node("\(folderId):l\(l)", parent: folderId, index: l))
            }
        }

        let idx = BookmarkChildIndex(strippedNodes: nodes)

        func legacy(prefix: String, parentId: String?) -> [ParsedBookmark] {
            nodes.filter { $0.id.starts(with: prefix + ":") && $0.parentId == parentId }
                .sorted(by: { $0.index < $1.index })
        }

        XCTAssertEqual(
            idx.children(prefix: "bookmark_bar", parentId: nil).map { $0.id },
            legacy(prefix: "bookmark_bar", parentId: nil).map { $0.id },
            "Root ordering must match the legacy predicate"
        )

        for f in 0..<30 {
            let folderId = "bookmark_bar:F\(f)"
            XCTAssertEqual(
                idx.children(prefix: "bookmark_bar", parentId: folderId).map { $0.id },
                legacy(prefix: "bookmark_bar", parentId: folderId).map { $0.id },
                "Children of \(folderId) must match the legacy predicate"
            )
        }
    }
}

// MARK: - Activity feed batching

final class DiffBatchingTests: XCTestCase {

    /// Every change gets its own row: no sampling, no summary placeholder.
    @MainActor
    func testEveryChangeGetsItsOwnRow() {
        let viewModel = AppViewModel()
        let titles = (0..<3000).map { "Add: Bookmark \($0)" }

        viewModel.addDiffs(
            titles: titles,
            targetBundleId: "com.google.Chrome",
            targetProfileName: "Default",
            profileSetId: "S1"
        )

        XCTAssertEqual(viewModel.diffHistory.count, 3000)
        XCTAssertFalse(
            viewModel.diffHistory.contains { $0.bookmarkTitle.hasPrefix("+") },
            "No summary placeholder rows"
        )
        XCTAssertEqual(viewModel.diffHistory.first?.bookmarkTitle, "Add: Bookmark 0")
    }

    /// The reported bug: repeated syncs must not keep appending rows for state
    /// that is already pending.
    @MainActor
    func testRepeatedSyncDoesNotGrowTheFeed() {
        let viewModel = AppViewModel()
        let titles = (0..<50).map { "Add: Bookmark \($0)" }

        for _ in 0..<5 {
            viewModel.addDiffs(
                titles: titles,
                targetBundleId: "com.google.Chrome",
                targetProfileName: "Default",
                profileSetId: "S1"
            )
        }

        XCTAssertEqual(viewModel.diffHistory.count, 50, "Re-syncing the same changes adds nothing")
    }

    @MainActor
    func testHistoryIsCapped() {
        let viewModel = AppViewModel()

        // More distinct changes than the cap allows, across several syncs.
        for batch in 0..<60 {
            let titles = (0..<100).map { "Add: B\(batch)-\($0)" }
            viewModel.addDiffs(
                titles: titles,
                targetBundleId: "com.google.Chrome",
                targetProfileName: "Default",
                profileSetId: "S1"
            )
        }

        XCTAssertEqual(viewModel.diffHistory.count, AppViewModel.diffHistoryLimit)
        XCTAssertEqual(viewModel.diffHistory.first?.bookmarkTitle, "Add: B59-0", "Most recent batch stays at the top")
    }

    @MainActor
    func testDuplicateTitlesAreNotRecordedTwiceForSameTarget() {
        let viewModel = AppViewModel()

        for _ in 0..<3 {
            viewModel.addDiffs(
                titles: ["Add: Same"],
                targetBundleId: "com.google.Chrome",
                targetProfileName: "Default",
                profileSetId: "S1"
            )
        }

        XCTAssertEqual(viewModel.diffHistory.count, 1)
    }

    @MainActor
    func testBatchedCancelRemovesMatchingWaitingDiffs() {
        let viewModel = AppViewModel()

        viewModel.addDiffs(
            titles: ["Add: Keep", "Update: Drop", "Delete: AlsoDrop"],
            targetBundleId: "com.google.Chrome",
            targetProfileName: "Default",
            profileSetId: "S1"
        )

        // Cancellation matches on the bare bookmark title, ignoring the
        // Add:/Update:/Delete: verb prefix.
        viewModel.cancelPendingDiffs(forTitles: ["Drop", "AlsoDrop"])

        XCTAssertEqual(viewModel.diffHistory.map { $0.bookmarkTitle }, ["Add: Keep"])
    }

    @MainActor
    func testConcreteChangeSupersedesPendingReorder() {
        let viewModel = AppViewModel()

        viewModel.addDiff(DiffRecord(
            bookmarkTitle: "Reorder",
            sourceBundleIds: ["System"],
            targetBundleIds: ["com.google.Chrome"],
            sourceProfileNames: ["System"],
            targetProfileNames: ["Default"],
            isWaiting: true,
            profileSetId: "S1"
        ))
        XCTAssertEqual(viewModel.diffHistory.count, 1)

        viewModel.addDiffs(
            titles: ["Add: Real"],
            targetBundleId: "com.google.Chrome",
            targetProfileName: "Default",
            profileSetId: "S1"
        )

        XCTAssertEqual(viewModel.diffHistory.map { $0.bookmarkTitle }, ["Add: Real"],
                       "A concrete change replaces the pending Reorder for that target")
    }
}

// MARK: - End-to-end sync (async read path)

final class SyncEngineIntegrationTests: XCTestCase {

    /// Writes a minimal Chrome bookmarks file with `count` bookmarks on the bar.
    private func writeChromeFixture(count: Int) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("Bookmarks_\(UUID().uuidString)")

        let children = (0..<count).map { i -> [String: Any] in
            [
                "id": "\(100 + i)",
                "name": "Bookmark \(i)",
                "type": "url",
                "url": "https://example.com/\(i)",
                "date_added": "13000000000000000",
                "date_modified": "13000000000000000",
            ]
        }
        let root: [String: Any] = [
            "version": 1,
            "checksum": "abc",
            "roots": [
                "bookmark_bar": ["id": "1", "name": "Bookmarks bar", "type": "folder", "date_added": "13000000000000000", "children": children],
                "other": ["id": "2", "name": "Other", "type": "folder", "date_added": "13000000000000000", "children": []],
                "synced": ["id": "3", "name": "Synced", "type": "folder", "date_added": "13000000000000000", "children": []],
            ],
        ]
        try JSONSerialization.data(withJSONObject: root, options: []).write(to: url)
        return url
    }

    /// Drives a full sync through the real async read path and asserts the hub
    /// ends up populated. Guards the restructure that moved parsing off the main
    /// actor: a regression there shows up as an empty or partial import.
    @MainActor
    func testSyncImportsBookmarksThroughAsyncReadPath() async throws {
        let fixture = try writeChromeFixture(count: 250)
        defer { try? FileManager.default.removeItem(at: fixture) }

        let schema = Schema([BookmarkNode.self, BrowserConfig.self, ProfileSet.self])
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext

        let profileSet = ProfileSet(name: "Set 1")
        context.insert(profileSet)

        let config = BrowserConfig(
            id: "com.google.Chrome:Default",
            bundleId: "com.google.Chrome",
            browserName: "Google Chrome",
            profileName: "Default",
            bookmarkFilePath: fixture.path,
            isEnabled: true,
            profileSetId: profileSet.id
        )
        context.insert(config)
        try context.save()

        let viewModel = AppViewModel()
        viewModel.modelContext = context
        // Keep the test off the real filesystem for writes.
        viewModel.syncState = .readOnly

        let engine = SyncEngine(modelContext: context, viewModel: viewModel)
        viewModel.syncEngine = engine

        engine.triggerSync(changedPaths: [], forceImmediate: true)

        // The read happens in a detached task; wait for the hub to populate.
        let imported = try await waitForNodes(in: context, timeout: 5.0)

        XCTAssertEqual(imported, 250, "All fixture bookmarks should reach the hub")

        let nodes = try context.fetch(FetchDescriptor<BookmarkNode>())
        XCTAssertTrue(
            nodes.allSatisfy { $0.profileSetId == profileSet.id },
            "Imported nodes must be namespaced to the profile set"
        )
        XCTAssertTrue(
            nodes.allSatisfy { $0.id.hasPrefix("\(profileSet.id):") },
            "Ids must carry the profile-set prefix applied during the background read"
        )
    }

    /// A sync requested while one is in flight must still run, not be dropped.
    @MainActor
    func testOverlappingSyncRequestIsHonoured() async throws {
        let fixture = try writeChromeFixture(count: 10)
        defer { try? FileManager.default.removeItem(at: fixture) }

        let schema = Schema([BookmarkNode.self, BrowserConfig.self, ProfileSet.self])
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext

        let profileSet = ProfileSet(name: "Set 1")
        context.insert(profileSet)
        let config = BrowserConfig(
            id: "com.google.Chrome:Default",
            bundleId: "com.google.Chrome",
            browserName: "Google Chrome",
            profileName: "Default",
            bookmarkFilePath: fixture.path,
            isEnabled: true,
            profileSetId: profileSet.id
        )
        context.insert(config)
        try context.save()

        let viewModel = AppViewModel()
        viewModel.modelContext = context
        viewModel.syncState = .readOnly
        let engine = SyncEngine(modelContext: context, viewModel: viewModel)
        viewModel.syncEngine = engine

        // Second call lands while the first is still reading, with no paths --
        // exactly the shape of a "force immediate" rescan.
        engine.triggerSync(changedPaths: [], forceImmediate: true)
        engine.triggerSync(changedPaths: [], forceImmediate: true)

        let imported = try await waitForNodes(in: context, timeout: 5.0)
        XCTAssertEqual(imported, 10)
        XCTAssertFalse(engine.hasPendingSync, "The coalesced request must be drained, not left pending")
    }

    private func waitForNodes(
        in context: ModelContext,
        timeout: TimeInterval
    ) async throws -> Int {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let count = try context.fetch(FetchDescriptor<BookmarkNode>()).count
            if count > 0 { return count }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        return try context.fetch(FetchDescriptor<BookmarkNode>()).count
    }
}
