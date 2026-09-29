import Foundation

extension AppViewModel {
    /// Hard cap on retained activity rows, as a memory backstop only.
    ///
    /// Every change gets its own row — the feed is meant to be read item by item —
    /// so this is set well above a full large import rather than at a size that
    /// would summarise one away. The list rendering it is lazy, so row count
    /// costs memory, not frame time.
    static let diffHistoryLimit = 5000

    /// Records one activity row per changed bookmark, in a single published
    /// mutation.
    ///
    /// Rows are deduplicated against what is already pending for the same target,
    /// so a repeated sync of unchanged state does not grow the feed.
    func addDiffs(
        titles: [String],
        targetBundleId: String,
        targetProfileName: String,
        profileSetId: String
    ) {
        guard !titles.isEmpty else { return }

        func makeRecord(_ title: String) -> DiffRecord {
            DiffRecord(
                bookmarkTitle: title,
                sourceBundleIds: ["System"],
                targetBundleIds: [targetBundleId],
                sourceProfileNames: ["System"],
                targetProfileNames: [targetProfileName],
                isWaiting: true,
                profileSetId: profileSetId
            )
        }

        // A pending Reorder is subsumed by any concrete change to the same target.
        dropPendingReorder(for: targetBundleId)

        var additions: [DiffRecord] = []
        var seen = Set(
            diffHistory.lazy
                .filter { $0.targetBundleIds == [targetBundleId] }
                .map { $0.bookmarkTitle }
        )

        for title in titles where !seen.contains(title) {
            seen.insert(title)
            additions.append(makeRecord(title))
        }

        guard !additions.isEmpty else { return }

        // One mutation of the @Published array, so SwiftUI performs a single
        // invalidation pass rather than one per bookmark. Inserted in order so
        // the batch reads top-to-bottom with its summary row trailing the
        // sampled titles it stands in for.
        var updated = diffHistory
        updated.insert(contentsOf: additions, at: 0)
        if updated.count > Self.diffHistoryLimit {
            updated.removeLast(updated.count - Self.diffHistoryLimit)
        }
        diffHistory = updated
    }

    /// Removes a waiting Reorder row's claim on `bundleId`, dropping the row
    /// entirely once no targets remain.
    private func dropPendingReorder(for bundleId: String) {
        guard let idx = diffHistory.firstIndex(where: { $0.bookmarkTitle == "Reorder" && $0.isWaiting }),
              let tIdx = diffHistory[idx].targetBundleIds.firstIndex(of: bundleId) else { return }

        diffHistory[idx].targetBundleIds.remove(at: tIdx)
        if tIdx < diffHistory[idx].targetProfileNames.count {
            diffHistory[idx].targetProfileNames.remove(at: tIdx)
        }
        if diffHistory[idx].targetBundleIds.isEmpty {
            diffHistory.remove(at: idx)
        }
    }

    /// Cancels pending diffs for many bookmark titles in one pass.
    ///
    /// The per-title variant rescans the entire history and re-derives each row's
    /// clean title, so calling it once per changed node was quadratic.
    func cancelPendingDiffs(forTitles titles: Set<String>) {
        guard !titles.isEmpty else { return }
        let cleanTargets = Set(titles.map { Self.cleanDiffTitle($0) })
        diffHistory.removeAll { diff in
            diff.isWaiting && cleanTargets.contains(Self.cleanDiffTitle(diff.bookmarkTitle))
        }
    }

    static func cleanDiffTitle(_ title: String) -> String {
        for prefix in ["Add: ", "Update: ", "Delete: "] where title.hasPrefix(prefix) {
            return String(title.dropFirst(prefix.count))
        }
        return title
    }

    func addDiff(_ diff: DiffRecord) {
        if diff.bookmarkTitle.starts(with: "System:") { return }
        
        if diff.bookmarkTitle != "Reorder" {
            for target in diff.targetBundleIds {
                if let idx = diffHistory.firstIndex(where: { $0.bookmarkTitle == "Reorder" && $0.isWaiting }) {
                    if let tIdx = diffHistory[idx].targetBundleIds.firstIndex(of: target) {
                        diffHistory[idx].targetBundleIds.remove(at: tIdx)
                        if tIdx < diffHistory[idx].targetProfileNames.count {
                            diffHistory[idx].targetProfileNames.remove(at: tIdx)
                        }
                    }
                    if diffHistory[idx].targetBundleIds.isEmpty {
                        diffHistory.remove(at: idx)
                    }
                }
            }
        } else {
            if let idx = diffHistory.firstIndex(where: { $0.bookmarkTitle == "Reorder" && $0.isWaiting }) {
                for (i, target) in diff.targetBundleIds.enumerated() {
                    if !diffHistory[idx].targetBundleIds.contains(target) {
                        diffHistory[idx].targetBundleIds.append(target)
                        diffHistory[idx].targetProfileNames.append(diff.targetProfileNames[i])
                    }
                }
                return
            }
        }

        if diffHistory.contains(where: {
            $0.bookmarkTitle == diff.bookmarkTitle &&
            Set($0.sourceBundleIds) == Set(diff.sourceBundleIds) &&
            Set($0.targetBundleIds) == Set(diff.targetBundleIds)
        }) {
            return
        }
        diffHistory.insert(diff, at: 0)
        if diffHistory.count > Self.diffHistoryLimit {
            diffHistory.removeLast(diffHistory.count - Self.diffHistoryLimit)
        }
    }

    func markSynced(diffId: UUID) {
        if let idx = diffHistory.firstIndex(where: { $0.id == diffId }) {
            diffHistory[idx].isWaiting = false
        }
    }

    func markBrowserSynced(bundleId: String) {
        for idx in diffHistory.indices {
            if diffHistory[idx].targetBundleIds.contains(bundleId) {
                diffHistory[idx].isWaiting = false
            }
        }
    }

    func clearHistory() {
        diffHistory = []
    }

    func removeDiffs(for bundleId: String, profileName: String) {
        for idx in diffHistory.indices.reversed() {
            var diff = diffHistory[idx]

            var keepTargets = [String]()
            var keepProfiles = [String]()
            for i in 0..<diff.targetBundleIds.count {
                if diff.targetBundleIds[i] == bundleId && diff.targetProfileNames[i] == profileName {
                    continue
                }
                keepTargets.append(diff.targetBundleIds[i])
                keepProfiles.append(diff.targetProfileNames[i])
            }

            diff.targetBundleIds = keepTargets
            diff.targetProfileNames = keepProfiles
            diffHistory[idx] = diff

            if diffHistory[idx].targetBundleIds.isEmpty {
                diffHistory.remove(at: idx)
            }
        }
    }

    func cancelPendingDiffs(for bookmarkTitle: String, bundleId: String? = nil) {
        let cleanTitle = Self.cleanDiffTitle(bookmarkTitle)

        diffHistory.removeAll { diff in
            let matchesBundle = bundleId == nil ? true : diff.targetBundleIds.contains(bundleId!)
            return diff.isWaiting &&
                   matchesBundle &&
                   Self.cleanDiffTitle(diff.bookmarkTitle) == cleanTitle
        }
    }
}
