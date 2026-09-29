import Foundation

protocol BrowserParser {
    var filePath: URL { get }
    func read() throws -> [BookmarkNode]
    func write(nodes: [BookmarkNode]) throws
}

extension BrowserParser {
    func performBackup() throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: filePath.path) else { return }
        
        let baseDir = filePath.deletingLastPathComponent()
        let filename = filePath.lastPathComponent
        
        // 1. Daily Backup (filename.backup.daily.YYYY-MM-DD)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let dateString = formatter.string(from: Date())
        let dailyBackupURL = baseDir.appendingPathComponent("\(filename).backup.daily.\(dateString)")
        
        if !fm.fileExists(atPath: dailyBackupURL.path) {
            try? fm.copyItem(at: filePath, to: dailyBackupURL)
        }
        
        // Clean up old daily backups (keep only the last 7)
        if let files = try? fm.contentsOfDirectory(atPath: baseDir.path) {
            let dailyPrefix = "\(filename).backup.daily."
            let dailyBackups = files.filter { $0.hasPrefix(dailyPrefix) }.sorted()
            if dailyBackups.count > 7 {
                let backupsToDelete = dailyBackups.prefix(dailyBackups.count - 7)
                for oldBackup in backupsToDelete {
                    let oldURL = baseDir.appendingPathComponent(oldBackup)
                    try? fm.removeItem(at: oldURL)
                }
            }
        }
        
        // 2. Rotating Backups (filename.backup.1, .2, .3)
        let backup3 = baseDir.appendingPathComponent("\(filename).backup.3")
        let backup2 = baseDir.appendingPathComponent("\(filename).backup.2")
        let backup1 = baseDir.appendingPathComponent("\(filename).backup.1")
        
        try? fm.removeItem(at: backup3)
        if fm.fileExists(atPath: backup2.path) {
            try? fm.moveItem(at: backup2, to: backup3)
        }
        if fm.fileExists(atPath: backup1.path) {
            try? fm.moveItem(at: backup1, to: backup2)
        }
        try? fm.removeItem(at: backup1)
        try fm.copyItem(at: filePath, to: backup1)
    }
}

/// Sibling index for writing out a bookmark tree.
///
/// Every writer needs "the children of parent P, in order", recursively. Doing
/// that with `nodes.filter { $0.id.starts(with: prefix) && $0.parentId == p }`
/// rescans the whole array — and runs a string prefix comparison — once per
/// folder visited, which is O(N^2) and the dominant cost of a large write
/// (~9M `starts(with:)` calls at 3k bookmarks).
///
/// This groups the nodes once up front so each lookup is a dictionary hit.
struct BookmarkChildIndex {
    /// Children of a given parent id, pre-sorted by `index`.
    private var byParent: [String: [BookmarkNode]] = [:]
    /// Root-level children (no parent), bucketed by root prefix and pre-sorted.
    private var rootsByPrefix: [String: [BookmarkNode]] = [:]

    /// - Parameter nodes: nodes with profile-set prefixes already stripped, so
    ///   ids read as `<rootPrefix>:<path>`.
    init(strippedNodes nodes: [BookmarkNode]) {
        for node in nodes {
            if let parentId = node.parentId, !parentId.isEmpty {
                byParent[parentId, default: []].append(node)
            } else if let prefix = node.id.split(separator: ":").first.map(String.init) {
                rootsByPrefix[prefix, default: []].append(node)
            }
        }

        for key in byParent.keys {
            byParent[key]?.sort { $0.index < $1.index }
        }
        for key in rootsByPrefix.keys {
            rootsByPrefix[key]?.sort { $0.index < $1.index }
        }
    }

    /// Ordered children to write under `parentId`, or the roots of `prefix`
    /// when `parentId` is nil.
    ///
    /// Mirrors the original predicate: a node is only considered under `prefix`
    /// if its id carries that root prefix.
    func children(prefix: String, parentId: String?) -> [BookmarkNode] {
        guard let parentId, !parentId.isEmpty else {
            return rootsByPrefix[prefix] ?? []
        }
        guard let candidates = byParent[parentId] else { return [] }
        let idPrefix = prefix + ":"
        return candidates.filter { $0.id.hasPrefix(idPrefix) }
    }
}
