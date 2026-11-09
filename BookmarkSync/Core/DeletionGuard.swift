import Foundation

/// Decides whether the deletions read from one profile are safe to propagate.
///
/// A deletion in one browser is copied to every other browser and from there to
/// every device through the browsers' own cloud sync, so a misread file must
/// never look like "the user deleted everything". Anything that looks like a
/// read failure or an unusually large deletion is held for the user to confirm.
enum DeletionGuard {
    /// A deletion is held when it removes at least this many nodes...
    static let massCount = 10
    /// ...and at least this share of what the profile had last time,
    static let massFraction = 0.2
    /// or when it removes at least `majorityCount` nodes and this share.
    static let majorityFraction = 0.5
    static let majorityCount = 3

    enum Reason: Equatable, Sendable {
        /// The profile read back empty although it was not empty last time.
        case emptyRead
        /// The profile lost an unusually large number of bookmarks at once.
        case massDeletion
    }

    enum Verdict: Equatable, Sendable {
        case allow
        case hold(Reason)
    }

    /// - Parameters:
    ///   - previousCount: nodes observed in this profile on the previous pass.
    ///   - currentCount: nodes read from this profile now.
    ///   - deletedIds: ids observed last time and missing now.
    ///   - approvedIds: deletions the user already confirmed for this profile.
    static func evaluate(
        previousCount: Int,
        currentCount: Int,
        deletedIds: Set<String>,
        approvedIds: Set<String> = []
    ) -> Verdict {
        let unapproved = deletedIds.subtracting(approvedIds)
        guard !unapproved.isEmpty else { return .allow }

        if previousCount > 0 && currentCount == 0 {
            return .hold(.emptyRead)
        }

        let fraction = Double(unapproved.count) / Double(max(previousCount, 1))
        if unapproved.count >= massCount && fraction >= massFraction {
            return .hold(.massDeletion)
        }
        if unapproved.count >= majorityCount && fraction >= majorityFraction {
            return .hold(.massDeletion)
        }
        return .allow
    }
}

/// A profile whose deletions are waiting for the user to confirm or reject.
struct PendingDeletionHold: Identifiable, Equatable {
    let configId: String
    let browserName: String
    let profileName: String
    let reason: DeletionGuard.Reason
    let deletedIds: Set<String>
    let previousCount: Int
    /// What the profile's file looks like now compared with last time, so the
    /// user can see which bookmarks would be deleted before deciding.
    let diff: BookmarkDiff

    var id: String { configId }
}
