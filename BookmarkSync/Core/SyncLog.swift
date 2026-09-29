import Foundation
import os

/// Sync-engine logging.
///
/// The engine used bare `print()` in its innermost loops, which meant ~3000
/// unbuffered stderr writes during a large import — milliseconds each when a
/// debugger is attached, and a measurable part of the main-thread stall.
///
/// `verbose` messages are per-node and compiled out of release builds entirely;
/// `event` messages are per-sync or per-profile and always recorded.
enum SyncLog {
    private static let logger = Logger(subsystem: "app.xazi.BookmarkSync", category: "sync")

    /// Per-node detail. Debug builds only, and further gated on the
    /// `BOOKMARKSYNC_VERBOSE` environment variable so that even a debug run is
    /// quiet by default.
    @inline(__always)
    static func verbose(_ message: @autoclosure () -> String) {
        #if DEBUG
        if isVerboseEnabled {
            let text = message()
            logger.debug("\(text, privacy: .public)")
        }
        #endif
    }

    /// Per-sync or per-profile milestones, and anything a user may need to see.
    @inline(__always)
    static func event(_ message: @autoclosure () -> String) {
        let text = message()
        logger.notice("\(text, privacy: .public)")
    }

    @inline(__always)
    static func error(_ message: @autoclosure () -> String) {
        let text = message()
        logger.error("\(text, privacy: .public)")
    }

    #if DEBUG
    private static let isVerboseEnabled: Bool =
        ProcessInfo.processInfo.environment["BOOKMARKSYNC_VERBOSE"] != nil
    #endif
}
