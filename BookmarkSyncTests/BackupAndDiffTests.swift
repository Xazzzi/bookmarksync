import XCTest
@testable import BookmarkSync

// MARK: - Backup naming, listing and restore

final class BackupStoreTests: XCTestCase {
    private var dir: URL!
    private var live: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("BackupStoreTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        live = dir.appendingPathComponent("Bookmarks")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func setLive(_ text: String) throws {
        try Data(text.utf8).write(to: live)
    }

    private func contents(_ url: URL) throws -> String {
        String(decoding: try Data(contentsOf: url), as: UTF8.self)
    }

    func testBackupIsNamedByTimestamp() throws {
        try setLive("v1")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let url = try XCTUnwrap(try BackupStore.createBackup(of: live, now: now))

        XCTAssertTrue(url.lastPathComponent.hasPrefix("Bookmarks.backup."))
        XCTAssertNotNil(url.lastPathComponent.range(of: #"\.backup\.\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}$"#, options: .regularExpression))
        XCTAssertEqual(try contents(url), "v1")

        let listed = BackupStore.listBackups(for: live)
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed.first?.kind, .timestamped)
        XCTAssertEqual(listed.first?.date, now)
    }

    func testBackupsInTheSameSecondDoNotCollide() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try setLive("a")
        try BackupStore.createBackup(of: live, now: now)
        try setLive("b")
        try BackupStore.createBackup(of: live, now: now)

        let listed = BackupStore.listBackups(for: live)
        XCTAssertEqual(listed.count, 2)
        XCTAssertTrue(listed.allSatisfy { $0.kind == .timestamped })
        XCTAssertEqual(Set(try listed.map { try contents($0.url) }), ["a", "b"])
    }

    /// Regression: restoring used to shift the rotating backups first, so the
    /// chosen file already held different contents by the time it was copied.
    func testRestoreBringsBackExactlyTheChosenBackup() throws {
        let t1 = Date(timeIntervalSince1970: 1_800_000_000)
        try setLive("v1")
        try BackupStore.createBackup(of: live, now: t1)
        try setLive("v2")
        try BackupStore.createBackup(of: live, now: t1.addingTimeInterval(60))
        try setLive("v3")

        let chosen = try XCTUnwrap(BackupStore.listBackups(for: live).first { $0.date == t1 })
        try BackupStore.restore(chosen, over: live, now: t1.addingTimeInterval(120))

        XCTAssertEqual(try contents(live), "v1")
        let after = BackupStore.listBackups(for: live)
        XCTAssertEqual(after.count, 3, "Restoring adds one backup of the replaced file and moves nothing")
        XCTAssertEqual(try contents(try XCTUnwrap(after.first { $0.date == t1 }).url), "v1")
        XCTAssertEqual(try contents(try XCTUnwrap(after.first { $0.date == t1.addingTimeInterval(60) }).url), "v2")
        XCTAssertEqual(try contents(try XCTUnwrap(after.first { $0.date == t1.addingTimeInterval(120) }).url), "v3",
                       "The file that was replaced can itself be restored")
    }

    func testLegacyBackupsAreListedAndNeverPruned() throws {
        try setLive("live")
        let fm = FileManager.default
        try Data("old1".utf8).write(to: dir.appendingPathComponent("Bookmarks.backup.1"))
        try Data("daily".utf8).write(to: dir.appendingPathComponent("Bookmarks.backup.daily.2025-01-01"))
        try Data("junk".utf8).write(to: dir.appendingPathComponent("Bookmarks.backup.notabackup"))

        try BackupStore.createBackup(of: live)

        let kinds = BackupStore.listBackups(for: live).map(\.kind)
        XCTAssertEqual(kinds.filter { $0 == .legacyRotating }.count, 1)
        XCTAssertEqual(kinds.filter { $0 == .legacyDaily }.count, 1)
        XCTAssertEqual(kinds.filter { $0 == .timestamped }.count, 1)
        XCTAssertEqual(kinds.count, 3, "Unrecognised names are not backups")
        XCTAssertTrue(fm.fileExists(atPath: dir.appendingPathComponent("Bookmarks.backup.1").path))
        XCTAssertTrue(fm.fileExists(atPath: dir.appendingPathComponent("Bookmarks.backup.daily.2025-01-01").path))
    }

    func testMissingLiveFileIsNotBackedUp() throws {
        XCTAssertNil(try BackupStore.createBackup(of: live))
        XCTAssertTrue(BackupStore.listBackups(for: live).isEmpty)
    }
}

// MARK: - Retention policy

final class BackupRetentionTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// 2026-10-15 12:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_792_065_600)

    private func entry(_ name: String, hoursAgo: Double) -> BackupEntry {
        BackupEntry(url: URL(fileURLWithPath: "/tmp/\(name)"), kind: .timestamped,
                    date: now.addingTimeInterval(-hoursAgo * 3600))
    }

    func testKeepsRecentKeepsOnePerDayThenDropsOld() {
        let entries = [
            entry("now", hoursAgo: 0),
            entry("1d", hoursAgo: 24),
            entry("3d-a", hoursAgo: 72),
            entry("3d-b", hoursAgo: 73),          // still within 7 days: kept
            entry("8d-newer", hoursAgo: 8 * 24),
            entry("8d-older", hoursAgo: 8 * 24 + 1), // same day as 8d-newer: dropped
            entry("20d", hoursAgo: 20 * 24),
            entry("31d", hoursAgo: 31 * 24),       // past 30 days: dropped
        ]
        let dropped = Set(BackupStore.filesToPrune(entries, now: now, calendar: calendar).map(\.lastPathComponent))
        XCTAssertEqual(dropped, ["8d-older", "31d"])
    }

    func testTotalIsCappedDroppingTheOldest() {
        let count = BackupStore.maxBackups + 50
        let entries = (0..<count).map { entry("m\($0)", hoursAgo: Double($0) / 60) }
        let dropped = BackupStore.filesToPrune(entries, now: now, calendar: calendar).map(\.lastPathComponent)
        XCTAssertEqual(Set(dropped), Set((BackupStore.maxBackups..<count).map { "m\($0)" }))
    }

    func testLegacyEntriesAreIgnored() {
        let legacy = BackupEntry(url: URL(fileURLWithPath: "/tmp/old"), kind: .legacyRotating,
                                 date: now.addingTimeInterval(-365 * 86_400))
        XCTAssertTrue(BackupStore.filesToPrune([legacy], now: now, calendar: calendar).isEmpty)
    }
}

// MARK: - Item-by-item diff

final class BookmarkDiffTests: XCTestCase {
    private func leaf(_ id: String, _ title: String, _ url: String, parent: String? = nil) -> ParsedBookmark {
        ParsedBookmark(id: id, title: title, url: url, type: .leaf, parentId: parent, mtime: Date(timeIntervalSince1970: 0))
    }

    private func folder(_ id: String, _ title: String, parent: String? = nil) -> ParsedBookmark {
        ParsedBookmark(id: id, title: title, type: .folder, parentId: parent, mtime: Date(timeIntervalSince1970: 0))
    }

    func testReportsAddedRemovedAndChangedWithFolderPaths() {
        let work = folder("bookmark_bar:Work", "Work")
        let old = [
            leaf("bookmark_bar:a.com", "A", "https://a.com"),
            leaf("bookmark_bar:b.com", "B", "https://b.com"),
            work,
            leaf("bookmark_bar:Work:c.com", "C", "https://c.com", parent: work.id),
        ]
        let new = [
            leaf("bookmark_bar:a.com", "A renamed", "https://a.com"),
            work,
            leaf("bookmark_bar:Work:c.com", "C", "https://c.com", parent: work.id),
            leaf("bookmark_bar:Work:d.com", "D", "https://d.com", parent: work.id),
        ]

        let diff = BookmarkDiff(old: old, new: new)

        XCTAssertEqual(diff.removed.map(\.title), ["B"])
        XCTAssertEqual(diff.added.map(\.title), ["D"])
        XCTAssertEqual(diff.added.first?.path, ["bookmark_bar", "Work"])
        XCTAssertEqual(diff.changed.map(\.title), ["A renamed"])
        XCTAssertEqual(diff.changed.first?.change, .changed(oldTitle: "A", oldURL: "https://a.com"))
        XCTAssertEqual(diff.entries.count, 3, "Unchanged nodes are not listed")
    }

    func testIdenticalTreesHaveNoDifferences() {
        let nodes = [leaf("other:x.com", "X", "https://x.com")]
        XCTAssertTrue(BookmarkDiff(old: nodes, new: nodes).isEmpty)
    }

    func testProfileSetPrefixIsNotShownAsTheRoot() {
        let node = leaf("SET-1:other:x.com", "X", "https://x.com")
        XCTAssertEqual(BookmarkDiff.folderPath(of: node, in: [node.id: node]), ["other"])
    }
}
