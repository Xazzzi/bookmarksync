import XCTest
@testable import BookmarkSync

final class SearchParserTests: XCTestCase {
    private var url: URL!

    override func setUp() {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("search-bookmarks-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: url)
        // Backups are written next to the file.
        let dir = url.deletingLastPathComponent()
        for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        where name.hasPrefix(url.lastPathComponent + ".backup") {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    private let sample = """
    [{"id":"AAAAAAAA-0000-0000-0000-000000000001","title":"Example","url":"https:\\/\\/example.com\\/"},
     {"id":"AAAAAAAA-0000-0000-0000-000000000002","title":"Work","children":[
        {"id":"AAAAAAAA-0000-0000-0000-000000000003","title":"Docs","url":"https:\\/\\/docs.example.com\\/a"}]}]
    """

    func testReadsTopLevelAsBarWithFolders() throws {
        try sample.write(to: url, atomically: true, encoding: .utf8)
        let nodes = try SearchParser(filePath: url).read()
        XCTAssertEqual(nodes.count, 3)
        let work = try XCTUnwrap(nodes.first { $0.title == "Work" })
        XCTAssertEqual(work.id, "bookmark_bar:Work")
        XCTAssertEqual(work.type, .folder)
        let docs = try XCTUnwrap(nodes.first { $0.title == "Docs" })
        XCTAssertEqual(docs.parentId, work.id)
    }

    func testWriteKeepsExistingIdsAndAppliesChanges() throws {
        try sample.write(to: url, atomically: true, encoding: .utf8)
        let parser = SearchParser(filePath: url)
        var nodes = try parser.read()
        nodes.append(ParsedBookmark(id: "bookmark_bar:new.example.com", title: "New", url: "https://new.example.com",
                                    type: .leaf, parentId: nil, mtime: Date(), index: 2))
        nodes.removeAll { $0.title == "Example" }
        try parser.write(nodes: nodes)

        let out = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [[String: Any]]
        XCTAssertEqual(out.map { $0["title"] as? String }, ["Work", "New"])
        XCTAssertEqual(out[0]["id"] as? String, "AAAAAAAA-0000-0000-0000-000000000002")
        let kids = out[0]["children"] as! [[String: Any]]
        XCTAssertEqual(kids.first?["id"] as? String, "AAAAAAAA-0000-0000-0000-000000000003")
        XCTAssertNotNil(out[1]["id"])

        // And it reads back to the same tree.
        XCTAssertEqual(try parser.read().count, 3)
    }

    func testRefusesAFileThatIsNotAList() throws {
        try "{\"roots\":{}}".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try SearchParser(filePath: url).read())
        XCTAssertThrowsError(try SearchParser(filePath: url).write(nodes: []))
    }

    func testSearchHoldsOnlyTheBarRoot() {
        XCTAssertEqual(BookmarkRoots.supported(bundleId: "com.officecommun.search", profileName: "Default"), ["bookmark_bar"])
    }
}
