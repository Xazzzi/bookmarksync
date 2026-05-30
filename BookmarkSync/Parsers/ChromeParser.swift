import Foundation



class ChromeParser: BrowserParser {
    let filePath: URL
    
    init(filePath: URL) {
        self.filePath = filePath
    }
    
    func read() throws -> [BookmarkNode] {
        let data = try Data(contentsOf: filePath)
        let bookmarks = try JSONDecoder().decode(ChromeBookmarks.self, from: data)
        var result: [BookmarkNode] = []
        
        var seenKeys: [String: Int] = [:]
        
        func traverse(node: ChromeNode, prefix: String, parentId: String?, index: Int) {
            if node.name == "Deleted by BookmarkSync" && parentId == nil { return }
            
            let normalized = node.url != nil ? normalizeURL(node.url!) : node.name
            let baseId = parentId != nil ? "\(parentId!):\(normalized)" : "\(prefix):\(normalized)"
            let count = seenKeys[baseId, default: 0]
            seenKeys[baseId] = count + 1
            let uniqueId = count == 0 ? baseId : "\(baseId):dup\(count)"
            let bNode = BookmarkNode(
                id: uniqueId,
                title: node.name,
                url: node.url,
                type: node.type == "folder" ? .folder : .leaf,
                parentId: parentId,
                mtime: webKitToDate(node.date_modified ?? node.date_added),
                index: index
            )
            result.append(bNode)
            if let children = node.children {
                for (i, child) in children.enumerated() {
                    traverse(node: child, prefix: prefix, parentId: uniqueId, index: i)
                }
            }
        }
        
        if let children = bookmarks.roots.bookmark_bar.children {
            for (i, child) in children.enumerated() {
                traverse(node: child, prefix: "bookmark_bar", parentId: nil, index: i)
            }
        }
        if let children = bookmarks.roots.other.children {
            for (i, child) in children.enumerated() {
                traverse(node: child, prefix: "other", parentId: nil, index: i)
            }
        }
        if let children = bookmarks.roots.synced.children {
            for (i, child) in children.enumerated() {
                traverse(node: child, prefix: "synced", parentId: nil, index: i)
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
                mtime: node.mtime,
                index: node.index
            )
        }
        
        let data = try Data(contentsOf: filePath)
        guard var root = try JSONSerialization.jsonObject(with: data, options: .mutableContainers) as? [String: Any] else {
            throw NSError(domain: "ChromeParser", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to parse JSON"])
        }
        
        var roots = root["roots"] as? [String: Any] ?? [:]
        
        var originalMapByTopologicalId: [String: [String: Any]] = [:]
        var originalMapByUrl: [String: [String: Any]] = [:]
        var originalMapByName: [String: [[String: Any]]] = [:]
        var originalNodesById: [String: [String: Any]] = [:]
        var parentIdMap: [String: String] = [:]
        var existingDeletedFolder: [String: Any]? = nil
        var usedOriginalIds: Set<String> = []
        var seenKeys: [String: Int] = [:]
        var maxId: Int = 0
        
        func traverseOriginal(nodes: [[String: Any]], prefix: String, parentId: String?) {
            for node in nodes {
                if let name = node["name"] as? String, name == "Deleted by BookmarkSync", parentId == nil {
                    existingDeletedFolder = node
                    continue
                }
                
                let idStr = node["id"] as? String ?? ""
                if let idInt = Int(idStr) {
                    maxId = max(maxId, idInt)
                }
                
                originalNodesById[idStr] = node
                if let pId = parentId {
                    parentIdMap[idStr] = pId
                }
                
                let name = node["name"] as? String ?? ""
                let url = node["url"] as? String
                let normalized = url != nil ? normalizeURL(url!) : name
                let baseId = parentId != nil ? "\(parentId!):\(normalized)" : "\(prefix):\(normalized)"
                
                let count = seenKeys[baseId, default: 0]
                seenKeys[baseId] = count + 1
                let uniqueId = count == 0 ? baseId : "\(baseId):dup\(count)"
                
                originalMapByTopologicalId[uniqueId] = node
                if let u = url {
                    originalMapByUrl[normalizeURL(u)] = node
                } else {
                    originalMapByName[name, default: []].append(node)
                }
                
                if let children = node["children"] as? [[String: Any]] {
                    traverseOriginal(nodes: children, prefix: prefix, parentId: idStr)
                }
            }
        }
        
        if let bookmarkBar = roots["bookmark_bar"] as? [String: Any], let children = bookmarkBar["children"] as? [[String: Any]] {
            traverseOriginal(nodes: children, prefix: "bookmark_bar", parentId: nil)
        }
        if let other = roots["other"] as? [String: Any], let children = other["children"] as? [[String: Any]] {
            traverseOriginal(nodes: children, prefix: "other", parentId: nil)
        }
        if let synced = roots["synced"] as? [String: Any], let children = synced["children"] as? [[String: Any]] {
            traverseOriginal(nodes: children, prefix: "synced", parentId: nil)
        }
        
        func buildTree(prefix: String, parentId: String?) -> [[String: Any]] {
            let children = strippedNodes.filter { $0.id.starts(with: prefix + ":") && $0.parentId == parentId }
            let sortedChildren = children.sorted(by: { $0.index < $1.index })
            return sortedChildren.map { node in
                var dict: [String: Any] = originalMapByTopologicalId[node.id] ?? [:]
                
                if dict.isEmpty {
                    if let url = node.url {
                        if let orig = originalMapByUrl[normalizeURL(url)] {
                            dict = orig
                        }
                    } else {
                        if var origs = originalMapByName[node.title], !origs.isEmpty {
                            dict = origs.removeFirst()
                            originalMapByName[node.title] = origs
                        }
                    }
                }
                
                if !dict.isEmpty, let idStr = dict["id"] as? String {
                    usedOriginalIds.insert(idStr)
                }
                
                if dict["id"] == nil {
                    maxId += 1
                    dict["id"] = String(maxId)
                }
                if dict["guid"] == nil {
                    dict["guid"] = UUID().uuidString
                }
                
                dict["name"] = node.title
                dict["type"] = node.type == .folder ? "folder" : "url"
                if let url = node.url {
                    dict["url"] = url
                } else {
                    dict.removeValue(forKey: "url")
                }
                if dict["date_added"] == nil {
                    dict["date_added"] = dateToWebKit(node.mtime)
                }
                dict["date_modified"] = dateToWebKit(Date())
                
                if node.type == .folder {
                    dict["children"] = buildTree(prefix: prefix, parentId: node.id)
                } else {
                    dict.removeValue(forKey: "children")
                }
                return dict
            }
        }
        
        var bookmarkBar = roots["bookmark_bar"] as? [String: Any] ?? [:]
        bookmarkBar["children"] = buildTree(prefix: "bookmark_bar", parentId: nil)
        roots["bookmark_bar"] = bookmarkBar
        
        var other = roots["other"] as? [String: Any] ?? [:]
        other["children"] = buildTree(prefix: "other", parentId: nil)
        
        var newlyDeleted: [[String: Any]] = []
        for (idStr, origDict) in originalNodesById {
            if !usedOriginalIds.contains(idStr) {
                let pId = parentIdMap[idStr]
                if pId == nil || usedOriginalIds.contains(pId!) {
                    newlyDeleted.append(origDict)
                }
            }
        }
        
        if existingDeletedFolder != nil || !newlyDeleted.isEmpty {
            maxId += 1
            var deletedFolder = existingDeletedFolder ?? [
                "id": String(maxId),
                "guid": UUID().uuidString,
                "name": "Deleted by BookmarkSync",
                "type": "folder",
                "date_added": dateToWebKit(Date()),
                "date_modified": dateToWebKit(Date()),
                "children": [[String: Any]]()
            ]
            
            var deletedChildren = deletedFolder["children"] as? [[String: Any]] ?? []
            deletedChildren.append(contentsOf: newlyDeleted)
            deletedFolder["children"] = deletedChildren
            
            other["children"] = (other["children"] as? [[String: Any]] ?? []) + [deletedFolder]
        }
        roots["other"] = other
        
        var synced = roots["synced"] as? [String: Any] ?? [:]
        synced["children"] = buildTree(prefix: "synced", parentId: nil)
        roots["synced"] = synced
        
        root["roots"] = roots
        
        root.removeValue(forKey: "checksum")
        
        let outData = try JSONSerialization.data(withJSONObject: root, options: .prettyPrinted)
        try outData.write(to: filePath, options: .atomic)
    }
}
