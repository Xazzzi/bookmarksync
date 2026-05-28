import Foundation
import SwiftData

@Model
final class BrowserConfig {
    @Attribute(.unique) var id: String // e.g. "com.apple.Safari:Default"
    var bundleId: String
    var browserName: String
    var profileName: String
    var bookmarkFilePath: String
    var isEnabled: Bool
    var profileSetId: String?
    var lastSyncTime: Date?
    @Attribute(.externalStorage) var observedStateData: Data?
    
    init(id: String, bundleId: String, browserName: String, profileName: String, bookmarkFilePath: String, isEnabled: Bool = true, profileSetId: String? = nil, lastSyncTime: Date? = nil, observedStateData: Data? = nil) {
        self.id = id
        self.bundleId = bundleId
        self.browserName = browserName
        self.profileName = profileName
        self.bookmarkFilePath = bookmarkFilePath
        self.isEnabled = isEnabled
        self.profileSetId = profileSetId
        self.lastSyncTime = lastSyncTime
        self.observedStateData = observedStateData
    }
}
