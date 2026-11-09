import Foundation

/// Empty folders are real user state and are kept in the hub.
///
/// Earlier versions dropped every folder without a bookmark beneath it from the
/// hub, so the export then deleted those folders from every browser -- including
/// the one where the user had just created them. Hubs written by those versions
/// are missing each profile's existing empty folders; `emptyFolders(in:)` finds
/// them so the engine can add them back once per profile.
enum EmptyFolderMigration {
    static let defaultsKey = "emptyFolderMigratedConfigIds"

    /// Folders with no bookmark anywhere beneath them (nested empty folders included).
    static func emptyFolders(in nodes: [ParsedBookmark]) -> [ParsedBookmark] {
        var childrenByParent: [String: [ParsedBookmark]] = [:]
        for node in nodes {
            if let parent = node.parentId {
                childrenByParent[parent, default: []].append(node)
            }
        }

        var memo: [String: Bool] = [:]
        func hasLeaf(_ folderId: String, visiting: inout Set<String>) -> Bool {
            if let known = memo[folderId] { return known }
            guard visiting.insert(folderId).inserted else { return false }
            let result = (childrenByParent[folderId] ?? []).contains { child in
                child.type == .leaf || hasLeaf(child.id, visiting: &visiting)
            }
            memo[folderId] = result
            return result
        }

        return nodes.filter { node in
            guard node.type == .folder else { return false }
            var visiting = Set<String>()
            return !hasLeaf(node.id, visiting: &visiting)
        }
    }
}
