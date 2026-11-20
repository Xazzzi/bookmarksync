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

    /// Keeps `Sync.ServerID` but drops the position and change state iCloud
    /// recorded, so `SafariBookmarksSyncAgent` treats the bookmark as edited.
    static func syncWithoutPosition(_ sync: [String: Any]) -> [String: Any] {
        var sync = sync
        sync.removeValue(forKey: "Data")
        sync.removeValue(forKey: "ServerData")
        return sync
    }

    /// Positions in `values` on one longest increasing subsequence. Siblings
    /// outside it are the fewest that must have moved to explain the new order.
    static func longestIncreasingSubsequence(_ values: [Int]) -> Set<Int> {
        var tails: [Int] = []
        var predecessors = Array(repeating: -1, count: values.count)
        for i in values.indices {
            var low = 0, high = tails.count
            while low < high {
                let mid = (low + high) / 2
                if values[tails[mid]] < values[i] { low = mid + 1 } else { high = mid }
            }
            if low > 0 { predecessors[i] = tails[low - 1] }
            if low == tails.count { tails.append(i) } else { tails[low] = i }
        }
        var result = Set<Int>()
        var cursor = tails.last ?? -1
        while cursor >= 0 {
            result.insert(cursor)
            cursor = predecessors[cursor]
        }
        return result
    }

    /// Takes Safari's own lock, so its sync agent neither interleaves with
    /// this write nor overwrites it. See `SafariBookmarksLock`.
    func write(nodes: [ParsedBookmark]) throws {
        try SafariBookmarksLock(bookmarksFile: filePath).withLock {
            try performBackup()
            try writeLocked(nodes: nodes)
        }
    }

    /// Rewrites the bookmarks in place. Entries matched to an existing one keep
    /// every key Safari stored, including iCloud's `Sync` state, which is
    /// reset only for entries that were renamed, moved or reordered.
    private func writeLocked(nodes: [ParsedBookmark]) throws {
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
        /// Every original leaf per URL, in file order: one URL can be bookmarked more than once.
        var originalMapByUrl: [String: [String]] = [:]
        var originalMapByName: [String: [String]] = [:]
        var originalNodesByUuid: [String: [String: Any]] = [:]
        var parentUuidMap: [String: String] = [:]
        /// Index among its original siblings, and the root of parentless entries.
        var originalIndexByUuid: [String: Int] = [:]
        var originalRootByUuid: [String: String] = [:]
        var existingDeletedFolder: [String: Any]? = nil
        var usedUuids: Set<String> = []
        var seenKeys: [String: Int] = [:]
        // Top-level entries of "other" that live directly at the plist root
        // rather than in the Bookmarks menu stay where they are.
        var rootLevelUuids: Set<String> = []

        func traverseOriginal(nodes: [[String: Any]], prefix: String, parentId: String?, parentUuid: String?) {
            for (index, node) in nodes.enumerated() {
                let name = Self.nodeTitle(in: node) ?? ""
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
                originalIndexByUuid[uuid] = index
                if let pUuid = parentUuid {
                    parentUuidMap[uuid] = pUuid
                } else {
                    originalRootByUuid[uuid] = prefix
                }

                originalMapByTopologicalId[uniqueId] = uuid
                if let u = url {
                    originalMapByUrl[normalizeURL(u), default: []].append(uuid)
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
        
        func hasType(_ original: [String: Any], _ type: BookmarkType) -> Bool {
            (original["WebBookmarkType"] as? String) == (type == .folder ? "WebBookmarkTypeList" : "WebBookmarkTypeLeaf")
        }

        // Reserve every exact position match first, so a bookmark that moved
        // cannot take the entry of an unmoved one with the same URL or name.
        var positionMatches: [String: String] = [:]
        var reservedUuids: Set<String> = []
        for node in strippedNodes {
            if let uuid = originalMapByTopologicalId[node.id], !reservedUuids.contains(uuid),
               let original = originalNodesByUuid[uuid], hasType(original, node.type) {
                positionMatches[node.id] = uuid
                reservedUuids.insert(uuid)
            }
        }

        func claim(_ candidates: [String], for node: ParsedBookmark) -> String? {
            candidates.first { uuid in
                !usedUuids.contains(uuid) && !reservedUuids.contains(uuid)
                    && originalNodesByUuid[uuid].map { hasType($0, node.type) } == true
            }
        }

        var keptSyncCount = 0
        var resetSyncCount = 0

        func buildTree(prefix: String, parentId: String?, parentUuid: String? = nil) -> [[String: Any]] {
            let siblings = childIndex.children(prefix: prefix, parentId: parentId)

            var uuids: [String] = []
            var sameParent: [Bool] = []
            for node in siblings {
                var uuid = positionMatches[node.id]
                if uuid == nil, let url = node.url {
                    let candidates = originalMapByUrl[normalizeURL(url)] ?? []
                    let sameTitle = candidates.filter { originalNodesByUuid[$0].flatMap(Self.nodeTitle(in:)) == node.title }
                    uuid = claim(sameTitle + candidates, for: node)
                } else if uuid == nil, node.type == .folder {
                    let named = originalMapByName[node.title] ?? []
                    uuid = claim(named.filter { parentUuidMap[$0] == parentUuid } + named, for: node)
                }
                let finalUuid = uuid ?? newUuid()
                usedUuids.insert(finalUuid)
                uuids.append(finalUuid)
                sameParent.append(uuid != nil && (parentUuid != nil
                    ? parentUuidMap[finalUuid] == parentUuid
                    : parentUuidMap[finalUuid] == nil && originalRootByUuid[finalUuid] == prefix))
            }

            // Of the siblings that stayed in this folder, the ones off the
            // longest run in original order are the ones that were reordered.
            let stayed = siblings.indices.filter { sameParent[$0] }
            let inOrder = Self.longestIncreasingSubsequence(stayed.map { originalIndexByUuid[uuids[$0]] ?? 0 })
            var reordered = Set<Int>()
            for (offset, i) in stayed.enumerated() where !inOrder.contains(offset) {
                reordered.insert(i)
            }

            return siblings.indices.map { i in
                let node = siblings[i]
                let uuid = uuids[i]
                let children = node.type == .folder ? buildTree(prefix: prefix, parentId: node.id, parentUuid: uuid) : nil

                guard var dict = originalNodesByUuid[uuid] else {
                    var dict: [String: Any] = [
                        "Title": node.title,
                        "WebBookmarkUUID": uuid
                    ]
                    if node.type == .folder {
                        dict["WebBookmarkType"] = "WebBookmarkTypeList"
                        dict["Children"] = children ?? []
                    } else {
                        dict["WebBookmarkType"] = "WebBookmarkTypeLeaf"
                        if let url = node.url {
                            dict["URLString"] = url
                            dict["URIDictionary"] = ["title": node.title]
                        }
                    }
                    return dict
                }

                let unchanged = sameParent[i] && !reordered.contains(i)
                    && Self.nodeTitle(in: dict) == node.title
                    && (node.type == .folder || (dict["URLString"] as? String) == node.url)
                dict["WebBookmarkUUID"] = uuid
                if node.type == .folder {
                    dict["Title"] = node.title
                    dict["Children"] = children ?? []
                } else {
                    // Safari keeps a leaf's title in URIDictionary only.
                    if dict["Title"] != nil { dict["Title"] = node.title }
                    if let url = node.url { dict["URLString"] = url }
                    var uri = dict["URIDictionary"] as? [String: Any] ?? [:]
                    uri["title"] = node.title
                    dict["URIDictionary"] = uri
                }
                if let sync = dict["Sync"] as? [String: Any] {
                    if unchanged {
                        keptSyncCount += 1
                    } else {
                        dict["Sync"] = Self.syncWithoutPosition(sync)
                        resetSyncCount += 1
                    }
                }
                return dict
            }
        }

        /// A deleted entry as moved into "Deleted by BookmarkSync": without
        /// descendants that still exist elsewhere, and without iCloud position state.
        func deletedSubtree(_ dict: [String: Any]) -> [String: Any]? {
            if let uuid = dict["WebBookmarkUUID"] as? String, usedUuids.contains(uuid) { return nil }
            var dict = dict
            if let sync = dict["Sync"] as? [String: Any] {
                dict["Sync"] = Self.syncWithoutPosition(sync)
            }
            if let children = dict["Children"] as? [[String: Any]] {
                dict["Children"] = children.compactMap(deletedSubtree)
            }
            return dict
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
                if pUuid == nil || usedUuids.contains(pUuid!), let deleted = deletedSubtree(origDict) {
                    newlyDeleted.append(deleted)
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
        SyncLog.event("Safari write: kept iCloud state on \(keptSyncCount) entries, reset it on \(resetSyncCount)")
    }
}
