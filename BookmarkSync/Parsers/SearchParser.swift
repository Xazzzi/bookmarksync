import Foundation

/// Reads and writes Search's `bookmarks.json` (Personal profile).
///
/// Search keeps one JSON array. Each entry is `{id, title, url?, children?}`:
/// a folder has `children` and no `url`. There are no fixed root folders;
/// whatever sits at the top level is what Search's bookmarks bar shows, so the
/// whole array is read as the `bookmark_bar` root and Search holds nothing
/// under `other` or `synced` (see `BookmarkRoots.supported`).
///
/// Search has no modification times, so every node reads as the epoch, as
/// Safari's do: another browser's real edit always wins a conflict.
///
/// Search holds its bookmarks in memory and rewrites this file on every
/// change, so the write queue only lets this parser write while Search is not
/// running (it waits for the app to quit, like every other browser).
final class SearchParser: BrowserParser {
    let filePath: URL

    static let deletedFolderTitle = "Deleted by BookmarkSync"

    init(filePath: URL) {
        self.filePath = filePath
    }

    func read() throws -> [ParsedBookmark] {
        let data = try Data(contentsOf: filePath)
        guard let list = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw BookmarkParseError.unexpectedStructure("Search bookmarks are not a list")
        }

        var result: [ParsedBookmark] = []
        var seenKeys: [String: Int] = [:]

        func traverse(_ node: [String: Any], parentId: String?, index: Int) {
            let title = node["title"] as? String ?? ""
            let url = node["url"] as? String
            let uniqueId = Self.uniqueId(title: title, url: url, parentId: parentId, seenKeys: &seenKeys)
            result.append(ParsedBookmark(
                id: uniqueId,
                title: title,
                url: url,
                type: url == nil ? .folder : .leaf,
                parentId: parentId,
                mtime: Date(timeIntervalSince1970: 0),
                index: index
            ))
            if url == nil, let children = node["children"] as? [[String: Any]] {
                for (i, child) in children.enumerated() {
                    traverse(child, parentId: uniqueId, index: i)
                }
            }
        }

        var index = 0
        for node in list {
            if node["url"] == nil, (node["title"] as? String) == Self.deletedFolderTitle { continue }
            traverse(node, parentId: nil, index: index)
            index += 1
        }
        return result
    }

    /// The engine's id for a node: `<parent id>:<normalized url or title>`,
    /// with `:dupN` for same-named siblings. Must match what `read` produces,
    /// so `write` can find the node a bookmark came from.
    private static func uniqueId(title: String, url: String?, parentId: String?, seenKeys: inout [String: Int]) -> String {
        let normalized = url.map(normalizeURL) ?? title
        let baseId = "\(parentId ?? BookmarkRoots.bar):\(normalized)"
        let count = seenKeys[baseId, default: 0]
        seenKeys[baseId] = count + 1
        return count == 0 ? baseId : "\(baseId):dup\(count)"
    }

    func write(nodes: [ParsedBookmark]) throws {
        // Refuse to write over a file that isn't Search's: read first, so a
        // bad file throws before anything is touched or backed up.
        let data = try Data(contentsOf: filePath)
        guard let original = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw BookmarkParseError.unexpectedStructure("Search bookmarks are not a list")
        }
        try performBackup()

        let stripped = nodes.map { node in
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
        let childIndex = BookmarkChildIndex(strippedNodes: stripped)

        // Existing entries by engine id, so a bookmark that is still there
        // keeps the id Search gave it (Search's own state refers to them).
        var originalsById: [String: [String: Any]] = [:]
        var seenKeys: [String: Int] = [:]
        func indexOriginal(_ node: [String: Any], parentId: String?) {
            let title = node["title"] as? String ?? ""
            let url = node["url"] as? String
            let uniqueId = Self.uniqueId(title: title, url: url, parentId: parentId, seenKeys: &seenKeys)
            originalsById[uniqueId] = node
            if url == nil, let children = node["children"] as? [[String: Any]] {
                for child in children { indexOriginal(child, parentId: uniqueId) }
            }
        }
        for node in original {
            if node["url"] == nil, (node["title"] as? String) == Self.deletedFolderTitle { continue }
            indexOriginal(node, parentId: nil)
        }

        func build(parentId: String?) -> [[String: Any]] {
            childIndex.children(prefix: BookmarkRoots.bar, parentId: parentId).map { node in
                var dict = originalsById[node.id] ?? [:]
                if dict["id"] == nil { dict["id"] = UUID().uuidString }
                dict["title"] = node.title
                if node.type == .folder {
                    dict.removeValue(forKey: "url")
                    dict["children"] = build(parentId: node.id)
                } else {
                    dict["url"] = node.url
                    dict.removeValue(forKey: "children")
                }
                return dict
            }
        }

        let out = try JSONSerialization.data(withJSONObject: build(parentId: nil))
        try out.write(to: filePath, options: .atomic)
    }
}
