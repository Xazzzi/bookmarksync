import Foundation

/// Immutable, value-type projection of a `BookmarkNode` for display.
///
/// The tree UI never touches `@Model` instances directly: constructing a
/// `PersistentModel` is expensive and doing it per row per frame is what made
/// large collections (3k+ bookmarks) unusable.
struct BookmarkItem: Identifiable, Hashable {
    let id: String
    let title: String
    let url: String?
    let type: BookmarkType
    let mtime: Date
    let parentId: String?
    let index: Int
}

/// One rendered line of the expanded tree, pre-flattened so the list can be lazy.
struct BookmarkFlatRow: Identifiable, Hashable {
    let item: BookmarkItem
    let depth: Int
    let hasChildren: Bool

    var id: String { item.id }
}

private let deletedFolderTitle = "Deleted by BookmarkSync"

/// Pre-computed view of the bookmark store: built once per data change instead
/// of once per view-body evaluation.
struct BookmarkTreeSnapshot {
    private(set) var items: [BookmarkItem] = []
    private(set) var byId: [String: BookmarkItem] = [:]
    private(set) var childrenById: [String: [BookmarkItem]] = [:]
    private(set) var roots: [BookmarkItem] = []
    /// `items` in stable title order, used by the search list.
    private(set) var titleSorted: [BookmarkItem] = []

    static let empty = BookmarkTreeSnapshot()

    var isEmpty: Bool { items.isEmpty }

    init() {}

    /// - Parameters:
    ///   - nodes: live nodes from the store.
    ///   - profileSetFilter: a profile set id, or `nil` for the merged global view.
    init(nodes: [BookmarkNode], profileSetFilter: String?) {
        var collected: [BookmarkItem]

        if let setId = profileSetFilter {
            collected = nodes.compactMap { node in
                guard !node.isDeleted, node.profileSetId == setId else { return nil }
                return BookmarkItem(
                    id: node.id,
                    title: node.title,
                    url: node.url,
                    type: node.type,
                    mtime: node.mtime,
                    parentId: node.parentId,
                    index: node.index
                )
            }
        } else {
            // Global view: strip the profile-set prefix so the same logical
            // bookmark from several sets collapses into one row. Newest mtime wins.
            var merged = [String: BookmarkItem]()
            merged.reserveCapacity(nodes.count)
            for node in nodes where !node.isDeleted {
                let strippedId = stripProfileSetPrefix(node.id)
                if let existing = merged[strippedId], existing.mtime >= node.mtime {
                    continue
                }
                merged[strippedId] = BookmarkItem(
                    id: strippedId,
                    title: node.title,
                    url: node.url,
                    type: node.type,
                    mtime: node.mtime,
                    parentId: node.parentId.map { stripProfileSetPrefix($0) },
                    index: node.index
                )
            }
            collected = Array(merged.values)
        }

        items = collected

        byId = Dictionary(collected.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var children = [String: [BookmarkItem]]()
        var rootItems = [BookmarkItem]()
        for item in collected {
            if let pId = item.parentId, !pId.isEmpty, byId[pId] != nil {
                children[pId, default: []].append(item)
            } else {
                rootItems.append(item)
            }
        }

        for (key, value) in children {
            children[key] = value.sorted(by: Self.isOrderedBefore)
        }
        childrenById = children
        roots = rootItems.sorted(by: Self.isOrderedBefore)
        titleSorted = collected.sorted { $0.title.localizedCompare($1.title) == .orderedAscending }
    }

    /// Sibling ordering: the synthetic trash folder sinks to the bottom, then by
    /// explicit index, then folders before leaves, then title.
    static func isOrderedBefore(_ a: BookmarkItem, _ b: BookmarkItem) -> Bool {
        if a.title == deletedFolderTitle && b.title != deletedFolderTitle { return false }
        if b.title == deletedFolderTitle && a.title != deletedFolderTitle { return true }

        if a.index == b.index {
            if a.type != b.type {
                return a.type == .folder
            }
            return a.title.localizedCompare(b.title) == .orderedAscending
        }
        return a.index < b.index
    }

    func item(id: String?) -> BookmarkItem? {
        guard let id else { return nil }
        return byId[id]
    }

    func hasChildren(_ id: String) -> Bool {
        !(childrenById[id]?.isEmpty ?? true)
    }

    func children(of id: String) -> [BookmarkItem] {
        childrenById[id] ?? []
    }

    /// Walks up to the root. O(depth), no dictionary rebuild.
    func breadcrumbs(for id: String) -> [BookmarkItem] {
        var list = [BookmarkItem]()
        var currentParent = byId[id]?.parentId
        var guardCount = 0
        while let pId = currentParent, !pId.isEmpty, let parent = byId[pId], guardCount < 512 {
            list.insert(parent, at: 0)
            currentParent = parent.parentId
            guardCount += 1
        }
        return list
    }

    func breadcrumbPath(for id: String) -> String {
        let path = breadcrumbs(for: id).map { $0.title }
        return path.isEmpty ? "Root" : path.joined(separator: " > ")
    }

    var folderIds: [String] {
        items.compactMap { $0.type == .folder ? $0.id : nil }
    }

    /// Depth-first flattening of only the rows that are actually visible for the
    /// given expansion state. Drives a lazy list, so cost is proportional to the
    /// expanded tree rather than to every frame.
    func flattenVisible(expandedIds: Set<String>) -> [BookmarkFlatRow] {
        var result = [BookmarkFlatRow]()
        result.reserveCapacity(min(items.count, 512))

        func traverse(_ item: BookmarkItem, depth: Int) {
            let kids = childrenById[item.id] ?? []
            result.append(BookmarkFlatRow(item: item, depth: depth, hasChildren: !kids.isEmpty))
            guard item.type == .folder, expandedIds.contains(item.id) else { return }
            for child in kids {
                traverse(child, depth: depth + 1)
            }
        }

        for root in roots {
            traverse(root, depth: 0)
        }
        return result
    }

    func search(query rawQuery: String) -> [BookmarkItem] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if query.isEmpty { return titleSorted }
        return titleSorted.filter { item in
            item.title.lowercased().contains(query) || (item.url ?? "").lowercased().contains(query)
        }
    }
}
