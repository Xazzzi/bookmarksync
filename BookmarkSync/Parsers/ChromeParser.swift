import Foundation



final class ChromeParser: BrowserParser {
    let filePath: URL
    
    init(filePath: URL) {
        self.filePath = filePath
    }
    
    func read() throws -> [ParsedBookmark] {
        let data = try Data(contentsOf: filePath)
        let bookmarks = try JSONDecoder().decode(ChromeBookmarks.self, from: data)
        var result: [ParsedBookmark] = []
        
        var seenKeys: [String: Int] = [:]
        
        func traverse(node: ChromeNode, prefix: String, parentId: String?, index: Int) {
            if node.name == "Deleted by BookmarkSync" && parentId == nil { return }
            
            let normalized = node.url != nil ? normalizeURL(node.url!) : node.name
            let baseId = parentId != nil ? "\(parentId!):\(normalized)" : "\(prefix):\(normalized)"
            let count = seenKeys[baseId, default: 0]
            seenKeys[baseId] = count + 1
            let uniqueId = count == 0 ? baseId : "\(baseId):dup\(count)"
            let bNode = ParsedBookmark(
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
    
    /// A guid in the form Chrome itself writes: lowercase canonical UUID.
    ///
    /// Chrome keys cloud sync on `guid`, and `UUID().uuidString` is UPPERCASE on
    /// Apple platforms. Writing an uppercase guid makes Chrome see a bookmark it
    /// has no record of, so it keeps its cloud copy AND adopts ours -- which is
    /// how a single bookmark becomes two. Every guid we mint must match the
    /// browser's own convention.
    private func newGuid() -> String {
        UUID().uuidString.lowercased()
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
        guard var root = try JSONSerialization.jsonObject(with: data, options: .mutableContainers) as? [String: Any] else {
            throw NSError(domain: "ChromeParser", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to parse JSON"])
        }
        
        var roots = root["roots"] as? [String: Any] ?? [:]
        
        var originalMapByTopologicalId: [String: [String: Any]] = [:]
        /// Originals keyed by "<parentId>:<normalizedURL>", each a queue.
        ///
        /// This is the cross-browser identity fallback: the same page saved under
        /// different names in different browsers still matches by URL. Scoped to
        /// the parent, because the engine's own node id is `parentId:url` -- a
        /// match from a different folder is a different bookmark. Held as a queue
        /// so several same-URL siblings consume distinct originals instead of all
        /// adopting one (which wrote colliding ids and guids).
        var originalMapByUrl: [String: [[String: Any]]] = [:]
        var originalMapByName: [String: [[String: Any]]] = [:]
        var originalNodesById: [String: [String: Any]] = [:]
        var parentIdMap: [String: String] = [:]
        var existingDeletedFolder: [String: Any]? = nil
        var usedOriginalIds: Set<String> = []
        var seenKeys: [String: Int] = [:]
        var maxId: Int = 0
        
        // `parentId` is Chrome's numeric id (used for tombstone parent checks);
        // `parentTopoId` is the title-path id the sync engine uses. Both are
        // needed: the URL scope must be keyed the engine's way to match.
        func traverseOriginal(nodes: [[String: Any]], prefix: String, parentId: String?, parentTopoId: String?) {
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
                let baseId = parentTopoId != nil ? "\(parentTopoId!):\(normalized)" : "\(prefix):\(normalized)"

                let count = seenKeys[baseId, default: 0]
                seenKeys[baseId] = count + 1
                let uniqueId = count == 0 ? baseId : "\(baseId):dup\(count)"

                originalMapByTopologicalId[uniqueId] = node
                if let u = url {
                    let scope = parentTopoId ?? "root:\(prefix)"
                    originalMapByUrl["\(scope):\(normalizeURL(u))", default: []].append(node)
                } else {
                    originalMapByName[name, default: []].append(node)
                }

                if let children = node["children"] as? [[String: Any]] {
                    traverseOriginal(nodes: children, prefix: prefix, parentId: idStr, parentTopoId: uniqueId)
                }
            }
        }
        
        if let bookmarkBar = roots["bookmark_bar"] as? [String: Any], let children = bookmarkBar["children"] as? [[String: Any]] {
            traverseOriginal(nodes: children, prefix: "bookmark_bar", parentId: nil, parentTopoId: nil)
        }
        if let other = roots["other"] as? [String: Any], let children = other["children"] as? [[String: Any]] {
            traverseOriginal(nodes: children, prefix: "other", parentId: nil, parentTopoId: nil)
        }
        if let synced = roots["synced"] as? [String: Any], let children = synced["children"] as? [[String: Any]] {
            traverseOriginal(nodes: children, prefix: "synced", parentId: nil, parentTopoId: nil)
        }
        
        func buildTree(prefix: String, parentId: String?) -> [[String: Any]] {
            let sortedChildren = childIndex.children(prefix: prefix, parentId: parentId)
            return sortedChildren.map { node in
                var dict: [String: Any] = originalMapByTopologicalId[node.id] ?? [:]

                // Never adopt an original node twice: Chrome requires ids and
                // guids to be unique, and a collision makes it discard or
                // re-create the node -- which is what surfaced as a bookmark
                // reappearing with a `:dup1` id on the next read.
                if let idStr = dict["id"] as? String, usedOriginalIds.contains(idStr) {
                    dict = [:]
                }

                if dict.isEmpty {
                    if let url = node.url {
                        // Match by URL within the same parent, so a bookmark
                        // renamed in another browser keeps its Chrome identity.
                        let scope = node.parentId ?? "root:\(prefix)"
                        let key = "\(scope):\(normalizeURL(url))"
                        if var candidates = originalMapByUrl[key] {
                            while let candidate = candidates.first {
                                candidates.removeFirst()
                                guard let cId = candidate["id"] as? String,
                                      !usedOriginalIds.contains(cId) else { continue }
                                dict = candidate
                                break
                            }
                            originalMapByUrl[key] = candidates
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
                    dict["guid"] = newGuid()
                }
                
                // Repair guids an earlier build wrote in uppercase; leaving them
                // mixed keeps the duplication going on every subsequent sync.
                if let existing = dict["guid"] as? String, existing != existing.lowercased() {
                    dict["guid"] = existing.lowercased()
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
        
        // Build EVERY root before deciding what was deleted. `buildTree` is what
        // populates `usedOriginalIds`, so computing tombstones while any root is
        // still unbuilt marks that root's bookmarks as deleted: the `synced`
        // tree used to be built after this check, so every synced bookmark was
        // copied into "Deleted by BookmarkSync" on every single write, and the
        // copies accumulated without bound.
        var bookmarkBar = roots["bookmark_bar"] as? [String: Any] ?? [:]
        bookmarkBar["children"] = buildTree(prefix: "bookmark_bar", parentId: nil)
        roots["bookmark_bar"] = bookmarkBar

        var other = roots["other"] as? [String: Any] ?? [:]
        let otherChildren = buildTree(prefix: "other", parentId: nil)

        var synced = roots["synced"] as? [String: Any] ?? [:]
        synced["children"] = buildTree(prefix: "synced", parentId: nil)
        roots["synced"] = synced

        // Anything the original file contained that no root re-used has been
        // deleted. Only tombstone the topmost such node: if a folder is gone its
        // children are gone with it and are already inside the copy we keep.
        var newlyDeleted: [[String: Any]] = []
        for (idStr, origDict) in originalNodesById {
            if !usedOriginalIds.contains(idStr) {
                let pId = parentIdMap[idStr]
                if pId == nil || usedOriginalIds.contains(pId!) {
                    newlyDeleted.append(origDict)
                }
            }
        }

        // Keep ids stable so a bookmark is not re-tombstoned on the next write.
        let alreadyTombstonedIds = Set(
            ((existingDeletedFolder?["children"] as? [[String: Any]]) ?? [])
                .compactMap { $0["id"] as? String }
        )
        newlyDeleted.removeAll { node in
            guard let id = node["id"] as? String else { return false }
            return alreadyTombstonedIds.contains(id)
        }

        other["children"] = otherChildren

        if existingDeletedFolder != nil || !newlyDeleted.isEmpty {
            maxId += 1
            var deletedFolder = existingDeletedFolder ?? [
                "id": String(maxId),
                "guid": newGuid(),
                "name": "Deleted by BookmarkSync",
                "type": "folder",
                "date_added": dateToWebKit(Date()),
                "date_modified": dateToWebKit(Date()),
                "children": [[String: Any]]()
            ]

            var deletedChildren = deletedFolder["children"] as? [[String: Any]] ?? []
            deletedChildren.append(contentsOf: newlyDeleted)
            deletedFolder["children"] = deletedChildren

            other["children"] = otherChildren + [deletedFolder]
        }
        roots["other"] = other
        
        root["roots"] = roots
        
        root.removeValue(forKey: "checksum")
        
        let outData = try JSONSerialization.data(withJSONObject: root, options: .prettyPrinted)
        try outData.write(to: filePath, options: .atomic)
    }
}
