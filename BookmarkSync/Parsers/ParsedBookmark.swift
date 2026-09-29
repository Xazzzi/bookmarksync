import Foundation

/// A bookmark as read from a browser's own storage.
///
/// Parsers produce these rather than `BookmarkNode` so that reading — file I/O,
/// JSON decoding, plist parsing, copying and querying Firefox's SQLite database —
/// can run off the main actor. `BookmarkNode` is a SwiftData `@Model`, which is
/// bound to its context's actor and cannot safely cross threads.
struct ParsedBookmark: Sendable, Hashable {
    let id: String
    let title: String
    let url: String?
    let type: BookmarkType
    let parentId: String?
    let mtime: Date
    let index: Int

    init(
        id: String,
        title: String,
        url: String? = nil,
        type: BookmarkType,
        parentId: String? = nil,
        mtime: Date,
        index: Int = 0
    ) {
        self.id = id
        self.title = title
        self.url = url
        self.type = type
        self.parentId = parentId
        self.mtime = mtime
        self.index = index
    }
}
