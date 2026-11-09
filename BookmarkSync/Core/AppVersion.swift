import Foundation

/// The version shown in the menu bar and the help window.
///
/// CI stamps the build number (the workflow run number) and the commit into
/// the app's Info.plist before signing, so every installed build can be told
/// apart; a local Xcode build shows the values from `project.yml`.
enum AppVersion {
    static var display: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        if let commit = info["BookmarkSyncCommit"] as? String, !commit.isEmpty {
            return "\(version) (\(build), \(commit))"
        }
        return "\(version) (\(build))"
    }
}
