import Foundation
import IOKit

/// The lock Safari and `SafariBookmarksSyncAgent` take around every write to
/// `Bookmarks.plist`: a `lock` directory beside the file, holding a
/// `details.plist` that names the holder. Created with `mkdir`, which is atomic.
///
/// Taking it keeps the sync agent from rewriting the file while we write it,
/// and keeps us from writing over the agent mid-update.
struct SafariBookmarksLock {
    enum LockError: LocalizedError {
        case held(by: String)

        var errorDescription: String? {
            switch self {
            case .held(let holder):
                return "Safari bookmarks are locked by \(holder)"
            }
        }
    }

    /// A lock directory without details this old is treated as abandoned.
    /// Real holders write details right after `mkdir` and hold for 1-2s.
    static let detailsGracePeriod: TimeInterval = 30

    let directory: URL

    init(bookmarksFile: URL) {
        directory = bookmarksFile.deletingLastPathComponent().appendingPathComponent("lock")
    }

    private var detailsURL: URL { directory.appendingPathComponent("details.plist") }

    /// Runs `body` while holding the lock. Throws `LockError.held` at once if
    /// another live process holds it; callers retry later rather than wait.
    func withLock<T>(_ body: () throws -> T) throws -> T {
        try acquire()
        defer { try? FileManager.default.removeItem(at: directory) }
        return try body()
    }

    private func acquire() throws {
        if mkdir(directory.path, 0o755) != 0 {
            guard errno == EEXIST else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            guard isAbandoned() else {
                throw LockError.held(by: holderName() ?? "another process")
            }
            SyncLog.event("Removing abandoned Safari bookmarks lock held by \(holderName() ?? "unknown")")
            try? FileManager.default.removeItem(at: directory)
            guard mkdir(directory.path, 0o755) == 0 else {
                throw LockError.held(by: holderName() ?? "another process")
            }
        }

        // Same keys and value types Safari writes.
        let details: [String: Any] = [
            "LockFileDate": Date(),
            "LockFileHostname": Self.hostUUID ?? ProcessInfo.processInfo.hostName,
            "LockFileProcessID": Int(ProcessInfo.processInfo.processIdentifier),
            "LockFileProcessName": ProcessInfo.processInfo.processName,
            "LockFileUsername": NSFullUserName(),
        ]
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: details, format: .binary, options: 0)
            try data.write(to: detailsURL)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private func readDetails() -> [String: Any]? {
        guard let data = try? Data(contentsOf: detailsURL) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
    }

    private func holderName() -> String? {
        readDetails()?["LockFileProcessName"] as? String
    }

    /// Only a lock that provably has no live holder counts as abandoned:
    /// one from a dead process on this Mac, or one never given details.
    private func isAbandoned() -> Bool {
        guard let details = readDetails() else {
            let created = (try? FileManager.default.attributesOfItem(atPath: directory.path))?[.creationDate] as? Date
            return created.map { Date().timeIntervalSince($0) > Self.detailsGracePeriod } ?? false
        }
        guard let host = details["LockFileHostname"] as? String, host == Self.hostUUID,
              let pid = details["LockFileProcessID"] as? Int else { return false }
        return kill(pid_t(pid), 0) != 0 && errno == ESRCH
    }

    /// The hardware UUID Safari records as `LockFileHostname`.
    static let hostUUID: String? = {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        return IORegistryEntryCreateCFProperty(service, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String
    }()
}
