import Foundation
import AppKit
import SQLite

struct DiscoveredProfile {
    let bundleId: String
    let browserName: String
    let profileName: String
    let bookmarkFilePath: String
    let appPath: String
}

class BrowserDiscoverer {
    static var isSafariAccessGranted: Bool = true

    static func discover() -> [DiscoveredProfile] {
        isSafariAccessGranted = false
        var profiles: [DiscoveredProfile] = []

        // 1. Safari
        let safariPath = "/Applications/Safari.app"
        if FileManager.default.fileExists(atPath: safariPath) {
            let bookmarksPath = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Safari/Bookmarks.plist").path
            if FileManager.default.fileExists(atPath: bookmarksPath) {
                do {
                    let data = try Data(contentsOf: URL(fileURLWithPath: bookmarksPath))
                    isSafariAccessGranted = true

                    profiles.append(DiscoveredProfile(
                        bundleId: "com.apple.Safari",
                        browserName: "Safari",
                        profileName: "Default",
                        bookmarkFilePath: bookmarksPath,
                        appPath: safariPath
                    ))

                    if let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
                       let children = plist["Children"] as? [[String: Any]] {

                        let systemTitles = ["History", "BookmarksBar", "BookmarksMenu", "com.apple.ReadingList"]

                        for child in children {
                            if child["WebBookmarkType"] as? String == "WebBookmarkTypeList",
                               let title = child["Title"] as? String,
                               !systemTitles.contains(title),
                               !title.isEmpty {
                                profiles.append(DiscoveredProfile(
                                    bundleId: "com.apple.Safari",
                                    browserName: "Safari",
                                    profileName: title,
                                    bookmarkFilePath: bookmarksPath,
                                    appPath: safariPath
                                ))
                            }
                        }
                    }
                } catch {
                    isSafariAccessGranted = false
                    print("Failed to read Safari Bookmarks.plist: \(error)")
                }
            }
        }

        // 2. Chromium-based browsers
        let chromiumBrowsers = [
            ("com.google.Chrome", "Google Chrome", "Google/Chrome"),
            ("com.brave.Browser", "Brave", "BraveSoftware/Brave-Browser"),
            ("com.microsoft.edgemac", "Microsoft Edge", "Microsoft Edge"),
            ("com.vivaldi.Vivaldi", "Vivaldi", "Vivaldi"),
            ("com.operasoftware.Opera", "Opera", "com.operasoftware.Opera"),
            ("org.chromium.Chromium", "Chromium", "Chromium")
        ]

        for (bundleId, name, appSupportDir) in chromiumBrowsers {
            if let appUrl = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
                let supportPath = URL(fileURLWithPath: NSHomeDirectory())
                    .appendingPathComponent("Library/Application Support/\(appSupportDir)")

                let localStatePath = supportPath.appendingPathComponent("Local State").path
                var profileMap: [String: String] = [:]

                if let data = try? Data(contentsOf: URL(fileURLWithPath: localStatePath)),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let profile = json["profile"] as? [String: Any],
                   let infoCache = profile["info_cache"] as? [String: [String: Any]] {
                    for (dirName, info) in infoCache {
                        if let displayName = info["name"] as? String {
                            profileMap[dirName] = displayName
                        }
                    }
                }

                if profileMap.isEmpty {
                    profileMap["Default"] = "Default"
                }

                for (dirName, displayName) in profileMap {
                    let bPath = supportPath.appendingPathComponent(dirName).appendingPathComponent("Bookmarks").path
                    if FileManager.default.fileExists(atPath: bPath) {
                        var finalDisplayName = displayName
                        if finalDisplayName == "Default" || finalDisplayName.trimmingCharacters(in: .whitespaces).isEmpty {
                            let authPath = supportPath.appendingPathComponent(dirName).appendingPathComponent("auth_account").path
                            if let authData = try? Data(contentsOf: URL(fileURLWithPath: authPath)) {
                                if let braceIndex = authData.firstIndex(of: 0x7B),
                                   let lastBraceIndex = authData.lastIndex(of: 0x7D),
                                   lastBraceIndex > braceIndex {
                                    let jsonData = authData.subdata(in: braceIndex..<(lastBraceIndex + 1))
                                    if let authJson = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                                       let fullName = authJson["full_name"] as? String, !fullName.isEmpty {
                                        finalDisplayName = fullName
                                    }
                                }
                            }
                        }
                        
                        if finalDisplayName.trimmingCharacters(in: .whitespaces).isEmpty {
                            finalDisplayName = "Default"
                        }
                        
                        profiles.append(DiscoveredProfile(
                            bundleId: bundleId,
                            browserName: name,
                            profileName: finalDisplayName,
                            bookmarkFilePath: bPath,
                            appPath: appUrl.path
                        ))
                    }
                }
            }
        }

        // 3. Firefox
        if let appUrl = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "org.mozilla.firefox") {
            let supportPath = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/Firefox")

            var pathToName: [String: String] = [:]

            // Try to parse from Profile Groups SQLite databases (newer Firefox versions)
            let pgDirPath = supportPath.appendingPathComponent("Profile Groups").path
            if let enumerator = FileManager.default.enumerator(atPath: pgDirPath) {
                while let dbName = enumerator.nextObject() as? String {
                    if dbName.hasSuffix(".sqlite") && !dbName.contains("/") {
                        let dbPath = supportPath.appendingPathComponent("Profile Groups").appendingPathComponent(dbName).path
                        if let db = try? Connection(dbPath, readonly: true) {
                            let profilesTable = Table("Profiles")
                            let pathCol = Expression<String>("path")
                            let nameCol = Expression<String>("name")

                            if let rows = try? db.prepare(profilesTable.select(pathCol, nameCol)) {
                                for row in rows {
                                    pathToName[row[pathCol]] = row[nameCol]
                                }
                            }
                        }
                    }
                }
            }

            // Scan the Profiles directory directly
            let profilesDirPath = supportPath.appendingPathComponent("Profiles").path
            if let enumerator = FileManager.default.enumerator(atPath: profilesDirPath) {
                while let dirName = enumerator.nextObject() as? String {
                    // Only process top-level directories
                    if dirName.contains("/") { continue }

                    let bPath = supportPath.appendingPathComponent("Profiles").appendingPathComponent(dirName).appendingPathComponent("places.sqlite").path
                    if FileManager.default.fileExists(atPath: bPath) {
                        let relativePath = "Profiles/\(dirName)"
                        var profileName = pathToName[relativePath]

                        if profileName == nil {
                            profileName = dirName
                            if let dotIndex = dirName.firstIndex(of: ".") {
                                profileName = String(dirName[dirName.index(after: dotIndex)...])
                            }
                        }

                        profiles.append(DiscoveredProfile(
                            bundleId: "org.mozilla.firefox",
                            browserName: "Firefox",
                            profileName: profileName!,
                            bookmarkFilePath: bPath,
                            appPath: appUrl.path
                        ))
                    }
                }
            }
        }

        return profiles
    }

    static func getIcon(for bundleId: String) -> NSImage? {
        if let appUrl = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            return NSWorkspace.shared.icon(forFile: appUrl.path)
        }
        return nil
    }
}
