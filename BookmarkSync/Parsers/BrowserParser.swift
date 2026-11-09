import Foundation

/// A bookmark file that was readable but not shaped the way the parser expects.
///
/// Parsers throw this instead of returning an empty list: an empty result is
/// indistinguishable from "the user deleted every bookmark", which the engine
/// would then propagate to every other browser and, through their cloud sync,
/// to every device.
enum BookmarkParseError: LocalizedError {
    case unexpectedStructure(String)

    var errorDescription: String? {
        switch self {
        case .unexpectedStructure(let detail):
            return "Unexpected bookmark file structure: \(detail)"
        }
    }
}

/// Reads and writes one browser profile's bookmark storage.
///
/// Conformers must be safe to use off the main actor: `read` and `write` do file
/// I/O and are deliberately kept free of SwiftData `@Model` types so the sync
/// engine can run them on a background executor.
protocol BrowserParser: Sendable {
    var filePath: URL { get }
    func read() throws -> [ParsedBookmark]
    func write(nodes: [ParsedBookmark]) throws
}

/// The parser for one profile's bookmark file (or a backup of it).
func makeBookmarkParser(bundleId: String, profileName: String, fileURL: URL) -> BrowserParser {
    switch bundleId {
    case "com.apple.Safari":
        return SafariParser(filePath: fileURL, profileName: profileName)
    case "org.mozilla.firefox":
        return FirefoxParser(filePath: fileURL)
    default:
        return ChromeParser(filePath: fileURL)
    }
}

extension BrowserParser {
    /// Snapshots the current file before it is overwritten. See `BackupStore`
    /// for naming and retention.
    func performBackup() throws {
        try BackupStore.createBackup(of: filePath)
    }
}

/// Sibling index for writing out a bookmark tree.
///
/// Every writer needs "the children of parent P, in order", recursively. Doing
/// that with `nodes.filter { $0.id.starts(with: prefix) && $0.parentId == p }`
/// rescans the whole array — and runs a string prefix comparison — once per
/// folder visited, which is O(N^2) and the dominant cost of a large write
/// (~9M `starts(with:)` calls at 3k bookmarks).
///
/// This groups the nodes once up front so each lookup is a dictionary hit.
struct BookmarkChildIndex {
    /// Children of a given parent id, pre-sorted by `index`.
    private var byParent: [String: [ParsedBookmark]] = [:]
    /// Root-level children (no parent), bucketed by root prefix and pre-sorted.
    private var rootsByPrefix: [String: [ParsedBookmark]] = [:]

    /// - Parameter nodes: nodes with profile-set prefixes already stripped, so
    ///   ids read as `<rootPrefix>:<path>`.
    init(strippedNodes nodes: [ParsedBookmark]) {
        for node in nodes {
            if let parentId = node.parentId, !parentId.isEmpty {
                byParent[parentId, default: []].append(node)
            } else if let prefix = node.id.split(separator: ":").first.map(String.init) {
                rootsByPrefix[prefix, default: []].append(node)
            }
        }

        for key in byParent.keys {
            byParent[key]?.sort { $0.index < $1.index }
        }
        for key in rootsByPrefix.keys {
            rootsByPrefix[key]?.sort { $0.index < $1.index }
        }
    }

    /// Ordered children to write under `parentId`, or the roots of `prefix`
    /// when `parentId` is nil.
    ///
    /// Mirrors the original predicate: a node is only considered under `prefix`
    /// if its id carries that root prefix.
    func children(prefix: String, parentId: String?) -> [ParsedBookmark] {
        guard let parentId, !parentId.isEmpty else {
            return rootsByPrefix[prefix] ?? []
        }
        guard let candidates = byParent[parentId] else { return [] }
        let idPrefix = prefix + ":"
        return candidates.filter { $0.id.hasPrefix(idPrefix) }
    }
}
