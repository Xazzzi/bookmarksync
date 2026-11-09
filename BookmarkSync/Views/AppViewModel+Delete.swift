import Foundation
import SwiftData

extension AppViewModel {
    /// The hub nodes a bookmark-window row stands for, with everything inside
    /// them. A row id is a full node id in a profile-set view and a
    /// prefix-stripped id in the merged global view, where it covers that
    /// bookmark in every set.
    func hubNodesToDelete(forItemId itemId: String) -> [BookmarkNode] {
        guard let context = modelContext,
              let nodes = try? context.fetch(FetchDescriptor<BookmarkNode>()) else { return [] }

        let targets = nodes.filter { $0.id == itemId || stripProfileSetPrefix($0.id) == itemId }
        guard !targets.isEmpty else { return [] }

        // Children are found through parentId, not by id prefix: ids are title
        // paths, so "Folder:dup1:..." would wrongly match "Folder:".
        var childrenByParent: [String: [BookmarkNode]] = [:]
        for node in nodes {
            if let parentId = node.parentId {
                childrenByParent[parentId, default: []].append(node)
            }
        }

        var result: [BookmarkNode] = []
        var seen = Set<String>()
        var stack = targets
        while let node = stack.popLast() {
            guard seen.insert(node.id).inserted else { continue }
            result.append(node)
            stack.append(contentsOf: childrenByParent[node.id] ?? [])
        }
        return result
    }

    /// Deletes a bookmark or folder from the hub. The next sync removes it from
    /// every synced browser the usual way: each browser file is backed up before
    /// the write, and the removed items are kept in "Deleted by BookmarkSync".
    /// Browsers still have the bookmark and did not change it, so the import
    /// does not bring it back.
    @discardableResult
    func deleteBookmark(itemId: String) -> Int {
        guard let context = modelContext else { return 0 }
        let doomed = hubNodesToDelete(forItemId: itemId)
        guard !doomed.isEmpty else { return 0 }

        let titles = Set(doomed.map { $0.title })
        for node in doomed {
            context.delete(node)
        }
        try? context.save()
        cancelPendingDiffs(forTitles: titles)
        noteBookmarkDataChanged()
        SyncLog.event("[Hub] Deleted \(doomed.count) node(s) for \(itemId) from the bookmarks window")
        syncEngine?.triggerSync(changedPaths: [], forceImmediate: true)
        return doomed.count
    }
}
