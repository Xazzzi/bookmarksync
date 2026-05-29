import Foundation
import SQLite

class FirefoxParser: BrowserParser {
    let filePath: URL
    
    init(filePath: URL) {
        self.filePath = filePath
    }
    
    func read() throws -> [BookmarkNode] {
        let db = try Connection(filePath.path, readonly: true)
        
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
        
        var result: [BookmarkNode] = []
        var idToPrefix: [Int64: String] = [:]
        
        idToPrefix[3] = "bookmark_bar"
        idToPrefix[5] = "other"
        
        let query = bookmarks.select(bookmarks[*], places[p_url])
            .join(.leftOuter, places, on: bookmarks[b_fk] == places[p_id])
        
        let rows = Array(try db.prepare(query))
        var idToTitle: [Int64: String] = [:]
        var idToParent: [Int64: Int64] = [:]
        
        let sortedRows = rows.sorted {
            let p1 = $0[bookmarks[b_parent]]
            let p2 = $1[bookmarks[b_parent]]
            if p1 == p2 { return $0[bookmarks[b_position]] < $1[bookmarks[b_position]] }
            return p1 < p2
        }
        
        for row in sortedRows {
            let id = row[bookmarks[b_id]]
            let title = row[bookmarks[b_title]] ?? "Unknown"
            let parent = row[bookmarks[b_parent]]
            
            idToTitle[id] = title
            idToParent[id] = parent
            
            if row[bookmarks[b_type]] == 2 {
                let prefix = idToPrefix[parent] ?? "other"
                idToPrefix[id] = prefix
            }
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
        
        // Pre-warm paths to ensure deterministic dup counters for folders
        for row in sortedRows where row[bookmarks[b_type]] == 2 {
            _ = getPath(for: row[bookmarks[b_id]])
        }
        
        for row in sortedRows {
            let id = row[bookmarks[b_id]]
            let type = row[bookmarks[b_type]] // 1=leaf, 2=folder
            let parent = row[bookmarks[b_parent]]
            let title = row[bookmarks[b_title]] ?? "Unknown"
            let url = row[places[p_url]]
            
            if [1,2,3,4,5].contains(id) { continue }
            
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
    
    func write(nodes: [BookmarkNode]) throws {
        // Warning: Writing to places.sqlite safely requires either using the Firefox Places API
        // or performing complex relational inserts into moz_places and moz_bookmarks while
        // maintaining foreign keys and triggers.
        // For local sync MVP, we emit a log.
        print("Firefox write logic queued. Requires relational insertion.")
    }
}
