import CryptoKit
import Foundation

/// Deterministic hash of a bookmark tree's content: ids, titles, URLs, types,
/// parents and order. Ignores `mtime` and anything storage-specific, so a file
/// rewritten with the same bookmarks (e.g. Safari's sync agent) hashes the same.
enum BookmarkSnapshotFingerprint {
    static func compute(_ nodes: [ParsedBookmark]) -> String {
        let sorted = nodes.sorted {
            let lhsParent = $0.parentId ?? ""
            let rhsParent = $1.parentId ?? ""
            if lhsParent != rhsParent { return lhsParent < rhsParent }
            if $0.index != $1.index { return $0.index < $1.index }
            if $0.id != $1.id { return $0.id < $1.id }
            if $0.title != $1.title { return $0.title < $1.title }
            return ($0.url ?? "") < ($1.url ?? "")
        }

        var hasher = SHA256()
        hashCount(sorted.count, into: &hasher)
        for node in sorted {
            hashString(node.id, into: &hasher)
            hashString(node.title, into: &hasher)
            hashString(node.url ?? "", into: &hasher)
            hashString(node.type == .folder ? "F" : "L", into: &hasher)
            hashString(node.parentId ?? "", into: &hasher)
            hashCount(node.index, into: &hasher)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func hashCount(_ value: Int, into hasher: inout SHA256) {
        var encoded = Int64(value).bigEndian
        withUnsafeBytes(of: &encoded) { hasher.update(bufferPointer: $0) }
    }

    // Length-prefixed so adjacent fields cannot run into each other.
    private static func hashString(_ value: String, into hasher: inout SHA256) {
        let utf8 = Data(value.utf8)
        hashCount(utf8.count, into: &hasher)
        hasher.update(data: utf8)
    }
}
