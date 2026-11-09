import Foundation
import SwiftData

/// The URL part of a bookmark's identity.
///
/// Folds only what really is case- or form-insensitive: the scheme (http and
/// https count as the same page), the host's case, a leading `www.`, a default
/// port and a trailing slash. Paths, query strings and fragments are
/// case-sensitive on most servers, and a non-default port is a different
/// server, so both are kept: `localhost:3000` and `localhost:8080`, or
/// `/Docs/A` and `/docs/a`, are different bookmarks.
///
/// Changing this function changes every bookmark id. Stored ids must be
/// migrated with it; see `BookmarkIdMigration`.
func normalizeURL(_ urlString: String) -> String {
    let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)

    // Add dummy protocol if none exists, to allow correct URLComponents parsing
    let hasProtocol = trimmed.lowercased().hasPrefix("http://") || trimmed.lowercased().hasPrefix("https://")
    let urlToParse = hasProtocol ? trimmed : "https://" + trimmed

    guard let url = URL(string: urlToParse) ?? URL(string: urlToParse.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "") else {
        return trimmed
    }

    var host = url.host?.lowercased() ?? ""
    if host.hasPrefix("www.") {
        host = String(host.dropFirst(4))
    }
    if let port = url.port, port != 80, port != 443 {
        host += ":\(port)"
    }

    var path = url.path
    if path.hasSuffix("/") {
        path = String(path.dropLast())
    }

    var result = host + path
    if let query = url.query, !query.isEmpty {
        result += "?" + query
    }
    if let fragment = url.fragment, !fragment.isEmpty {
        result += "#" + fragment
    }

    return result.isEmpty ? trimmed : result
}

func stripProfileSetPrefix(_ id: String) -> String {
    let rootPrefixes = ["bookmark_bar", "other", "synced"]
    
    let parts = id.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
    
    // Case 1: Already stripped. e.g. "bookmark_bar:https://google.com" or "bookmark_bar:Folder:Name"
    if let first = parts.first, rootPrefixes.contains(String(first)) {
        return id
    }
    
    // Case 2: Prefixed with profileSetId. e.g. "UUID:bookmark_bar:Folder:Name"
    if parts.count >= 2 {
        let second = String(parts[1])
        if rootPrefixes.contains(second) {
            if let firstColon = id.firstIndex(of: ":") {
                let afterColon = id.index(after: firstColon)
                return String(id[afterColon...])
            }
        }
    }
    
    return id
}

enum BookmarkType: String, Codable, Sendable {
    case folder
    case leaf
}

struct BookmarkNodeRecord: Codable {
    var id: String
    var title: String
    var url: String?
    var type: BookmarkType
    var parentId: String?
    var index: Int?
}

@Model
final class BookmarkNode {
    @Attribute(.unique) var id: String // composite key: prefix + url or profileSetId + ":" + prefix + ":" + url
    var title: String
    var url: String?
    var type: BookmarkType
    var parentId: String?
    var mtime: Date
    var profileSetId: String?
    var index: Int = 0
    
    init(id: String, title: String, url: String? = nil, type: BookmarkType, parentId: String? = nil, mtime: Date, profileSetId: String? = nil, index: Int = 0) {
        self.id = id
        self.title = title
        self.url = url
        self.type = type
        self.parentId = parentId
        self.mtime = mtime
        self.profileSetId = profileSetId
        self.index = index
    }
}
