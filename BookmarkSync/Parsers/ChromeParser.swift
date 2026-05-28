import Foundation

struct ChromeBookmarks: Codable {
    let roots: ChromeRoots
}

struct ChromeRoots: Codable {
    let bookmark_bar: ChromeNode
    let other: ChromeNode
    let synced: ChromeNode
}

struct ChromeNode: Codable {
    let id: String
    let name: String
    let type: String // "folder" or "url"
    let url: String?
    let date_added: String
    let date_modified: String?
    let children: [ChromeNode]?
}

class ChromeParser: BrowserParser {
    let filePath: URL
    
    init(filePath: URL) {
        self.filePath = filePath
    }
    
    func read() throws -> [BookmarkNode] {
        let data = try Data(contentsOf: filePath)
        let bookmarks = try JSONDecoder().decode(ChromeBookmarks.self, from: data)
        var result: [BookmarkNode] = []
        
        func traverse(node: ChromeNode, prefix: String, parentId: String?) {
            let normalized = node.url != nil ? normalizeURL(node.url!) : node.name
            let uniqueId = "\(prefix):\(normalized)"
            let bNode = BookmarkNode(
                id: uniqueId,
                title: node.name,
                url: node.url,
                type: node.type == "folder" ? .folder : .leaf,
                parentId: parentId,
                mtime: webKitToDate(node.date_modified ?? node.date_added)
            )
            result.append(bNode)
            if let children = node.children {
                for child in children {
                    traverse(node: child, prefix: prefix, parentId: uniqueId)
                }
            }
        }
        
        if let children = bookmarks.roots.bookmark_bar.children {
            for child in children {
                traverse(node: child, prefix: "bookmark_bar", parentId: nil)
            }
        }
        if let children = bookmarks.roots.other.children {
            for child in children {
                traverse(node: child, prefix: "other", parentId: nil)
            }
        }
        if let children = bookmarks.roots.synced.children {
            for child in children {
                traverse(node: child, prefix: "synced", parentId: nil)
            }
        }
        
        return result
    }
    
    private func webKitToDate(_ webkitStr: String) -> Date {
        guard let micros = Int64(webkitStr) else { return Date() }
        let seconds = Double(micros) / 1_000_000 - 11644473600
        return Date(timeIntervalSince1970: seconds)
    }
    
    private func dateToWebKit(_ date: Date) -> String {
        let seconds = date.timeIntervalSince1970 + 11644473600
        let micros = Int64(seconds * 1_000_000)
        return String(micros)
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
                mtime: node.mtime
            )
        }
        
        func buildTree(prefix: String, parentId: String?) -> [[String: Any]] {
            let children = strippedNodes.filter { $0.id.starts(with: prefix + ":") && $0.parentId == parentId }
            return children.map { node in
                var dict: [String: Any] = [
                    "id": node.id,
                    "name": node.title,
                    "type": node.type == .folder ? "folder" : "url"
                ]
                if let url = node.url {
                    dict["url"] = url
                }
                dict["date_added"] = dateToWebKit(node.mtime)
                dict["date_modified"] = dateToWebKit(Date())
                if node.type == .folder {
                    dict["children"] = buildTree(prefix: prefix, parentId: node.id)
                }
                return dict
            }
        }
        
        let data = try Data(contentsOf: filePath)
        guard var root = try JSONSerialization.jsonObject(with: data, options: .mutableContainers) as? [String: Any] else {
            throw NSError(domain: "ChromeParser", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to parse JSON"])
        }
        
        var roots = root["roots"] as? [String: Any] ?? [:]
        
        var bookmarkBar = roots["bookmark_bar"] as? [String: Any] ?? [:]
        bookmarkBar["children"] = buildTree(prefix: "bookmark_bar", parentId: nil)
        roots["bookmark_bar"] = bookmarkBar
        
        var other = roots["other"] as? [String: Any] ?? [:]
        other["children"] = buildTree(prefix: "other", parentId: nil)
        roots["other"] = other
        
        var synced = roots["synced"] as? [String: Any] ?? [:]
        synced["children"] = buildTree(prefix: "synced", parentId: nil)
        roots["synced"] = synced
        
        root["roots"] = roots
        
        // Remove checksum so Chrome automatically recalculates it on startup
        root.removeValue(forKey: "checksum")
        
        let outData = try JSONSerialization.data(withJSONObject: root, options: .prettyPrinted)
        try outData.write(to: filePath, options: .atomic)
    }
}
