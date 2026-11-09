import Foundation

extension SafariParser {
    /// A UUID in the form Safari itself writes: UPPERCASE canonical.
    ///
    /// The inverse of Chrome's convention -- verified against a real
    /// Bookmarks.plist. `UUID().uuidString` is already uppercase on Apple
    /// platforms, so this is a named assertion of that requirement rather than a
    /// transformation: it keeps the intent explicit and survives anyone
    /// "tidying" the two parsers to match each other.
    private func newUuid() -> String {
        UUID().uuidString.uppercased()
    }

    func write(nodes: [ParsedBookmark]) throws {
        try performBackup()
        
        let strippedNodes = nodes.map { node in
            ParsedBookmark(
                id: stripProfileSetPrefix(node.id),
                title: node.title,
                url: node.url,
                type: node.type,
                parentId: node.parentId.map { stripProfileSetPrefix($0) },
                mtime: node.mtime,
                index: node.index
            )
        }

        // Group siblings once; the recursive tree build below then does O(1)
        // lookups instead of rescanning every node per folder.
        let childIndex = BookmarkChildIndex(strippedNodes: strippedNodes)
        
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
        // Top-level entries of "other" that live directly at the plist root
        // rather than in the Bookmarks menu stay where they are.
        var rootLevelUuids: Set<String> = []
        
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
                
                let uuid = node["WebBookmarkUUID"] as? String ?? newUuid()
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
            // Same order as `read`: the menu, then the user's top-level entries.
            let menuChildren = rootChildren.first(where: { ($0["Title"] as? String) == "BookmarksMenu" })?["Children"] as? [[String: Any]] ?? []
            traverseOriginal(nodes: menuChildren, prefix: BookmarkRoots.other, parentId: nil, parentUuid: nil)
            let rootEntries = rootChildren.filter(Self.isUserRootEntry)
            traverseOriginal(nodes: rootEntries, prefix: BookmarkRoots.other, parentId: nil, parentUuid: nil)
            for entry in rootEntries {
                if let uuid = entry["WebBookmarkUUID"] as? String { rootLevelUuids.insert(uuid) }
            }
            if let mobile = rootChildren.first(where: Self.isMobileFolder), let children = mobile["Children"] as? [[String: Any]] {
                traverseOriginal(nodes: children, prefix: BookmarkRoots.mobile, parentId: nil, parentUuid: nil)
            }
        } else {
            if let node = rootChildren.first(where: { ($0["Title"] as? String) == profileName }), let children = node["Children"] as? [[String: Any]] {
                traverseOriginal(nodes: children, prefix: "bookmark_bar", parentId: nil, parentUuid: nil)
            }
        }
        
        func buildTree(prefix: String, parentId: String?) -> [[String: Any]] {
            let sortedChildren = childIndex.children(prefix: prefix, parentId: parentId)
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
                
                let finalUuid = uuid ?? newUuid()
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
        let otherChildren = buildTree(prefix: "other", parentId: nil)
        let isRootLevel: ([String: Any]) -> Bool = { entry in
            (entry["WebBookmarkUUID"] as? String).map { rootLevelUuids.contains($0) } ?? false
        }
        var bMenuChildren = otherChildren.filter { !isRootLevel($0) }
        let rootLevelChildren = otherChildren.filter(isRootLevel)
        let mobileChildren = profileName == "Default" ? buildTree(prefix: BookmarkRoots.mobile, parentId: nil) : []
        
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
                "WebBookmarkUUID": newUuid(),
                "Children": [[String: Any]]()
            ]
            var deletedChildren = deletedFolder["Children"] as? [[String: Any]] ?? []
            deletedChildren.append(contentsOf: newlyDeleted)
            deletedFolder["Children"] = deletedChildren
            
            bMenuChildren.append(deletedFolder)
        }
        
        if profileName == "Default" {
            // Rebuild the top level in place: Safari's own entries keep their
            // positions, the user's top-level entries go back where the first
            // of them was, and the mobile folder is created only when needed.
            var newRootChildren: [[String: Any]] = []
            var placedBar = false, placedMenu = false, placedRootLevel = false, placedMobile = false
            for entry in rootChildren {
                let title = entry["Title"] as? String
                if title == "BookmarksBar" && !placedBar {
                    var bar = entry
                    bar["Children"] = fBarChildren
                    newRootChildren.append(bar)
                    placedBar = true
                } else if title == "BookmarksMenu" && !placedMenu {
                    var menu = entry
                    menu["Children"] = bMenuChildren
                    newRootChildren.append(menu)
                    placedMenu = true
                } else if Self.isMobileFolder(entry) && !placedMobile {
                    var mobile = entry
                    mobile["Children"] = mobileChildren
                    newRootChildren.append(mobile)
                    placedMobile = true
                } else if Self.isUserRootEntry(entry) {
                    if !placedRootLevel {
                        newRootChildren.append(contentsOf: rootLevelChildren)
                        placedRootLevel = true
                    }
                } else {
                    newRootChildren.append(entry)
                }
            }
            if !placedRootLevel {
                newRootChildren.append(contentsOf: rootLevelChildren)
            }
            if !placedBar {
                newRootChildren.append(["Title": "BookmarksBar", "WebBookmarkType": "WebBookmarkTypeList", "Children": fBarChildren])
            }
            if !placedMenu {
                newRootChildren.append(["Title": "BookmarksMenu", "WebBookmarkType": "WebBookmarkTypeList", "Children": bMenuChildren])
            }
            if !placedMobile && !mobileChildren.isEmpty {
                newRootChildren.append([
                    "Title": Self.newMobileFolderTitle,
                    "WebBookmarkType": "WebBookmarkTypeList",
                    "WebBookmarkUUID": newUuid(),
                    "Children": mobileChildren
                ])
            }
            rootChildren = newRootChildren
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
                    "WebBookmarkUUID": newUuid()
                ])
            }
        }
        
        root["Children"] = rootChildren
        let outData = try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
        try outData.write(to: filePath, options: .atomic)
    }
}
