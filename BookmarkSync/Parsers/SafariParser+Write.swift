import Foundation

extension SafariParser {
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
        var root = try PropertyListSerialization.propertyList(from: data, options: .mutableContainersAndLeaves, format: nil) as! [String: Any]
        var rootChildren = root["Children"] as? [[String: Any]] ?? []
        
        var originalMapByTopologicalId: [String: String] = [:]
        var originalMapByUrl: [String: String] = [:]
        var originalMapByName: [String: [String]] = [:]
        var originalNodesByUuid: [String: [String: Any]] = [:]
        var parentUuidMap: [String: String] = [:]
        var existingDeletedFolder: [String: Any]? = nil
        var usedUuids: Set<String> = []
        var seenKeys: [String: Int] = [:]
        
        func traverseOriginal(nodes: [[String: Any]], prefix: String, parentId: String?, parentUuid: String?) {
            for node in nodes {
                let name = node["Title"] as? String ?? ""
                if name == "Deleted by BookmarkSync" && parentId == nil {
                    existingDeletedFolder = node
                    continue
                }
                
                let type = node["WebBookmarkType"] as? String
                let url = type == "WebBookmarkTypeLeaf" ? node["URLString"] as? String : nil
                
                let normalized = url != nil ? normalizeURL(url!) : name
                let baseId = parentId != nil ? "\(parentId!):\(normalized)" : "\(prefix):\(normalized)"
                
                let count = seenKeys[baseId, default: 0]
                seenKeys[baseId] = count + 1
                let uniqueId = count == 0 ? baseId : "\(baseId):dup\(count)"
                
                let uuid = node["WebBookmarkUUID"] as? String ?? UUID().uuidString
                originalNodesByUuid[uuid] = node
                if let pUuid = parentUuid {
                    parentUuidMap[uuid] = pUuid
                }
                
                originalMapByTopologicalId[uniqueId] = uuid
                if let u = url {
                    originalMapByUrl[normalizeURL(u)] = uuid
                } else {
                    originalMapByName[name, default: []].append(uuid)
                }
                
                if let children = node["Children"] as? [[String: Any]] {
                    traverseOriginal(nodes: children, prefix: prefix, parentId: uniqueId, parentUuid: uuid)
                }
            }
        }
        
        if profileName == "Default" {
            if let node = rootChildren.first(where: { ($0["Title"] as? String) == "BookmarksBar" }), let children = node["Children"] as? [[String: Any]] {
                traverseOriginal(nodes: children, prefix: "bookmark_bar", parentId: nil, parentUuid: nil)
            }
            if let node = rootChildren.first(where: { ($0["Title"] as? String) == "BookmarksMenu" }), let children = node["Children"] as? [[String: Any]] {
                traverseOriginal(nodes: children, prefix: "other", parentId: nil, parentUuid: nil)
            }
        } else {
            if let node = rootChildren.first(where: { ($0["Title"] as? String) == profileName }), let children = node["Children"] as? [[String: Any]] {
                traverseOriginal(nodes: children, prefix: "bookmark_bar", parentId: nil, parentUuid: nil)
            }
        }
        
        func buildTree(prefix: String, parentId: String?) -> [[String: Any]] {
            let childrenNodes = strippedNodes.filter { $0.id.starts(with: prefix + ":") && $0.parentId == parentId }
            let sortedChildren = childrenNodes.sorted(by: { $0.index < $1.index })
            return sortedChildren.map { node in
                var uuid = originalMapByTopologicalId[node.id]
                if uuid == nil {
                    if let url = node.url {
                        uuid = originalMapByUrl[normalizeURL(url)]
                    } else {
                        if var origs = originalMapByName[node.title], !origs.isEmpty {
                            uuid = origs.removeFirst()
                            originalMapByName[node.title] = origs
                        }
                    }
                }
                
                let finalUuid = uuid ?? UUID().uuidString
                usedUuids.insert(finalUuid)
                
                var dict: [String: Any] = [
                    "Title": node.title,
                    "WebBookmarkUUID": finalUuid
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
        var bMenuChildren = buildTree(prefix: "other", parentId: nil)
        
        var newlyDeleted: [[String: Any]] = []
        for (uuid, origDict) in originalNodesByUuid {
            if !usedUuids.contains(uuid) {
                let pUuid = parentUuidMap[uuid]
                if pUuid == nil || usedUuids.contains(pUuid!) {
                    newlyDeleted.append(origDict)
                }
            }
        }
        
        if existingDeletedFolder != nil || !newlyDeleted.isEmpty {
            var deletedFolder = existingDeletedFolder ?? [
                "Title": "Deleted by BookmarkSync",
                "WebBookmarkType": "WebBookmarkTypeList",
                "WebBookmarkUUID": UUID().uuidString,
                "Children": [[String: Any]]()
            ]
            var deletedChildren = deletedFolder["Children"] as? [[String: Any]] ?? []
            deletedChildren.append(contentsOf: newlyDeleted)
            deletedFolder["Children"] = deletedChildren
            
            bMenuChildren.append(deletedFolder)
        }
        
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
