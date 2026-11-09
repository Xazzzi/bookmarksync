import Foundation

/// One backup file next to a browser's bookmark file.
struct BackupEntry: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// `<file>.backup.2026-10-15T14-30-05`, written by this version.
        case timestamped
        /// `<file>.backup.manual.2026-10-15T14-30-05`, taken from the Backups
        /// window. Never pruned automatically.
        case manual
        /// `<file>.backup.1` ... `.backup.3`, written by earlier versions.
        case legacyRotating
        /// `<file>.backup.daily.2026-10-15`, written by earlier versions.
        case legacyDaily
    }

    let url: URL
    let kind: Kind
    /// When the backup was taken: parsed from the name for timestamped
    /// backups, the file's modification date for legacy ones.
    let date: Date

    var id: String { url.path }
    var name: String { url.lastPathComponent }
}

/// Creates, lists, prunes and restores bookmark-file backups.
///
/// Backups are named by the time they were taken and never renamed afterwards.
/// The previous scheme rotated `.backup.1/2/3` on every backup, so restoring
/// ".backup.1" first shifted that file to ".backup.2" and then copied the
/// freshly made ".backup.1" -- the live file -- back over itself.
enum BackupStore {
    /// Every backup from the last `keepAllDays` days is kept...
    static let keepAllDays = 7
    /// ...then the newest backup of each day up to `keepDailyDays` days...
    static let keepDailyDays = 30
    /// ...and never more than this many timestamped backups in total.
    static let maxBackups = 200

    private static let marker = ".backup."
    private static let manualPrefix = "manual."

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        return formatter
    }()

    private static let timestampPattern = try! NSRegularExpression(
        pattern: #"^(\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2})(?:-\d+)?$"#
    )

    // MARK: Creating

    /// Copies `fileURL` to a new timestamped backup beside it and prunes old
    /// backups. Returns `nil` when there is no file to back up.
    /// A manual backup is kept until the user deletes it.
    @discardableResult
    static func createBackup(of fileURL: URL, now: Date = Date(), manual: Bool = false) throws -> URL? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else { return nil }

        let dir = fileURL.deletingLastPathComponent()
        let base = "\(fileURL.lastPathComponent)\(marker)\(manual ? manualPrefix : "")\(timestampFormatter.string(from: now))"
        var target = dir.appendingPathComponent(base)
        var suffix = 2
        while fm.fileExists(atPath: target.path) {
            target = dir.appendingPathComponent("\(base)-\(suffix)")
            suffix += 1
        }
        try fm.copyItem(at: fileURL, to: target)

        let timestamped = listBackups(for: fileURL).filter { $0.kind == .timestamped }
        for url in filesToPrune(timestamped, now: now) {
            try? fm.removeItem(at: url)
        }
        return target
    }

    /// Which timestamped backups the retention policy drops. Legacy backups are
    /// never pruned: they are the user's only copies from earlier versions.
    static func filesToPrune(_ backups: [BackupEntry], now: Date, calendar: Calendar = .current) -> [URL] {
        let newestFirst = backups.filter { $0.kind == .timestamped }.sorted { $0.date > $1.date }
        let keepAllCutoff = now.addingTimeInterval(-Double(keepAllDays) * 86_400)
        let keepDailyCutoff = now.addingTimeInterval(-Double(keepDailyDays) * 86_400)

        var kept: [BackupEntry] = []
        var dropped: [URL] = []
        var keptDays = Set<DateComponents>()

        for entry in newestFirst {
            let day = calendar.dateComponents([.year, .month, .day], from: entry.date)
            let keep: Bool
            if entry.date >= keepAllCutoff {
                keep = true
            } else if entry.date >= keepDailyCutoff {
                keep = !keptDays.contains(day)
            } else {
                keep = false
            }

            if keep && kept.count < maxBackups {
                kept.append(entry)
                keptDays.insert(day)
            } else {
                dropped.append(entry.url)
            }
        }
        return dropped
    }

    // MARK: Listing

    /// All backups of `fileURL`, newest first.
    static func listBackups(for fileURL: URL) -> [BackupEntry] {
        let fm = FileManager.default
        let dir = fileURL.deletingLastPathComponent()
        let prefix = fileURL.lastPathComponent + marker
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return [] }

        var entries: [BackupEntry] = []
        for name in names where name.hasPrefix(prefix) {
            let url = dir.appendingPathComponent(name)
            let rest = String(name.dropFirst(prefix.count))
            let modified = (try? fm.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? .distantPast

            if let date = timestamp(from: rest) {
                entries.append(BackupEntry(url: url, kind: .timestamped, date: date))
            } else if rest.hasPrefix(manualPrefix), let date = timestamp(from: String(rest.dropFirst(manualPrefix.count))) {
                entries.append(BackupEntry(url: url, kind: .manual, date: date))
            } else if rest.hasPrefix("daily.") {
                entries.append(BackupEntry(url: url, kind: .legacyDaily, date: modified))
            } else if Int(rest) != nil {
                entries.append(BackupEntry(url: url, kind: .legacyRotating, date: modified))
            }
            // Anything else (e.g. a half-written temp file) is not a backup.
        }
        return entries.sorted { $0.date > $1.date }
    }

    private static func timestamp(from rest: String) -> Date? {
        let range = NSRange(rest.startIndex..., in: rest)
        guard let match = timestampPattern.firstMatch(in: rest, range: range),
              let stampRange = Range(match.range(at: 1), in: rest) else { return nil }
        return timestampFormatter.date(from: String(rest[stampRange]))
    }

    // MARK: Restoring

    /// Replaces `liveURL` with the contents of `backup`, after backing up the
    /// current live file so the restore itself can be undone.
    ///
    /// The caller must make sure the browser is not running: a running browser
    /// keeps its bookmarks in memory and overwrites the restored file.
    static func restore(_ backup: BackupEntry, over liveURL: URL, now: Date = Date()) throws {
        let fm = FileManager.default
        try createBackup(of: liveURL, now: now)

        // Copy into the same directory first, then swap it in, so the live
        // file is never missing or half-written.
        let staging = liveURL.deletingLastPathComponent()
            .appendingPathComponent(".\(liveURL.lastPathComponent).restore-\(UUID().uuidString)")
        try fm.copyItem(at: backup.url, to: staging)
        do {
            if fm.fileExists(atPath: liveURL.path) {
                _ = try fm.replaceItemAt(liveURL, withItemAt: staging)
            } else {
                try fm.moveItem(at: staging, to: liveURL)
            }
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }

        // A restored SQLite database must not be paired with the previous
        // database's write-ahead log, which SQLite would replay over it.
        if liveURL.pathExtension == "sqlite" {
            try? fm.removeItem(at: URL(fileURLWithPath: liveURL.path + "-wal"))
            try? fm.removeItem(at: URL(fileURLWithPath: liveURL.path + "-shm"))
        }
    }
}
