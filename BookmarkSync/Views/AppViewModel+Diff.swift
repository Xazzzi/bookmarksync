import Foundation

extension AppViewModel {
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
        let cleanTitle = bookmarkTitle
            .replacingOccurrences(of: "Add: ", with: "")
            .replacingOccurrences(of: "Update: ", with: "")
            .replacingOccurrences(of: "Delete: ", with: "")

        diffHistory.removeAll { diff in
            let diffCleanTitle = diff.bookmarkTitle
                .replacingOccurrences(of: "Add: ", with: "")
                .replacingOccurrences(of: "Update: ", with: "")
                .replacingOccurrences(of: "Delete: ", with: "")

            let matchesBundle = bundleId == nil ? true : diff.targetBundleIds.contains(bundleId!)
            return diff.isWaiting &&
                   matchesBundle &&
                   diffCleanTitle == cleanTitle
        }
    }
}
