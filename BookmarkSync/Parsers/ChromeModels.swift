import Foundation

struct ChromeBookmarks: Codable {
    let roots: ChromeRoots
}

struct ChromeRoots: Codable {
    let bookmark_bar: ChromeNode
    let other: ChromeNode
    let synced: ChromeNode
}

struct ChromeNode: Codable {
    let id: String
    let name: String
    let type: String // "folder" or "url"
    let url: String?
    let date_added: String
    let date_modified: String?
    let children: [ChromeNode]?
}
