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
        
        for row in rows {
            let id = row[bookmarks[b_id]]
            let title = row[bookmarks[b_title]] ?? "Unknown"
            idToTitle[id] = title
            
            let parent = row[bookmarks[b_parent]]
            let type = row[bookmarks[b_type]]
            
            if type == 2 {
                let prefix = idToPrefix[parent] ?? "other"
                idToPrefix[id] = prefix
            }
        }
        
        for row in rows {
            let id = row[bookmarks[b_id]]
            let type = row[bookmarks[b_type]] // 1=leaf, 2=folder
            let parent = row[bookmarks[b_parent]]
            let title = row[bookmarks[b_title]] ?? "Unknown"
            let url = row[places[p_url]]
            
            let prefix = idToPrefix[parent] ?? "other"
            
            if [1,2,3,4,5].contains(id) { continue }
            
            let normalized = url != nil ? normalizeURL(url!) : title
            let uniqueId = "\(prefix):\(normalized)"
            
            var parentUniqueId: String? = nil
            if parent > 5 {
                let parentTitle = idToTitle[parent] ?? "Unknown"
                let parentPrefix = idToPrefix[parent] ?? prefix
                parentUniqueId = "\(parentPrefix):\(parentTitle)"
            }
            
            let bNode = BookmarkNode(
                id: uniqueId,
                title: title,
                url: url,
                type: type == 2 ? .folder : .leaf,
                parentId: parentUniqueId,
                mtime: Date(timeIntervalSince1970: Double(row[bookmarks[b_dateAdded]]) / 1_000_000)
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
