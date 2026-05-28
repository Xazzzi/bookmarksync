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
        let newNode = BookmarkNode(id: "bookmark_bar:https://apple.com", title: "Apple", url: "https://apple.com", type: .leaf, mtime: Date())
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
        let newNode = BookmarkNode(id: "bookmark_bar:https://google.com", title: "Google", url: "https://google.com", type: .leaf, mtime: Date())
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



