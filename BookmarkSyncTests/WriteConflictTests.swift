import XCTest
@testable import BookmarkSync

/// A queued write is dropped, and a re-sync requested, when its file changed
/// after the sync that computed the write had read it.
final class WriteConflictTests: XCTestCase {
    private var url: URL!

    override func setUpWithError() throws {
        url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("WriteConflict_\(UUID().uuidString).plist")
        let root: [String: Any] = [
            "Children": [
                ["Title": "BookmarksBar", "WebBookmarkType": "WebBookmarkTypeList", "WebBookmarkUUID": "BAR",
                 "Children": [["Title": "A", "WebBookmarkType": "WebBookmarkTypeLeaf", "URLString": "https://a.com/",
                               "WebBookmarkUUID": "U-A", "URIDictionary": ["title": "A"]]]],
                ["Title": "BookmarksMenu", "WebBookmarkType": "WebBookmarkTypeList", "WebBookmarkUUID": "MENU", "Children": []],
            ],
            "Title": "", "WebBookmarkFileVersion": 1, "WebBookmarkType": "WebBookmarkTypeList", "WebBookmarkUUID": "ROOT",
        ]
        try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0).write(to: url)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: url)
    }

    private func leaf(_ title: String, _ link: String, index: Int, mtime: Date = Date()) -> ParsedBookmark {
        ParsedBookmark(id: "bookmark_bar:\(normalizeURL(link))", title: title, url: link, type: .leaf,
                       parentId: nil, mtime: mtime, index: index)
    }

    func testFingerprintIgnoresMtimeButNotContent() {
        let base = [leaf("A", "https://a.com/", index: 0, mtime: Date(timeIntervalSince1970: 1))]
        let touched = [leaf("A", "https://a.com/", index: 0, mtime: Date(timeIntervalSince1970: 2))]
        let renamed = [leaf("B", "https://a.com/", index: 0)]
        let moved = [leaf("A", "https://a.com/", index: 1)]

        XCTAssertEqual(BookmarkSnapshotFingerprint.compute(base), BookmarkSnapshotFingerprint.compute(touched))
        XCTAssertNotEqual(BookmarkSnapshotFingerprint.compute(base), BookmarkSnapshotFingerprint.compute(renamed))
        XCTAssertNotEqual(BookmarkSnapshotFingerprint.compute(base), BookmarkSnapshotFingerprint.compute(moved))
    }

    func testStaleWriteIsDroppedAndReported() throws {
        let parser = SafariParser(filePath: url)
        let initial = try parser.read()
        let expected = BookmarkSnapshotFingerprint.compute(initial)

        // The browser adds a bookmark after the sync read the file.
        try parser.write(nodes: initial + [leaf("Remote", "https://remote.com/", index: 1)])

        let queue = WriteQueue(monitorsSystem: false, runningBundleIds: { [] })
        var conflicted: URL?
        queue.onWriteConflict = { conflicted = $0 }
        queue.enqueue(parser: parser, nodes: initial + [leaf("Local", "https://local.com/", index: 1)],
                      bundleId: "com.apple.Safari", expectedDiskFingerprint: expected)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertEqual(conflicted, url)
        XCTAssertFalse(queue.isWritePending(for: "com.apple.Safari"))
        XCTAssertEqual(try parser.read().map(\.title), ["A", "Remote"])
    }

    func testWriteProceedsWhenFileIsUnchanged() throws {
        let parser = SafariParser(filePath: url)
        let initial = try parser.read()

        let queue = WriteQueue(monitorsSystem: false, runningBundleIds: { [] })
        var conflicted: URL?
        queue.onWriteConflict = { conflicted = $0 }
        queue.enqueue(parser: parser, nodes: initial + [leaf("Local", "https://local.com/", index: 1)],
                      bundleId: "com.apple.Safari", expectedDiskFingerprint: BookmarkSnapshotFingerprint.compute(initial))
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertNil(conflicted)
        XCTAssertEqual(try parser.read().map(\.title), ["A", "Local"])
    }

    func testWriteIsHeldWhileBrowserRuns() throws {
        let parser = SafariParser(filePath: url)
        let initial = try parser.read()

        let queue = WriteQueue(monitorsSystem: false, runningBundleIds: { ["com.apple.Safari"] })
        queue.enqueue(parser: parser, nodes: initial + [leaf("Local", "https://local.com/", index: 1)],
                      bundleId: "com.apple.Safari", expectedDiskFingerprint: BookmarkSnapshotFingerprint.compute(initial))

        XCTAssertTrue(queue.isWritePending(for: "com.apple.Safari"))
        XCTAssertEqual(try parser.read().map(\.title), ["A"])
    }
}
