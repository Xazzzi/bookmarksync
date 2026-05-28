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
        
        if profileName == "Default" {
            for rootChild in rootChildren {
                let title = rootChild["Title"] as? String ?? ""
                if title == "BookmarksBar" || title == "BookmarksMenu" {
                    let prefix = title == "BookmarksBar" ? "bookmark_bar" : "other"
                    if let children = rootChild["Children"] as? [[String: Any]] {
                        for child in children {
                            result.append(contentsOf: parseNode(child, parentId: nil, prefix: prefix))
                        }
                    }
                }
            }
        } else {
            if let profileNode = rootChildren.first(where: { ($0["Title"] as? String) == profileName }) {
                if let children = profileNode["Children"] as? [[String: Any]] {
                    for child in children {
                        result.append(contentsOf: parseNode(child, parentId: nil, prefix: "bookmark_bar"))
                    }
                }
            }
        }
        
        return result
    }
    
    private func parseNode(_ dict: [String: Any], parentId: String?, prefix: String) -> [BookmarkNode] {
        var nodes: [BookmarkNode] = []
        
        let type = dict["WebBookmarkType"] as? String
        let uriDict = dict["URIDictionary"] as? [String: Any]
        let title = dict["Title"] as? String ?? uriDict?["title"] as? String ?? "Unknown"
        let uuid = dict["WebBookmarkUUID"] as? String ?? UUID().uuidString
        
        if type == "WebBookmarkTypeList" {
            let normalized = title
            let uniqueId = "\(prefix):\(normalized)"
            let node = BookmarkNode(id: uniqueId, title: title, url: nil, type: .folder, parentId: parentId, mtime: Date(timeIntervalSince1970: 0))
            nodes.append(node)
            
            if let children = dict["Children"] as? [[String: Any]] {
                for child in children {
                    nodes.append(contentsOf: parseNode(child, parentId: uniqueId, prefix: prefix))
                }
            }
        } else if type == "WebBookmarkTypeLeaf" {
            let url = dict["URLString"] as? String
            let normalized = url != nil ? normalizeURL(url!) : title
            let uniqueId = "\(prefix):\(normalized)"
            let node = BookmarkNode(id: uniqueId, title: title, url: url, type: .leaf, parentId: parentId, mtime: Date(timeIntervalSince1970: 0))
            nodes.append(node)
        }
        
        return nodes
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
        
        let data = try Data(contentsOf: filePath)
        var root = try PropertyListSerialization.propertyList(from: data, options: .mutableContainersAndLeaves, format: nil) as! [String: Any]
        var rootChildren = root["Children"] as? [[String: Any]] ?? []
        
        func buildTree(prefix: String, parentId: String?) -> [[String: Any]] {
            let childrenNodes = strippedNodes.filter { $0.id.starts(with: prefix + ":") && $0.parentId == parentId }
            return childrenNodes.map { node in
                var dict: [String: Any] = [
                    "Title": node.title,
                    "WebBookmarkUUID": UUID().uuidString
                ]
                if node.type == .folder {
                    dict["WebBookmarkType"] = "WebBookmarkTypeList"
                    dict["Children"] = buildTree(prefix: prefix, parentId: node.id)
                } else {
                    dict["WebBookmarkType"] = "WebBookmarkTypeLeaf"
                    if let url = node.url {
                        dict["URLString"] = url
                        dict["URIDictionary"] = ["title": node.title]
                    }
                }
                return dict
            }
        }
        
        let fBarChildren = buildTree(prefix: "bookmark_bar", parentId: nil)
        let bMenuChildren = buildTree(prefix: "other", parentId: nil)
        
        if profileName == "Default" {
            if let idx = rootChildren.firstIndex(where: { ($0["Title"] as? String) == "BookmarksBar" }) {
                var bar = rootChildren[idx]
                bar["Children"] = fBarChildren
                rootChildren[idx] = bar
            } else {
                rootChildren.append(["Title": "BookmarksBar", "WebBookmarkType": "WebBookmarkTypeList", "Children": fBarChildren])
            }
            
            if let idx = rootChildren.firstIndex(where: { ($0["Title"] as? String) == "BookmarksMenu" }) {
                var menu = rootChildren[idx]
                menu["Children"] = bMenuChildren
                rootChildren[idx] = menu
            } else {
                rootChildren.append(["Title": "BookmarksMenu", "WebBookmarkType": "WebBookmarkTypeList", "Children": bMenuChildren])
            }
        } else {
            if let idx = rootChildren.firstIndex(where: { ($0["Title"] as? String) == profileName }) {
                var profileNode = rootChildren[idx]
                profileNode["Children"] = fBarChildren
                rootChildren[idx] = profileNode
            } else {
                rootChildren.append([
                    "Title": profileName,
                    "WebBookmarkType": "WebBookmarkTypeList",
                    "Children": fBarChildren,
                    "WebBookmarkUUID": UUID().uuidString
                ])
            }
        }
        
        root["Children"] = rootChildren
        let outData = try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
        try outData.write(to: filePath, options: .atomic)
    }
}
