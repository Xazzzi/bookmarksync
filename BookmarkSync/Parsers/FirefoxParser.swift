import Foundation
import SQLite

class FirefoxParser: BrowserParser {
    let filePath: URL
    
    init(filePath: URL) {
        self.filePath = filePath
    }
    
    func read() throws -> [BookmarkNode] {
        let tempDir = FileManager.default.temporaryDirectory
        let tempId = UUID().uuidString
        let tempDbPath = tempDir.appendingPathComponent("\(tempId)_places.sqlite")
        let tempWalPath = tempDir.appendingPathComponent("\(tempId)_places.sqlite-wal")
        let tempShmPath = tempDir.appendingPathComponent("\(tempId)_places.sqlite-shm")
        
        let originalDbPath = filePath
        let originalWalPath = URL(fileURLWithPath: filePath.path + "-wal")
        let originalShmPath = URL(fileURLWithPath: filePath.path + "-shm")
        
        try? FileManager.default.copyItem(at: originalDbPath, to: tempDbPath)
        try? FileManager.default.copyItem(at: originalWalPath, to: tempWalPath)
        try? FileManager.default.copyItem(at: originalShmPath, to: tempShmPath)
        
        defer {
            try? FileManager.default.removeItem(at: tempDbPath)
            try? FileManager.default.removeItem(at: tempWalPath)
            try? FileManager.default.removeItem(at: tempShmPath)
        }
        
        let db = try Connection(tempDbPath.path, readonly: true)
        
        let bookmarks = Table("moz_bookmarks")
        let places = Table("moz_places")
        
        let b_id = Expression<Int64>("id")
        let b_type = Expression<Int64>("type")
        let b_fk = Expression<Int64?>("fk")
        let b_parent = Expression<Int64>("parent")
        let b_title = Expression<String?>("title")
        let b_dateAdded = Expression<Int64>("dateAdded")
        let b_position = Expression<Int64>("position")
        
        let p_id = Expression<Int64>("id")
        let p_url = Expression<String?>("url")
        let p_title = Expression<String?>("title") // Added to get fallback title
        
        var result: [BookmarkNode] = []
        var idToPrefix: [Int64: String] = [:]
        
        idToPrefix[3] = "bookmark_bar"
        idToPrefix[5] = "other"
        
        // Use left outer join to include folders (which have no fk)
        let query = bookmarks.select(bookmarks[*], places[p_url], places[p_title])
            .join(.leftOuter, places, on: bookmarks[b_fk] == places[p_id])
        
        let rows = Array(try db.prepare(query))
        let sortedRows = rows.sorted {
            let p1 = $0[bookmarks[b_parent]]
            let p2 = $1[bookmarks[b_parent]]
            if p1 == p2 { return $0[bookmarks[b_position]] < $1[bookmarks[b_position]] }
            return p1 < p2
        }
        
        var idToTitle: [Int64: String] = [:]
        var idToParent: [Int64: Int64] = [:]
        
        for row in sortedRows {
            let id = row[bookmarks[b_id]]
            let title = row[bookmarks[b_title]] ?? row[places[p_title]] ?? "Unknown"
            let parent = row[bookmarks[b_parent]]
            
            idToTitle[id] = title
            idToParent[id] = parent
        }
        
        var idToPath: [Int64: String] = [:]
        idToPath[3] = "bookmark_bar"
        idToPath[5] = "other"
        
        var seenKeys: [String: Int] = [:]
        
        func getPath(for id: Int64) -> String {
            if let path = idToPath[id] { return path }
            if [1,2,4].contains(id) { return "other" }
            
            let parent = idToParent[id] ?? 5
            let title = idToTitle[id] ?? "Unknown"
            
            let parentPath = getPath(for: parent)
            let baseId = "\(parentPath):\(title)"
            
            let count = seenKeys[baseId, default: 0]
            seenKeys[baseId] = count + 1
            let path = count == 0 ? baseId : "\(baseId):dup\(count)"
            
            idToPath[id] = path
            return path
        }
        
        func isInvalid(id: Int64) -> Bool {
            if [1,4].contains(id) { return true }
            if let p = idToParent[id] {
                if [1,4].contains(p) { return true }
                if p > 5 { return isInvalid(id: p) }
            }
            return false
        }
        
        // Pre-warm paths to ensure deterministic dup counters for folders
        for row in sortedRows where row[bookmarks[b_type]] == 2 {
            if !isInvalid(id: row[bookmarks[b_id]]) {
                _ = getPath(for: row[bookmarks[b_id]])
            }
        }
        
        for row in sortedRows {
            let id = row[bookmarks[b_id]]
            let type = row[bookmarks[b_type]] // 1=leaf, 2=folder, 3=separator
            let parent = row[bookmarks[b_parent]]
            let title = row[bookmarks[b_title]] ?? row[places[p_title]] ?? "Unknown"
            let url = row[places[p_url]]
            
            if [1,2,3,4,5].contains(id) { continue }
            if type == 3 { continue } // Skip separators
            if isInvalid(id: id) { continue } // Skip tags and places roots
            
            let normalized = url != nil ? normalizeURL(url!) : title
            let parentPath = getPath(for: parent)
            
            let uniqueId: String
            if type == 2 {
                uniqueId = getPath(for: id)
            } else {
                let baseId = "\(parentPath):\(normalized)"
                let count = seenKeys[baseId, default: 0]
                seenKeys[baseId] = count + 1
                uniqueId = count == 0 ? baseId : "\(baseId):dup\(count)"
            }
            
            var parentUniqueId: String? = nil
            if parent > 5 {
                parentUniqueId = getPath(for: parent)
            }
            
            let bNode = BookmarkNode(
                id: uniqueId,
                title: title,
                url: url,
                type: type == 2 ? .folder : .leaf,
                parentId: parentUniqueId,
                mtime: Date(timeIntervalSince1970: Double(row[bookmarks[b_dateAdded]]) / 1_000_000),
                index: Int(row[bookmarks[b_position]])
            )
            result.append(bNode)
        }
        return result
    }
    
    private func hashURL(_ url: String) -> Int64 {
        var hash: UInt64 = 0
        for char in url.utf16 {
            hash = (hash &<< 5) &+ hash &+ UInt64(char)
        }
        return Int64(bitPattern: hash & 0x0000FFFFFFFFFFFF)
    }

    private func getOrCreatePlace(db: Connection, url: String, title: String) throws -> Int64 {
        let places = Table("moz_places")
        let p_id = Expression<Int64>("id")
        let p_url = Expression<String?>("url")
        let p_title = Expression<String?>("title")
        let p_guid = Expression<String>("guid")
        let p_hidden = Expression<Int>("hidden")
        let p_frecency = Expression<Int>("frecency")
        let p_url_hash = Expression<Int64>("url_hash")
        let p_foreign_count = Expression<Int>("foreign_count")
        
        if let row = try db.pluck(places.filter(p_url == url)) {
            let pid = row[p_id]
            try db.run(places.filter(p_id == pid).update(p_foreign_count <- row[p_foreign_count] + 1))
            return pid
        }
        
        let revHost = String((URL(string: url)?.host ?? "").reversed()) + "."
        let charset = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"
        let guid = String((0..<12).map { _ in charset.randomElement()! })
        
        let insert = places.insert(
            p_url <- url,
            p_title <- title,
            Expression<String>("rev_host") <- revHost,
            p_guid <- guid,
            p_hidden <- 0,
            p_frecency <- -1,
            p_url_hash <- hashURL(url),
            p_foreign_count <- 1
        )
        return try db.run(insert)
    }
    
    func write(nodes: [BookmarkNode]) throws {
        try performBackup()
        
        let strippedNodes = nodes.map { node in
            BookmarkNode(
                id: stripProfileSetPrefix(node.id),
                title: node.title,
                url: node.url,
                type: node.type,
                parentId: node.parentId.map { stripProfileSetPrefix($0) },
                mtime: node.mtime,
                index: node.index
            )
        }
        
        let db = try Connection(filePath.path, readonly: false)
        try db.execute("PRAGMA journal_mode=WAL;")
        
        let bookmarks = Table("moz_bookmarks")
        let b_id = Expression<Int64>("id")
        let b_type = Expression<Int64>("type")
        let b_fk = Expression<Int64?>("fk")
        let b_parent = Expression<Int64>("parent")
        let b_position = Expression<Int64>("position")
        let b_title = Expression<String?>("title")
        let b_dateAdded = Expression<Int64>("dateAdded")
        let b_lastModified = Expression<Int64>("lastModified")
        let b_guid = Expression<String>("guid")
        
        // 1. Recursive delete of old items from roots 3 and 5
        func deleteRecursive(parentId: Int64) throws {
            let children = try db.prepare(bookmarks.filter(b_parent == parentId)).map { ($0[b_id], $0[b_type], $0[b_fk]) }
            for (childId, type, fk) in children {
                if type == 2 {
                    try deleteRecursive(parentId: childId)
                } else if type == 1, let fkId = fk {
                    // Decrement foreign_count safely
                    let places = Table("moz_places")
                    let p_id = Expression<Int64>("id")
                    let p_foreign_count = Expression<Int>("foreign_count")
                    if let row = try db.pluck(places.filter(p_id == fkId)) {
                        let newCount = max(0, row[p_foreign_count] - 1)
                        try db.run(places.filter(p_id == fkId).update(p_foreign_count <- newCount))
                    }
                }
                try db.run(bookmarks.filter(b_id == childId).delete())
            }
        }
        
        try db.transaction {
            try deleteRecursive(parentId: 3)
            try deleteRecursive(parentId: 5)
            
            // 2. Insert new tree
            func generateGUID() -> String {
                let charset = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"
                return String((0..<12).map { _ in charset.randomElement()! })
            }
            
            func insertTree(prefix: String, parentLogicalId: String?, parentDbId: Int64) throws {
                let children = strippedNodes.filter { $0.id.starts(with: prefix + ":") && $0.parentId == parentLogicalId }
                let sorted = children.sorted(by: { $0.index < $1.index })
                
                for (idx, child) in sorted.enumerated() {
                    var fk: Int64? = nil
                    if child.type == .leaf, let url = child.url {
                        fk = try getOrCreatePlace(db: db, url: url, title: child.title)
                    }
                    
                    let dateMicro = Int64(child.mtime.timeIntervalSince1970 * 1_000_000)
                    let insert = bookmarks.insert(
                        b_type <- child.type == .folder ? 2 : 1,
                        b_fk <- fk,
                        b_parent <- parentDbId,
                        b_position <- Int64(idx),
                        b_title <- child.title,
                        b_dateAdded <- dateMicro,
                        b_lastModified <- Int64(Date().timeIntervalSince1970 * 1_000_000),
                        b_guid <- generateGUID()
                    )
                    let newId = try db.run(insert)
                    
                    if child.type == .folder {
                        try insertTree(prefix: prefix, parentLogicalId: child.id, parentDbId: newId)
                    }
                }
            }
            
            try insertTree(prefix: "bookmark_bar", parentLogicalId: nil, parentDbId: 3)
            try insertTree(prefix: "other", parentLogicalId: nil, parentDbId: 5)
        }
    }
}
