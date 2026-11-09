import XCTest
@testable import BookmarkSync

@MainActor
final class UpdateCheckerTests: XCTestCase {
    func testParsesVersionAndChangelog() {
        let text = "\n 1.2.0 \n- Faster sync\n\n* Spanish UI\n• Fixed backups\nPlain line\n"
        let release = UpdateChecker.parseLatest(text)
        XCTAssertEqual(release?.version, "1.2.0")
        XCTAssertEqual(release?.notes, ["Faster sync", "Spanish UI", "Fixed backups", "Plain line"])
    }

    func testRejectsAnythingButADottedVersion() {
        XCTAssertNil(UpdateChecker.parseLatest("<!DOCTYPE html>\n<html>"))
        XCTAssertNil(UpdateChecker.parseLatest("v1.2"))
        XCTAssertNil(UpdateChecker.parseLatest("1..2"))
        XCTAssertNil(UpdateChecker.parseLatest(""))
    }

    func testChangelogIsCapped() {
        let text = "2.0\n" + (1...20).map { "- note \($0)" }.joined(separator: "\n")
        XCTAssertEqual(UpdateChecker.parseLatest(text)?.notes.count, UpdateChecker.maxNotes)
    }

    func testVersionComparisonIsNumeric() {
        XCTAssertTrue(UpdateChecker.isNewer("1.10.0", than: "1.9.3"))
        XCTAssertTrue(UpdateChecker.isNewer("1.1.1", than: "1.1"))
        XCTAssertFalse(UpdateChecker.isNewer("1.1", than: "1.1.0"))
        XCTAssertFalse(UpdateChecker.isNewer("1.0.9", than: "1.1.0"))
        XCTAssertFalse(UpdateChecker.isNewer("garbage", than: "1.0"))
    }

    func testWeeklySchedule() {
        let now = Date()
        XCTAssertTrue(UpdateChecker.isDue(lastCheck: nil, now: now))
        XCTAssertFalse(UpdateChecker.isDue(lastCheck: now.addingTimeInterval(-6 * 86_400), now: now))
        XCTAssertTrue(UpdateChecker.isDue(lastCheck: now.addingTimeInterval(-7 * 86_400), now: now))
    }

    func testDisabledByDefault() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "UpdateCheckerTests"))
        defaults.removePersistentDomain(forName: "UpdateCheckerTests")
        XCTAssertFalse(UpdateChecker(defaults: defaults).isEnabled)
    }
}
