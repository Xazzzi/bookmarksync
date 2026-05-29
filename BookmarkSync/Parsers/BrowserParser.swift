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
