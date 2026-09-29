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

// MARK: - Deletion tombstoning (probe)

final class ChromeDeletionProbeTests: XCTestCase {

    private func fixture(bar: [(String, String)], synced: [(String, String)] = []) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("Bookmarks_\(UUID().uuidString)")
        func kids(_ items: [(String, String)], from: Int) -> [[String: Any]] {
            items.enumerated().map { i, it in
                ["id": "\(from + i)", "name": it.0, "type": "url", "url": it.1,
                 "date_added": "13000000000000000", "date_modified": "13000000000000000"]
            }
        }
        let root: [String: Any] = [
            "version": 1, "checksum": "abc",
            "roots": [
                "bookmark_bar": ["id": "1", "name": "Bar", "type": "folder", "date_added": "13000000000000000", "children": kids(bar, from: 100)],
                "other": ["id": "2", "name": "Other", "type": "folder", "date_added": "13000000000000000", "children": []],
                "synced": ["id": "3", "name": "Synced", "type": "folder", "date_added": "13000000000000000", "children": kids(synced, from: 500)],
            ],
        ]
        try JSONSerialization.data(withJSONObject: root, options: []).write(to: url)
        return url
    }

    private func deletedFolderChildren(_ url: URL) throws -> [String] {
        let json = try JSONSerialization.jsonObject(with: try Data(contentsOf: url)) as! [String: Any]
        let roots = json["roots"] as! [String: Any]
        let other = roots["other"] as! [String: Any]
        let children = other["children"] as? [[String: Any]] ?? []
        guard let folder = children.first(where: { ($0["name"] as? String) == "Deleted by BookmarkSync" }),
              let kids = folder["children"] as? [[String: Any]] else { return [] }
        return kids.compactMap { $0["name"] as? String }
    }

    private func syncedChildren(_ url: URL) throws -> [String] {
        let json = try JSONSerialization.jsonObject(with: try Data(contentsOf: url)) as! [String: Any]
        let roots = json["roots"] as! [String: Any]
        let synced = roots["synced"] as! [String: Any]
        return (synced["children"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
    }

    /// Removing a bookmark from the written tree should tombstone it.
    func testRemovedBookmarkIsMovedToDeletedFolder() throws {
        let url = try fixture(bar: [("Keep", "https://keep.com"), ("Gone", "https://gone.com")])
        defer { try? FileManager.default.removeItem(at: url) }

        let parser = ChromeParser(filePath: url)
        let all = try parser.read()
        let survivors = all.filter { $0.title != "Gone" }
        try parser.write(nodes: survivors)

        XCTAssertEqual(try deletedFolderChildren(url), ["Gone"])
    }

    /// Synced-folder bookmarks must not be treated as deleted.
    func testSyncedBookmarksAreNotFalselyTombstoned() throws {
        let url = try fixture(
            bar: [("Keep", "https://keep.com")],
            synced: [("Mobile", "https://mobile.com")]
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let parser = ChromeParser(filePath: url)
        let all = try parser.read()
        try parser.write(nodes: all)   // nothing removed

        XCTAssertEqual(try syncedChildren(url), ["Mobile"], "Synced bookmark stays in synced")
        XCTAssertEqual(try deletedFolderChildren(url), [], "Nothing was deleted, so no tombstones")
    }

    /// Repeated identical writes must not accumulate tombstones.
    func testRepeatedWritesDoNotAccumulateTombstones() throws {
        let url = try fixture(
            bar: [("Keep", "https://keep.com")],
            synced: [("Mobile", "https://mobile.com")]
        )
        defer { try? FileManager.default.removeItem(at: url) }

        for _ in 0..<3 {
            let parser = ChromeParser(filePath: url)
            let all = try parser.read()
            try parser.write(nodes: all)
        }

        XCTAssertEqual(try deletedFolderChildren(url), [])
    }

    /// The resurrection half of the report: once a bookmark is tombstoned, a
    /// subsequent read must not surface it as a live bookmark again.
    func testTombstonedBookmarkIsNotReadBackAsLive() throws {
        let url = try fixture(bar: [("Keep", "https://keep.com"), ("Gone", "https://gone.com")])
        defer { try? FileManager.default.removeItem(at: url) }

        let parser = ChromeParser(filePath: url)
        let survivors = try parser.read().filter { $0.title != "Gone" }
        try parser.write(nodes: survivors)

        XCTAssertEqual(try deletedFolderChildren(url), ["Gone"], "Precondition: it was tombstoned")

        let reread = try parser.read()
        XCTAssertFalse(
            reread.contains { $0.title == "Gone" },
            "A tombstoned bookmark must not reappear as live on re-read"
        )
        XCTAssertEqual(reread.map { $0.title }, ["Keep"])
    }

    /// A tombstoned bookmark must survive later writes rather than being dropped
    /// (which would let a browser's cloud sync push it back).
    func testTombstoneSurvivesSubsequentWrites() throws {
        let url = try fixture(bar: [("Keep", "https://keep.com"), ("Gone", "https://gone.com")])
        defer { try? FileManager.default.removeItem(at: url) }

        let parser = ChromeParser(filePath: url)
        try parser.write(nodes: try parser.read().filter { $0.title != "Gone" })
        XCTAssertEqual(try deletedFolderChildren(url), ["Gone"])

        // Two further no-op sync cycles.
        for _ in 0..<2 {
            try parser.write(nodes: try parser.read())
        }

        XCTAssertEqual(
            try deletedFolderChildren(url), ["Gone"],
            "The tombstone is retained exactly once, not dropped and not duplicated"
        )
    }
}

// MARK: - Safari deletion tombstoning

final class SafariDeletionTests: XCTestCase {

    private func fixture(bar: [(String, String)]) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SafariBookmarks_\(UUID().uuidString).plist")
        let kids: [[String: Any]] = bar.map { t, u in
            ["Title": t, "WebBookmarkType": "WebBookmarkTypeLeaf",
             "URLString": u, "WebBookmarkUUID": UUID().uuidString,
             "URIDictionary": ["title": t]]
        }
        let root: [String: Any] = [
            "Children": [
                ["Title": "BookmarksBar", "WebBookmarkType": "WebBookmarkTypeList", "WebBookmarkUUID": UUID().uuidString, "Children": kids],
                ["Title": "BookmarksMenu", "WebBookmarkType": "WebBookmarkTypeList", "WebBookmarkUUID": UUID().uuidString, "Children": [[String: Any]]()],
            ],
            "Title": "", "WebBookmarkFileVersion": 1,
            "WebBookmarkType": "WebBookmarkTypeList", "WebBookmarkUUID": "ROOT",
        ]
        try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0).write(to: url)
        return url
    }

    private func deletedFolderChildren(_ url: URL) throws -> [String] {
        let plist = try PropertyListSerialization.propertyList(
            from: try Data(contentsOf: url), options: [], format: nil
        ) as! [String: Any]
        let rootChildren = plist["Children"] as! [[String: Any]]
        guard let menu = rootChildren.first(where: { ($0["Title"] as? String) == "BookmarksMenu" }),
              let kids = menu["Children"] as? [[String: Any]],
              let folder = kids.first(where: { ($0["Title"] as? String) == "Deleted by BookmarkSync" }),
              let deleted = folder["Children"] as? [[String: Any]] else { return [] }
        return deleted.compactMap { $0["Title"] as? String }
    }

    func testRemovedBookmarkIsTombstoned() throws {
        let url = try fixture(bar: [("Keep", "https://keep.com"), ("Gone", "https://gone.com")])
        defer { try? FileManager.default.removeItem(at: url) }

        let parser = SafariParser(filePath: url)
        try parser.write(nodes: try parser.read().filter { $0.title != "Gone" })

        XCTAssertEqual(try deletedFolderChildren(url), ["Gone"])
    }

    func testNoOpWritesDoNotAccumulateTombstones() throws {
        let url = try fixture(bar: [("Keep", "https://keep.com")])
        defer { try? FileManager.default.removeItem(at: url) }

        let parser = SafariParser(filePath: url)
        for _ in 0..<3 {
            try parser.write(nodes: try parser.read())
        }

        XCTAssertEqual(try deletedFolderChildren(url), [], "Nothing deleted, so no tombstones")
    }

    func testTombstoneIsNotDuplicatedAcrossWrites() throws {
        let url = try fixture(bar: [("Keep", "https://keep.com"), ("Gone", "https://gone.com")])
        defer { try? FileManager.default.removeItem(at: url) }

        let parser = SafariParser(filePath: url)
        try parser.write(nodes: try parser.read().filter { $0.title != "Gone" })
        for _ in 0..<2 {
            try parser.write(nodes: try parser.read())
        }

        XCTAssertEqual(try deletedFolderChildren(url), ["Gone"], "Retained exactly once")
    }
}

// MARK: - Chrome identity preservation (probe)

final class ChromeIdentityProbeTests: XCTestCase {

    /// Fixture mimicking a real signed-in Chrome file: lowercase canonical
    /// guids, sync metadata, and a nested folder.
    private func fixture() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("Bookmarks_\(UUID().uuidString)")
        let bar: [[String: Any]] = [
            ["id": "100", "guid": "aaaaaaaa-1111-2222-3333-444444444444",
             "name": "Alpha", "type": "url", "url": "https://alpha.com",
             "date_added": "13000000000000000", "date_modified": "13000000000000000",
             "meta_info": ["last_visited": "13000000000000000"],
             "sync_transaction_version": "42"],
            ["id": "101", "guid": "bbbbbbbb-1111-2222-3333-444444444444",
             "name": "Folder", "type": "folder",
             "date_added": "13000000000000000", "date_modified": "13000000000000000",
             "children": [
                ["id": "102", "guid": "cccccccc-1111-2222-3333-444444444444",
                 "name": "Inner", "type": "url", "url": "https://inner.com",
                 "date_added": "13000000000000000", "date_modified": "13000000000000000"],
             ]],
        ]
        let root: [String: Any] = [
            "version": 1, "checksum": "deadbeef",
            "roots": [
                "bookmark_bar": ["id": "1", "guid": "00000000-0000-4000-a000-000000000002", "name": "Bar", "type": "folder", "date_added": "13000000000000000", "children": bar],
                "other": ["id": "2", "guid": "00000000-0000-4000-a000-000000000003", "name": "Other", "type": "folder", "date_added": "13000000000000000", "children": [[String: Any]]()],
                "synced": ["id": "3", "guid": "00000000-0000-4000-a000-000000000004", "name": "Synced", "type": "folder", "date_added": "13000000000000000", "children": [[String: Any]]()],
            ],
        ]
        try JSONSerialization.data(withJSONObject: root, options: []).write(to: url)
        return url
    }

    private func barNodes(_ url: URL) throws -> [[String: Any]] {
        let json = try JSONSerialization.jsonObject(with: try Data(contentsOf: url)) as! [String: Any]
        let roots = json["roots"] as! [String: Any]
        let bar = roots["bookmark_bar"] as! [String: Any]
        return bar["children"] as? [[String: Any]] ?? []
    }

    /// A no-op sync must not change any bookmark's guid: Chrome keys its cloud
    /// sync on guid, so a changed guid reads as a brand-new bookmark and the
    /// original comes back down from the cloud as a duplicate.
    func testNoOpWritePreservesGuids() throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }

        let before = try barNodes(url).compactMap { $0["guid"] as? String }
        let parser = ChromeParser(filePath: url)
        try parser.write(nodes: try parser.read())
        let after = try barNodes(url).compactMap { $0["guid"] as? String }

        XCTAssertEqual(after, before, "guids must survive a no-op write")
    }

    /// Guids Chrome writes are lowercase canonical UUIDs (verified against a real
    /// profile: 149/149 lowercase). An uppercase guid reads to Chrome as an
    /// unknown bookmark, so it keeps its cloud copy alongside ours -- the
    /// reported duplication.
    func testGeneratedGuidsAreLowercaseCanonical() throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }

        let parser = ChromeParser(filePath: url)
        var nodes = try parser.read()
        nodes.append(ParsedBookmark(
            id: "bookmark_bar:brandnew.com",
            title: "Brand New",
            url: "https://brandnew.com",
            type: .leaf,
            mtime: Date(),
            index: 99
        ))
        try parser.write(nodes: nodes)

        let guids = try barNodes(url).compactMap { $0["guid"] as? String }
        for guid in guids {
            XCTAssertEqual(guid, guid.lowercased(), "guid \(guid) must be lowercase")
            XCTAssertNotNil(UUID(uuidString: guid), "guid \(guid) must be a valid UUID")
        }
    }

    /// Round-tripping repeatedly must not multiply nodes. A `:dup1` id on read
    /// means the file itself gained a duplicate.
    func testRepeatedRoundTripsDoNotDuplicate() throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }

        let parser = ChromeParser(filePath: url)
        for _ in 0..<4 {
            try parser.write(nodes: try parser.read())
        }

        let ids = try parser.read().map { $0.id }
        XCTAssertFalse(ids.contains { $0.contains(":dup") }, "No duplicates: \(ids)")
        XCTAssertEqual(ids.count, 3, "Alpha, Folder, Inner -- got \(ids)")
    }

    /// Sync metadata Chrome attached to a node must be preserved.
    func testSyncMetadataIsPreserved() throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }

        let parser = ChromeParser(filePath: url)
        try parser.write(nodes: try parser.read())

        let alpha = try barNodes(url).first { ($0["name"] as? String) == "Alpha" }
        XCTAssertNotNil(alpha?["meta_info"], "meta_info must survive")
        XCTAssertEqual(alpha?["sync_transaction_version"] as? String, "42")
    }

    /// Guids an earlier build wrote in uppercase must be repaired on the next
    /// write, otherwise the duplication continues indefinitely.
    func testExistingUppercaseGuidIsRepaired() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("Bookmarks_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }

        let badGuid = "AAAAAAAA-1111-2222-3333-444444444444"
        let root: [String: Any] = [
            "version": 1,
            "roots": [
                "bookmark_bar": ["id": "1", "name": "Bar", "type": "folder", "date_added": "13000000000000000",
                                 "children": [["id": "100", "guid": badGuid, "name": "Alpha", "type": "url",
                                               "url": "https://alpha.com", "date_added": "13000000000000000"]]],
                "other": ["id": "2", "name": "Other", "type": "folder", "date_added": "13000000000000000", "children": [[String: Any]]()],
                "synced": ["id": "3", "name": "Synced", "type": "folder", "date_added": "13000000000000000", "children": [[String: Any]]()],
            ],
        ]
        try JSONSerialization.data(withJSONObject: root, options: []).write(to: url)

        let parser = ChromeParser(filePath: url)
        try parser.write(nodes: try parser.read())

        let json = try JSONSerialization.jsonObject(with: try Data(contentsOf: url)) as! [String: Any]
        let roots = json["roots"] as! [String: Any]
        let kids = ((roots["bookmark_bar"] as! [String: Any])["children"] as? [[String: Any]]) ?? []
        XCTAssertEqual(kids.first?["guid"] as? String, badGuid.lowercased(),
                       "An uppercase guid must be normalised, preserving the same UUID value")
    }
}

// MARK: - Chrome identity across real edits

final class ChromeEditIdentityTests: XCTestCase {

    private func fixture(_ bar: [[String: Any]]) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("Bookmarks_\(UUID().uuidString)")
        let root: [String: Any] = [
            "version": 1, "checksum": "deadbeef",
            "roots": [
                "bookmark_bar": ["id": "1", "guid": "00000000-0000-4000-a000-000000000002", "name": "Bar", "type": "folder", "date_added": "13000000000000000", "children": bar],
                "other": ["id": "2", "guid": "00000000-0000-4000-a000-000000000003", "name": "Other", "type": "folder", "date_added": "13000000000000000", "children": [[String: Any]]()],
                "synced": ["id": "3", "guid": "00000000-0000-4000-a000-000000000004", "name": "Synced", "type": "folder", "date_added": "13000000000000000", "children": [[String: Any]]()],
            ],
        ]
        try JSONSerialization.data(withJSONObject: root, options: []).write(to: url)
        return url
    }

    private func leaf(_ id: String, _ guid: String, _ name: String, _ url: String) -> [String: Any] {
        ["id": id, "guid": guid, "name": name, "type": "url", "url": url,
         "date_added": "13000000000000000", "date_modified": "13000000000000000"]
    }

    private func bar(_ url: URL) throws -> [[String: Any]] {
        let json = try JSONSerialization.jsonObject(with: try Data(contentsOf: url)) as! [String: Any]
        let roots = json["roots"] as! [String: Any]
        return ((roots["bookmark_bar"] as! [String: Any])["children"] as? [[String: Any]]) ?? []
    }

    /// RENAME. The node's identity (id/guid) must be carried over, because the
    /// engine's node id is derived from the URL and the title changed -- the
    /// original lookup key no longer matches.
    func testRenamePreservesGuid() throws {
        let url = try fixture([leaf("100", "aaaaaaaa-1111-2222-3333-444444444444", "Old Name", "https://site.com")])
        defer { try? FileManager.default.removeItem(at: url) }

        let parser = ChromeParser(filePath: url)
        let renamed = try parser.read().map {
            ParsedBookmark(id: $0.id, title: "New Name", url: $0.url, type: $0.type,
                           parentId: $0.parentId, mtime: $0.mtime, index: $0.index)
        }
        try parser.write(nodes: renamed)

        let nodes = try bar(url)
        XCTAssertEqual(nodes.count, 1)
        XCTAssertEqual(nodes.first?["name"] as? String, "New Name")
        XCTAssertEqual(nodes.first?["guid"] as? String, "aaaaaaaa-1111-2222-3333-444444444444",
                       "A rename must not mint a new guid -- Chrome would treat it as a new bookmark")
    }

    /// URL CHANGE. Same node, different URL: identity must still be preserved.
    func testUrlChangePreservesGuid() throws {
        let url = try fixture([leaf("100", "aaaaaaaa-1111-2222-3333-444444444444", "Site", "https://old.com")])
        defer { try? FileManager.default.removeItem(at: url) }

        let parser = ChromeParser(filePath: url)
        let original = try parser.read()
        let changed = original.map {
            ParsedBookmark(id: "bookmark_bar:new.com", title: $0.title, url: "https://new.com",
                           type: $0.type, parentId: $0.parentId, mtime: $0.mtime, index: $0.index)
        }
        try parser.write(nodes: changed)

        let nodes = try bar(url)
        XCTAssertEqual(nodes.count, 1, "Should be one node, not the old one plus a new one")
        XCTAssertEqual(nodes.first?["url"] as? String, "https://new.com")
    }

    /// REORDER. Moving bookmarks around must not disturb identity.
    func testReorderPreservesAllGuids() throws {
        let url = try fixture([
            leaf("100", "aaaaaaaa-1111-2222-3333-444444444444", "First", "https://one.com"),
            leaf("101", "bbbbbbbb-1111-2222-3333-444444444444", "Second", "https://two.com"),
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let parser = ChromeParser(filePath: url)
        let reversed = try parser.read().map {
            ParsedBookmark(id: $0.id, title: $0.title, url: $0.url, type: $0.type,
                           parentId: $0.parentId, mtime: $0.mtime,
                           index: $0.index == 0 ? 1 : 0)
        }
        try parser.write(nodes: reversed)

        let nodes = try bar(url)
        let guidByName = Dictionary(uniqueKeysWithValues: nodes.compactMap { n -> (String, String)? in
            guard let name = n["name"] as? String, let g = n["guid"] as? String else { return nil }
            return (name, g)
        })
        XCTAssertEqual(guidByName["First"], "aaaaaaaa-1111-2222-3333-444444444444")
        XCTAssertEqual(guidByName["Second"], "bbbbbbbb-1111-2222-3333-444444444444")
        XCTAssertEqual(nodes.first?["name"] as? String, "Second", "Order actually changed")
    }

    /// TWO BOOKMARKS, SAME URL, DIFFERENT TITLES -- a very common real-world
    /// shape. Each must keep its own identity.
    func testSameUrlDifferentTitlesKeepDistinctGuids() throws {
        let url = try fixture([
            leaf("100", "aaaaaaaa-1111-2222-3333-444444444444", "Docs Home", "https://example.com"),
            leaf("101", "bbbbbbbb-1111-2222-3333-444444444444", "Example", "https://example.com"),
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let parser = ChromeParser(filePath: url)
        let read = try parser.read()
        XCTAssertEqual(read.count, 2, "Both must be read: \(read.map(\.id))")

        try parser.write(nodes: read)

        let nodes = try bar(url)
        XCTAssertEqual(nodes.count, 2, "Both must survive the write")
        let guids = Set(nodes.compactMap { $0["guid"] as? String })
        XCTAssertEqual(guids.count, 2, "Distinct guids must stay distinct")
        XCTAssertEqual(
            guids,
            ["aaaaaaaa-1111-2222-3333-444444444444", "bbbbbbbb-1111-2222-3333-444444444444"],
            "Original guids must be preserved, not reassigned"
        )
    }
}

// MARK: - Safari UUID convention

final class SafariUuidConventionTests: XCTestCase {

    /// Safari's convention is the INVERSE of Chrome's: uppercase canonical,
    /// verified against a real Bookmarks.plist. Writing lowercase here would
    /// risk the same class of mismatch that Chrome's casing caused.
    func testGeneratedUuidsAreUppercase() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SafariBookmarks_\(UUID().uuidString).plist")
        defer { try? FileManager.default.removeItem(at: url) }

        let root: [String: Any] = [
            "Children": [
                ["Title": "BookmarksBar", "WebBookmarkType": "WebBookmarkTypeList", "WebBookmarkUUID": UUID().uuidString.uppercased(), "Children": [[String: Any]]()],
                ["Title": "BookmarksMenu", "WebBookmarkType": "WebBookmarkTypeList", "WebBookmarkUUID": UUID().uuidString.uppercased(), "Children": [[String: Any]]()],
            ],
            "Title": "", "WebBookmarkFileVersion": 1,
            "WebBookmarkType": "WebBookmarkTypeList", "WebBookmarkUUID": "ROOT",
        ]
        try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0).write(to: url)

        let parser = SafariParser(filePath: url)
        try parser.write(nodes: [
            ParsedBookmark(id: "bookmark_bar:new.com", title: "New", url: "https://new.com",
                           type: .leaf, mtime: Date(), index: 0)
        ])

        let plist = try PropertyListSerialization.propertyList(
            from: try Data(contentsOf: url), options: [], format: nil
        ) as! [String: Any]
        let rootChildren = plist["Children"] as! [[String: Any]]
        let bar = rootChildren.first { ($0["Title"] as? String) == "BookmarksBar" }!
        let kids = bar["Children"] as! [[String: Any]]
        let uuid = kids.first?["WebBookmarkUUID"] as? String

        XCTAssertNotNil(uuid)
        XCTAssertEqual(uuid, uuid?.uppercased(), "Safari UUIDs must be uppercase")
        XCTAssertNotNil(UUID(uuidString: uuid ?? ""), "Must be a valid canonical UUID")
    }
}

// MARK: - Chrome guid uniqueness

final class ChromeGuidUniquenessTests: XCTestCase {

    private func allGuids(_ url: URL) throws -> [String] {
        let json = try JSONSerialization.jsonObject(with: try Data(contentsOf: url)) as! [String: Any]
        let roots = json["roots"] as! [String: Any]
        var out: [String] = []
        func walk(_ n: [String: Any]) {
            if let g = n["guid"] as? String { out.append(g) }
            for c in (n["children"] as? [[String: Any]]) ?? [] { walk(c) }
        }
        for key in ["bookmark_bar", "other", "synced"] {
            if let r = roots[key] as? [String: Any] {
                for c in (r["children"] as? [[String: Any]]) ?? [] { walk(c) }
            }
        }
        return out
    }

    /// Two bookmarks sharing a URL must not end up sharing a guid. Chrome
    /// requires guids to be unique; a collision makes it discard or re-create
    /// nodes, which surfaces as duplication.
    func testTwoBookmarksSameUrlGetDistinctGuids() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("Bookmarks_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }

        // One original node; we will write TWO bookmarks with that same URL, so
        // the writer's URL-based fallback could hand both the same original.
        let root: [String: Any] = [
            "version": 1,
            "roots": [
                "bookmark_bar": ["id": "1", "name": "Bar", "type": "folder", "date_added": "13000000000000000",
                                 "children": [["id": "100", "guid": "aaaaaaaa-1111-2222-3333-444444444444",
                                               "name": "Only", "type": "url", "url": "https://same.com",
                                               "date_added": "13000000000000000"]]],
                "other": ["id": "2", "name": "Other", "type": "folder", "date_added": "13000000000000000", "children": [[String: Any]]()],
                "synced": ["id": "3", "name": "Synced", "type": "folder", "date_added": "13000000000000000", "children": [[String: Any]]()],
            ],
        ]
        try JSONSerialization.data(withJSONObject: root, options: []).write(to: url)

        let parser = ChromeParser(filePath: url)
        try parser.write(nodes: [
            ParsedBookmark(id: "bookmark_bar:same.com", title: "First", url: "https://same.com", type: .leaf, mtime: Date(), index: 0),
            ParsedBookmark(id: "bookmark_bar:same.com:dup1", title: "Second", url: "https://same.com", type: .leaf, mtime: Date(), index: 1),
        ])

        let guids = try allGuids(url)
        XCTAssertEqual(guids.count, Set(guids).count, "Duplicate guids written: \(guids)")
    }

    /// Same shape, for ids -- Chrome also requires unique numeric ids.
    func testTwoBookmarksSameUrlGetDistinctIds() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("Bookmarks_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }

        let root: [String: Any] = [
            "version": 1,
            "roots": [
                "bookmark_bar": ["id": "1", "name": "Bar", "type": "folder", "date_added": "13000000000000000",
                                 "children": [["id": "100", "guid": "aaaaaaaa-1111-2222-3333-444444444444",
                                               "name": "Only", "type": "url", "url": "https://same.com",
                                               "date_added": "13000000000000000"]]],
                "other": ["id": "2", "name": "Other", "type": "folder", "date_added": "13000000000000000", "children": [[String: Any]]()],
                "synced": ["id": "3", "name": "Synced", "type": "folder", "date_added": "13000000000000000", "children": [[String: Any]]()],
            ],
        ]
        try JSONSerialization.data(withJSONObject: root, options: []).write(to: url)

        let parser = ChromeParser(filePath: url)
        try parser.write(nodes: [
            ParsedBookmark(id: "bookmark_bar:same.com", title: "First", url: "https://same.com", type: .leaf, mtime: Date(), index: 0),
            ParsedBookmark(id: "bookmark_bar:same.com:dup1", title: "Second", url: "https://same.com", type: .leaf, mtime: Date(), index: 1),
        ])

        let json = try JSONSerialization.jsonObject(with: try Data(contentsOf: url)) as! [String: Any]
        let roots = json["roots"] as! [String: Any]
        let kids = ((roots["bookmark_bar"] as! [String: Any])["children"] as? [[String: Any]]) ?? []
        let ids = kids.compactMap { $0["id"] as? String }
        XCTAssertEqual(ids.count, Set(ids).count, "Duplicate ids written: \(ids)")
    }
}

// MARK: - Cross-browser URL identity matching (intended behaviour)

final class ChromeUrlMatchingTests: XCTestCase {

    private func write(_ bar: [[String: Any]]) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("Bookmarks_\(UUID().uuidString)")
        let root: [String: Any] = [
            "version": 1,
            "roots": [
                "bookmark_bar": ["id": "1", "name": "Bar", "type": "folder", "date_added": "13000000000000000", "children": bar],
                "other": ["id": "2", "name": "Other", "type": "folder", "date_added": "13000000000000000", "children": [[String: Any]]()],
                "synced": ["id": "3", "name": "Synced", "type": "folder", "date_added": "13000000000000000", "children": [[String: Any]]()],
            ],
        ]
        try JSONSerialization.data(withJSONObject: root, options: []).write(to: url)
        return url
    }

    private func nodes(_ url: URL, _ root: String = "bookmark_bar") throws -> [[String: Any]] {
        let json = try JSONSerialization.jsonObject(with: try Data(contentsOf: url)) as! [String: Any]
        let roots = json["roots"] as! [String: Any]
        return ((roots[root] as! [String: Any])["children"] as? [[String: Any]]) ?? []
    }

    /// THE INTENDED BEHAVIOUR: the same URL saved under a different name in
    /// another browser must adopt the existing Chrome node's identity rather
    /// than becoming a new bookmark.
    func testDifferentNameSameUrlAdoptsExistingIdentity() throws {
        let url = try write([[
            "id": "100", "guid": "aaaaaaaa-1111-2222-3333-444444444444",
            "name": "Chrome's Name", "type": "url", "url": "https://shared.com",
            "date_added": "13000000000000000",
        ]])
        defer { try? FileManager.default.removeItem(at: url) }

        let parser = ChromeParser(filePath: url)
        // Same URL at the same place, but the title another browser uses. Its
        // topological id therefore differs from Chrome's original.
        try parser.write(nodes: [
            ParsedBookmark(id: "bookmark_bar:shared.com", title: "Safari's Name",
                           url: "https://shared.com", type: .leaf, mtime: Date(), index: 0)
        ])

        let written = try nodes(url)
        XCTAssertEqual(written.count, 1, "Must stay one bookmark, not duplicate")
        XCTAssertEqual(written.first?["name"] as? String, "Safari's Name", "Name updated")
        XCTAssertEqual(written.first?["guid"] as? String, "aaaaaaaa-1111-2222-3333-444444444444",
                       "Identity adopted from the URL match -- this is the cross-browser merge")
        XCTAssertEqual(written.first?["id"] as? String, "100")
    }

    /// Renaming inside a folder must also keep identity via the URL match.
    func testRenameInsideFolderAdoptsIdentity() throws {
        let url = try write([[
            "id": "101", "guid": "bbbbbbbb-1111-2222-3333-444444444444",
            "name": "Folder", "type": "folder", "date_added": "13000000000000000",
            "children": [[
                "id": "102", "guid": "cccccccc-1111-2222-3333-444444444444",
                "name": "Old Inner", "type": "url", "url": "https://inner.com",
                "date_added": "13000000000000000",
            ]],
        ]])
        defer { try? FileManager.default.removeItem(at: url) }

        let parser = ChromeParser(filePath: url)
        let folderId = "bookmark_bar:Folder"
        try parser.write(nodes: [
            ParsedBookmark(id: folderId, title: "Folder", url: nil, type: .folder, mtime: Date(), index: 0),
            ParsedBookmark(id: "\(folderId):inner.com", title: "New Inner", url: "https://inner.com",
                           type: .leaf, parentId: folderId, mtime: Date(), index: 0),
        ])

        let folder = try nodes(url).first { ($0["name"] as? String) == "Folder" }
        let inner = (folder?["children"] as? [[String: Any]]) ?? []
        XCTAssertEqual(inner.count, 1)
        XCTAssertEqual(inner.first?["name"] as? String, "New Inner")
        XCTAssertEqual(inner.first?["guid"] as? String, "cccccccc-1111-2222-3333-444444444444",
                       "Identity preserved through a rename within the folder")
    }

    /// Scoping check: an unrelated bookmark that merely shares a URL in a
    /// DIFFERENT folder must not have its identity stolen.
    func testSameUrlInDifferentFolderDoesNotStealIdentity() throws {
        let url = try write([
            [
                "id": "100", "guid": "aaaaaaaa-1111-2222-3333-444444444444",
                "name": "At Root", "type": "url", "url": "https://shared.com",
                "date_added": "13000000000000000",
            ],
            [
                "id": "101", "guid": "bbbbbbbb-1111-2222-3333-444444444444",
                "name": "Folder", "type": "folder", "date_added": "13000000000000000",
                "children": [[String: Any]](),
            ],
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let parser = ChromeParser(filePath: url)
        let folderId = "bookmark_bar:Folder"
        // Keep the root bookmark AND add a same-URL bookmark inside the folder.
        try parser.write(nodes: [
            ParsedBookmark(id: "bookmark_bar:shared.com", title: "At Root", url: "https://shared.com",
                           type: .leaf, mtime: Date(), index: 0),
            ParsedBookmark(id: folderId, title: "Folder", url: nil, type: .folder, mtime: Date(), index: 1),
            ParsedBookmark(id: "\(folderId):shared.com", title: "In Folder", url: "https://shared.com",
                           type: .leaf, parentId: folderId, mtime: Date(), index: 0),
        ])

        let written = try nodes(url)
        let atRoot = written.first { ($0["name"] as? String) == "At Root" }
        XCTAssertEqual(atRoot?["guid"] as? String, "aaaaaaaa-1111-2222-3333-444444444444",
                       "The root bookmark keeps its own identity")

        // And every guid in the file is still unique.
        var all: [String] = []
        func walk(_ n: [String: Any]) {
            if let g = n["guid"] as? String { all.append(g) }
            for c in (n["children"] as? [[String: Any]]) ?? [] { walk(c) }
        }
        written.forEach(walk)
        XCTAssertEqual(all.count, Set(all).count, "Guids must remain unique: \(all)")
    }
}

// MARK: - Pre-existing duplicate siblings (regression from real-world data)

final class ChromeDuplicateSiblingTests: XCTestCase {

    /// A real profile was found holding 17 identical copies of one bookmark in
    /// the same folder, accumulated by the id/guid-collision bug. Syncing such a
    /// file must be stable: the copies keep distinct identities and no new ones
    /// appear.
    func testExistingDuplicateSiblingsDoNotMultiply() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("Bookmarks_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }

        // Seventeen siblings, same name and URL -- the observed real-world shape.
        let copies: [[String: Any]] = (0..<17).map { i in
            ["id": "\(200 + i)",
             "guid": String(format: "aaaaaaaa-1111-2222-3333-%012d", i),
             "name": "Plasticity - Product tour",
             "type": "url",
             "url": "https://www.plasticity.xyz/product",
             "date_added": "13000000000000000"]
        }
        let root: [String: Any] = [
            "version": 1,
            "roots": [
                "bookmark_bar": ["id": "1", "name": "Bar", "type": "folder", "date_added": "13000000000000000",
                                 "children": [["id": "150", "guid": "bbbbbbbb-1111-2222-3333-444444444444",
                                               "name": "Tools", "type": "folder",
                                               "date_added": "13000000000000000", "children": copies]]],
                "other": ["id": "2", "name": "Other", "type": "folder", "date_added": "13000000000000000", "children": [[String: Any]]()],
                "synced": ["id": "3", "name": "Synced", "type": "folder", "date_added": "13000000000000000", "children": [[String: Any]]()],
            ],
        ]
        try JSONSerialization.data(withJSONObject: root, options: []).write(to: url)

        let parser = ChromeParser(filePath: url)
        let before = try parser.read()
        XCTAssertEqual(before.count, 18, "Folder plus 17 copies")

        // Three no-op sync cycles.
        for _ in 0..<3 {
            try parser.write(nodes: try parser.read())
        }

        let after = try parser.read()
        XCTAssertEqual(after.count, before.count, "Count must not grow: \(after.count) vs \(before.count)")

        // Every id and guid in the written file must still be unique.
        let json = try JSONSerialization.jsonObject(with: try Data(contentsOf: url)) as! [String: Any]
        let roots = json["roots"] as! [String: Any]
        var guids: [String] = []
        var ids: [String] = []
        func walk(_ n: [String: Any]) {
            if let g = n["guid"] as? String { guids.append(g) }
            if let i = n["id"] as? String { ids.append(i) }
            for c in (n["children"] as? [[String: Any]]) ?? [] { walk(c) }
        }
        for key in ["bookmark_bar", "other", "synced"] {
            if let r = roots[key] as? [String: Any] {
                for c in (r["children"] as? [[String: Any]]) ?? [] { walk(c) }
            }
        }
        XCTAssertEqual(guids.count, Set(guids).count, "Guids must stay unique across 17 identical siblings")
        XCTAssertEqual(ids.count, Set(ids).count, "Ids must stay unique")
        XCTAssertTrue(guids.allSatisfy { $0 == $0.lowercased() }, "All lowercase")
    }
}
