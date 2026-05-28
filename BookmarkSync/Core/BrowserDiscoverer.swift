import Foundation
import AppKit

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
            ("com.operasoftware.Opera", "Opera", "Opera Software/Opera Stable"),
            ("org.chromium.Chromium", "Chromium", "Chromium"),
            ("company.thebrowser.Browser", "Arc", "Arc/User Data")
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
                        profiles.append(DiscoveredProfile(
                            bundleId: bundleId,
                            browserName: name,
                            profileName: displayName,
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
            let profilesIniPath = supportPath.appendingPathComponent("profiles.ini").path
            
            if let content = try? String(contentsOfFile: profilesIniPath) {
                let lines = content.components(separatedBy: .newlines)
                var currentName = "Default"
                var currentPath = ""
                
                for line in lines {
                    if line.starts(with: "Name=") {
                        currentName = String(line.dropFirst(5))
                    } else if line.starts(with: "Path=") {
                        currentPath = String(line.dropFirst(5))
                        let bPath = supportPath.appendingPathComponent(currentPath).appendingPathComponent("places.sqlite").path
                        if FileManager.default.fileExists(atPath: bPath) {
                            profiles.append(DiscoveredProfile(
                                bundleId: "org.mozilla.firefox",
                                browserName: "Firefox",
                                profileName: currentName,
                                bookmarkFilePath: bPath,
                                appPath: appUrl.path
                            ))
                        }
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
