import Foundation

final class SafariParser: BrowserParser {
    let filePath: URL
    let profileName: String
    
    init(filePath: URL, profileName: String = "Default") {
        self.filePath = filePath
        self.profileName = profileName
    }
    
    static let deletedFolderTitle = "Deleted by BookmarkSync"

    /// Top-level entries that are Safari's own, not the user's bookmarks.
    static let systemRootTitles: Set<String> = ["BookmarksBar", "BookmarksMenu", "com.apple.ReadingList", "History"]

    /// The top-level folder that holds Chromium's mobile bookmarks in Safari,
    /// which has no mobile root of its own. Either name is recognised; a new
    /// folder is named in the user's language.
    static let mobileFolderTitles: Set<String> = ["移动设备书签", "Mobile Bookmarks"]

    static var newMobileFolderTitle: String {
        Locale.preferredLanguages.first?.hasPrefix("zh") == true ? "移动设备书签" : "Mobile Bookmarks"
    }

    static func isMobileFolder(_ entry: [String: Any]) -> Bool {
        entry["WebBookmarkType"] as? String == "WebBookmarkTypeList"
            && mobileFolderTitles.contains(entry["Title"] as? String ?? "")
    }

    /// A folder or bookmark the user keeps directly at the top level of
    /// Safari's bookmarks (beside Favorites). Safari stores these as siblings of
    /// its fixed roots; they are read as part of "other".
    static func isUserRootEntry(_ entry: [String: Any]) -> Bool {
        let type = entry["WebBookmarkType"] as? String
        guard type == "WebBookmarkTypeList" || type == "WebBookmarkTypeLeaf" else { return false }
        if entry["ShouldOmitFromUI"] as? Bool == true { return false }
        let title = entry["Title"] as? String ?? ""
        if title.isEmpty || title.hasPrefix("com.apple.") { return false }
        if systemRootTitles.contains(title) || title == deletedFolderTitle { return false }
        return !isMobileFolder(entry)
    }

    func read() throws -> [ParsedBookmark] {
        let data = try Data(contentsOf: filePath)
        guard let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let rootChildren = plist["Children"] as? [[String: Any]] else {
            throw BookmarkParseError.unexpectedStructure("Safari bookmarks have no top-level Children")
        }
        
        var result: [ParsedBookmark] = []
        var seenKeys: [String: Int] = [:]
        
        if profileName == "Default" {
            let hasKnownRoot = rootChildren.contains { rootChild in
                let title = rootChild["Title"] as? String
                return title == "BookmarksBar" || title == "BookmarksMenu"
            }
            guard hasKnownRoot else {
                throw BookmarkParseError.unexpectedStructure("Safari bookmarks have neither BookmarksBar nor BookmarksMenu")
            }
            if let bar = rootChildren.first(where: { ($0["Title"] as? String) == "BookmarksBar" }),
               let children = bar["Children"] as? [[String: Any]] {
                for (i, child) in children.enumerated() {
                    if (child["Title"] as? String) == Self.deletedFolderTitle { continue }
                    result.append(contentsOf: parseNode(child, parentId: nil, prefix: BookmarkRoots.bar, index: i, seenKeys: &seenKeys))
                }
            }
            // "Other" is the Bookmarks menu followed by the folders and
            // bookmarks the user keeps directly at the top level, which Safari
            // shows next to Favorites.
            var otherIndex = 0
            let menuChildren = rootChildren.first(where: { ($0["Title"] as? String) == "BookmarksMenu" })?["Children"] as? [[String: Any]] ?? []
            for child in menuChildren + rootChildren.filter(Self.isUserRootEntry) {
                defer { otherIndex += 1 }
                if (child["Title"] as? String) == Self.deletedFolderTitle { continue }
                result.append(contentsOf: parseNode(child, parentId: nil, prefix: BookmarkRoots.other, index: otherIndex, seenKeys: &seenKeys))
            }
            if let mobile = rootChildren.first(where: Self.isMobileFolder),
               let children = mobile["Children"] as? [[String: Any]] {
                for (i, child) in children.enumerated() {
                    result.append(contentsOf: parseNode(child, parentId: nil, prefix: BookmarkRoots.mobile, index: i, seenKeys: &seenKeys))
                }
            }
        } else {
            guard let profileNode = rootChildren.first(where: { ($0["Title"] as? String) == profileName }) else {
                throw BookmarkParseError.unexpectedStructure("Safari profile folder \"\(profileName)\" not found")
            }
            if let children = profileNode["Children"] as? [[String: Any]] {
                for (i, child) in children.enumerated() {
                    if (child["Title"] as? String) == "Deleted by BookmarkSync" { continue }
                    result.append(contentsOf: parseNode(child, parentId: nil, prefix: "bookmark_bar", index: i, seenKeys: &seenKeys))
                }
            }
        }
        
        return result
    }
    
    private func parseNode(_ dict: [String: Any], parentId: String?, prefix: String, index: Int, seenKeys: inout [String: Int]) -> [ParsedBookmark] {
        var nodes: [ParsedBookmark] = []
        
        let type = dict["WebBookmarkType"] as? String
        let uriDict = dict["URIDictionary"] as? [String: Any]
        let title = dict["Title"] as? String ?? uriDict?["title"] as? String ?? "Unknown"
        
        if type == "WebBookmarkTypeList" {
            let normalized = title
            let baseId = parentId != nil ? "\(parentId!):\(normalized)" : "\(prefix):\(normalized)"
            let count = seenKeys[baseId, default: 0]
            seenKeys[baseId] = count + 1
            let uniqueId = count == 0 ? baseId : "\(baseId):dup\(count)"
            let node = ParsedBookmark(id: uniqueId, title: title, url: nil, type: .folder, parentId: parentId, mtime: Date(timeIntervalSince1970: 0), index: index)
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
            let node = ParsedBookmark(id: uniqueId, title: title, url: url, type: .leaf, parentId: parentId, mtime: Date(timeIntervalSince1970: 0), index: index)
            nodes.append(node)
        }
        
        return nodes
    }
    

}
