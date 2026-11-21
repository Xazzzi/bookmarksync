import XCTest
import CoreServices
@testable import BookmarkSync

final class FileWatcherTests: XCTestCase {
    private func flags(_ values: Int...) -> FSEventStreamEventFlags {
        FSEventStreamEventFlags(values.reduce(0, |))
    }

    func testIgnoresMetadataOnlyEvents() {
        // What an APFS clone of places.sqlite reports on the source.
        XCTAssertFalse(FileWatcher.isContentChange(flags(kFSEventStreamEventFlagItemIsFile, kFSEventStreamEventFlagItemInodeMetaMod)))
        XCTAssertFalse(FileWatcher.isContentChange(flags(kFSEventStreamEventFlagItemIsFile, kFSEventStreamEventFlagItemXattrMod)))
    }

    func testPassesContentChangesAndRescans() {
        XCTAssertTrue(FileWatcher.isContentChange(flags(kFSEventStreamEventFlagItemIsFile, kFSEventStreamEventFlagItemModified, kFSEventStreamEventFlagItemInodeMetaMod)))
        XCTAssertTrue(FileWatcher.isContentChange(flags(kFSEventStreamEventFlagItemIsFile, kFSEventStreamEventFlagItemRenamed)))
        XCTAssertTrue(FileWatcher.isContentChange(flags(kFSEventStreamEventFlagItemIsFile, kFSEventStreamEventFlagItemCreated)))
        XCTAssertTrue(FileWatcher.isContentChange(flags(kFSEventStreamEventFlagItemIsFile, kFSEventStreamEventFlagItemRemoved)))
        XCTAssertTrue(FileWatcher.isContentChange(flags(kFSEventStreamEventFlagMustScanSubDirs)))
    }
}
