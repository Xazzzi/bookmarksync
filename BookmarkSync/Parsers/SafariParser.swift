import Foundation

class SafariParser: BrowserParser {
    let filePath: URL
    let profileName: String
    
    init(filePath: URL, profileName: String = "Default") {
        self.filePath = filePath
        self.profileName = profileName
    }
    
    func read() throws -> [BookmarkNode] {
        let data = try Data(contentsOf: filePath)
        guard let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let rootChildren = plist["Children"] as? [[String: Any]] else {
            return []
        }
        
        var result: [BookmarkNode] = []
        var seenKeys: [String: Int] = [:]
        
        if profileName == "Default" {
            for rootChild in rootChildren {
                let title = rootChild["Title"] as? String ?? ""
                if title == "BookmarksBar" || title == "BookmarksMenu" {
                    let prefix = title == "BookmarksBar" ? "bookmark_bar" : "other"
                    if let children = rootChild["Children"] as? [[String: Any]] {
                        for (i, child) in children.enumerated() {
                            if (child["Title"] as? String) == "Deleted by BookmarkSync" { continue }
                            result.append(contentsOf: parseNode(child, parentId: nil, prefix: prefix, index: i, seenKeys: &seenKeys))
                        }
                    }
                }
            }
        } else {
            if let profileNode = rootChildren.first(where: { ($0["Title"] as? String) == profileName }) {
                if let children = profileNode["Children"] as? [[String: Any]] {
                    for (i, child) in children.enumerated() {
                        if (child["Title"] as? String) == "Deleted by BookmarkSync" { continue }
                        result.append(contentsOf: parseNode(child, parentId: nil, prefix: "bookmark_bar", index: i, seenKeys: &seenKeys))
                    }
                }
            }
        }
        
        return result
    }
    
    private func parseNode(_ dict: [String: Any], parentId: String?, prefix: String, index: Int, seenKeys: inout [String: Int]) -> [BookmarkNode] {
        var nodes: [BookmarkNode] = []
        
        let type = dict["WebBookmarkType"] as? String
        let uriDict = dict["URIDictionary"] as? [String: Any]
        let title = dict["Title"] as? String ?? uriDict?["title"] as? String ?? "Unknown"
        
        if type == "WebBookmarkTypeList" {
            let normalized = title
            let baseId = parentId != nil ? "\(parentId!):\(normalized)" : "\(prefix):\(normalized)"
            let count = seenKeys[baseId, default: 0]
            seenKeys[baseId] = count + 1
            let uniqueId = count == 0 ? baseId : "\(baseId):dup\(count)"
            let node = BookmarkNode(id: uniqueId, title: title, url: nil, type: .folder, parentId: parentId, mtime: Date(timeIntervalSince1970: 0), index: index)
            nodes.append(node)
            
            if let children = dict["Children"] as? [[String: Any]] {
                for (i, child) in children.enumerated() {
                    nodes.append(contentsOf: parseNode(child, parentId: uniqueId, prefix: prefix, index: i, seenKeys: &seenKeys))
                }
            }
        } else if type == "WebBookmarkTypeLeaf" {
            let url = dict["URLString"] as? String
            let normalized = url != nil ? normalizeURL(url!) : title
            let baseId = parentId != nil ? "\(parentId!):\(normalized)" : "\(prefix):\(normalized)"
            let count = seenKeys[baseId, default: 0]
            seenKeys[baseId] = count + 1
            let uniqueId = count == 0 ? baseId : "\(baseId):dup\(count)"
            let node = BookmarkNode(id: uniqueId, title: title, url: url, type: .leaf, parentId: parentId, mtime: Date(timeIntervalSince1970: 0), index: index)
            nodes.append(node)
        }
        
        return nodes
    }
    

}
