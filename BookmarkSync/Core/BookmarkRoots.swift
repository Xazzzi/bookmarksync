import Foundation

/// The top-level folders bookmarks live under, and which of them each browser
/// profile can hold.
///
/// Every id starts (after the profile-set prefix) with one of these root keys.
/// Chromium has all three. Safari's default profile maps Favorites to the bar,
/// the Bookmarks menu plus the user's top-level folders to "other", and keeps
/// mobile bookmarks in a top-level "Mobile Bookmarks" folder it creates when
/// needed; a named Safari profile (older configs only) is one folder, read as
/// the bar. Firefox's toolbar and "Other Bookmarks" are mapped (its
/// menu is read as `other`; its mobile root is not read).
///
/// A bookmark under a root the target lacks cannot be written there: the
/// writers simply have nowhere to put it. Counting it as missing made the
/// export rewrite that browser on every pass without ever converging, so such
/// bookmarks are left out of the comparison instead (plan item M2).
enum BookmarkRoots {
    static let bar = "bookmark_bar"
    static let other = "other"
    static let mobile = "synced"

    static func supported(bundleId: String, profileName: String) -> Set<String> {
        switch bundleId {
        case "com.apple.Safari":
            return profileName == "Default" ? [bar, other, mobile] : [bar]
        case "org.mozilla.firefox":
            return [bar, other]
        default:
            return [bar, other, mobile]
        }
    }

    /// The root key of a (possibly profile-set prefixed) node id.
    static func root(of id: String) -> String {
        stripProfileSetPrefix(id).split(separator: ":", maxSplits: 1).first.map(String.init) ?? ""
    }
}
