import XCTest
@testable import BookmarkSync

final class ManualBackupTests: XCTestCase {
    private var dir: URL!
    private var live: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ManualBackup_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        live = dir.appendingPathComponent("Bookmarks")
        try Data("v1".utf8).write(to: live)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testManualBackupIsListedAsManual() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let url = try XCTUnwrap(try BackupStore.createBackup(of: live, now: now, manual: true))
        XCTAssertTrue(url.lastPathComponent.hasPrefix("Bookmarks.backup.manual."))

        let entries = BackupStore.listBackups(for: live)
        XCTAssertEqual(entries.map(\.kind), [.manual])
        XCTAssertEqual(entries.first?.date, now)
    }

    func testManualBackupsAreNeverPruned() throws {
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        try BackupStore.createBackup(of: live, now: old, manual: true)
        // A year of automatic backups later, the manual one is still there.
        for day in 0..<40 {
            try BackupStore.createBackup(of: live, now: old.addingTimeInterval(Double(365 + day) * 86_400))
        }
        XCTAssertEqual(BackupStore.listBackups(for: live).filter { $0.kind == .manual }.count, 1)
    }
}

/// A finished activity row must not hide a new pending change with the same
/// title (a folder deleted, re-created and deleted again showed "0 pending").
@MainActor
final class PendingActivityTests: XCTestCase {
    func testFinishedRowDoesNotHideANewPendingChange() {
        let viewModel = AppViewModel()
        viewModel.addDiffs(titles: ["Delete: Test"], targetBundleId: "com.google.Chrome", targetProfileName: "Default", profileSetId: "S")
        viewModel.markBrowserSynced(bundleId: "com.google.Chrome")
        XCTAssertTrue(viewModel.diffHistory.allSatisfy { !$0.isWaiting })

        viewModel.addDiffs(titles: ["Delete: Test"], targetBundleId: "com.google.Chrome", targetProfileName: "Default", profileSetId: "S")
        XCTAssertEqual(viewModel.diffHistory.filter { $0.isWaiting }.count, 1)

        // While it is still pending, repeating it does not add another row.
        viewModel.addDiffs(titles: ["Delete: Test"], targetBundleId: "com.google.Chrome", targetProfileName: "Default", profileSetId: "S")
        XCTAssertEqual(viewModel.diffHistory.filter { $0.isWaiting }.count, 1)
    }
}
