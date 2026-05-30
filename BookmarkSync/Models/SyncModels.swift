import Foundation

struct DiffRecord: Identifiable {
    let id = UUID()
    let bookmarkTitle: String
    let sourceBundleIds: [String]
    var targetBundleIds: [String]
    let sourceProfileNames: [String]
    var targetProfileNames: [String]
    var isWaiting: Bool
    let profileSetId: String?
}

enum SyncState: Int, Codable {
    case stopped = 0
    case readOnly = 1
    case active = 2
}
