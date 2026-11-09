import Foundation

/// Item-by-item difference between two bookmark trees, for showing the user
/// exactly what a held deletion or a backup restore would change.
struct BookmarkDiff: Equatable, Sendable {
    enum Change: Equatable, Sendable {
        case added
        case removed
        /// Same identity, different title or URL.
        case changed(oldTitle: String, oldURL: String?)
    }

    struct Entry: Identifiable, Equatable, Sendable {
        let id: String
        let change: Change
        let type: BookmarkType
        let title: String
        let url: String?
        /// Readable location, e.g. ["bookmark_bar", "Work", "Docs"]. The first
        /// element is the root key; views translate it for display.
        let path: [String]
    }

    let entries: [Entry]

    var added: [Entry] { entries.filter { $0.change == .added } }
    var removed: [Entry] { entries.filter { $0.change == .removed } }
    var changed: [Entry] {
        entries.filter { if case .changed = $0.change { return true } else { return false } }
    }
    var isEmpty: Bool { entries.isEmpty }

    /// Compares `old` with `new` by node id. Moves appear as a removal plus an
    /// addition because a node's id encodes its folder.
    init(old: [ParsedBookmark], new: [ParsedBookmark]) {
        let oldById = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let newById = Dictionary(new.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var entries: [Entry] = []
        for (id, node) in oldById where newById[id] == nil {
            entries.append(Self.entry(node, .removed, in: oldById))
        }
        for (id, node) in newById {
            if let before = oldById[id] {
                if before.title != node.title || before.url != node.url {
                    entries.append(Self.entry(node, .changed(oldTitle: before.title, oldURL: before.url), in: newById))
                }
            } else {
                entries.append(Self.entry(node, .added, in: newById))
            }
        }

        self.entries = entries.sorted {
            if $0.path != $1.path { return $0.path.lexicographicallyPrecedes($1.path) }
            if $0.title != $1.title { return $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            return $0.id < $1.id
        }
    }

    private static func entry(_ node: ParsedBookmark, _ change: Change, in tree: [String: ParsedBookmark]) -> Entry {
        Entry(id: node.id, change: change, type: node.type, title: node.title, url: node.url,
              path: folderPath(of: node, in: tree))
    }

    /// Root key followed by the titles of the folders containing `node`.
    static func folderPath(of node: ParsedBookmark, in tree: [String: ParsedBookmark]) -> [String] {
        var titles: [String] = []
        var visited = Set<String>()
        var parentId = node.parentId
        while let pid = parentId, !pid.isEmpty, visited.insert(pid).inserted, let parent = tree[pid] {
            titles.insert(parent.title, at: 0)
            parentId = parent.parentId
        }
        let root = stripProfileSetPrefix(node.id).split(separator: ":").first.map(String.init) ?? ""
        return [root] + titles
    }
}
