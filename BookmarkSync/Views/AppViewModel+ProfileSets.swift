import SwiftUI
import SwiftData

extension AppViewModel {
    func loadProfileSets() {
        guard let context = modelContext else { return }
        let sets = (try? context.fetch(FetchDescriptor<ProfileSet>())) ?? []
        if sets.isEmpty {
            let defaultSet = ProfileSet(name: "Set 1")
            context.insert(defaultSet)
            try? context.save()
            self.profileSets = [defaultSet]
            self.selectedProfileSetId = defaultSet.id
            UserDefaults.standard.set(defaultSet.id, forKey: "selectedProfileSetId")
        } else {
            self.profileSets = sets.sorted(by: { $0.name < $1.name })
            let savedId = UserDefaults.standard.string(forKey: "selectedProfileSetId")
            if let savedId = savedId, sets.contains(where: { $0.id == savedId }) {
                self.selectedProfileSetId = savedId
            } else {
                self.selectedProfileSetId = sets.first?.id
            }
        }

        // Migrate legacy nil/empty profileSetId nodes and configs to the resolved selectedProfileSetId
        let targetSetId = self.selectedProfileSetId ?? ""
        if !targetSetId.isEmpty {
            if let configs = try? context.fetch(FetchDescriptor<BrowserConfig>()) {
                for config in configs {
                    if !config.isEnabled {
                        config.profileSetId = nil
                    } else if config.profileSetId == nil || config.profileSetId == "" {
                        config.profileSetId = targetSetId
                    }
                }
            }
            if let nodes = try? context.fetch(FetchDescriptor<BookmarkNode>()) {
                for node in nodes {
                    if node.profileSetId == nil || node.profileSetId == "" {
                        node.profileSetId = targetSetId
                        // Also prefix its ID and parentId if they are not already prefixed!
                        if !node.id.starts(with: targetSetId + ":") {
                            node.id = "\(targetSetId):\(node.id)"
                        }
                        if let parentId = node.parentId, !parentId.isEmpty, !parentId.starts(with: targetSetId + ":") {
                            node.parentId = "\(targetSetId):\(parentId)"
                        }
                    }
                }
            }
            try? context.save()
        }
    }

    func deleteProfileSet(withId id: String) {
        guard let context = modelContext else { return }

        // 1. Delete associated BookmarkNode entities
        if let nodes = try? context.fetch(FetchDescriptor<BookmarkNode>()) {
            for node in nodes {
                if node.profileSetId == id {
                    context.delete(node)
                }
            }
        }

        // 2. Clear profileSetId and disable associated configs
        if let configs = try? context.fetch(FetchDescriptor<BrowserConfig>()) {
            for config in configs {
                if config.profileSetId == id {
                    config.profileSetId = nil
                    config.isEnabled = false
                    WriteQueue.shared.removePendingWrites(for: config.bookmarkFilePath)
                }
            }
        }

        // 3. Delete the ProfileSet itself
        if let sets = try? context.fetch(FetchDescriptor<ProfileSet>()) {
            if let targetSet = sets.first(where: { $0.id == id }) {
                context.delete(targetSet)
            }
        }

        try? context.save()

        // 4. Clear associated queue/diff history items
        diffHistory.removeAll { $0.profileSetId == id }

        // 5. Renumber remaining sets to prevent gaps
        if let remainingSets = try? context.fetch(FetchDescriptor<ProfileSet>()) {
            let sortedSets = remainingSets.sorted { s1, s2 in
                let prefix = "Set "
                let n1 = s1.name.hasPrefix(prefix) ? (Int(s1.name.dropFirst(prefix.count)) ?? 0) : 0
                let n2 = s2.name.hasPrefix(prefix) ? (Int(s2.name.dropFirst(prefix.count)) ?? 0) : 0
                return n1 < n2
            }
            
            for (index, set) in sortedSets.enumerated() {
                if set.name.hasPrefix("Set ") {
                    set.name = "Set \(index + 1)"
                }
            }
            try? context.save()
        }

        // Refresh local lists
        loadProfileSets()
    }

    func cleanOrphanedNodes(for profileSetId: String) {
        guard let context = modelContext, !profileSetId.isEmpty else { return }

        let allConfigs = (try? context.fetch(FetchDescriptor<BrowserConfig>())) ?? []
        let remainingConfigs = allConfigs.filter { $0.isEnabled && $0.profileSetId == profileSetId }

        var validIds = Set<String>()
        for config in remainingConfigs {
            if let data = config.observedStateData,
               let decoded = try? JSONDecoder().decode([String: BookmarkNodeRecord].self, from: data) {
                validIds.formUnion(decoded.keys)
            }
        }

        let allNodes = (try? context.fetch(FetchDescriptor<BookmarkNode>())) ?? []
        let setNodes = allNodes.filter { $0.profileSetId == profileSetId }

        var deletedCount = 0
        for node in setNodes {
            if !validIds.contains(node.id) {
                context.delete(node)
                cancelPendingDiffs(for: node.title)
                deletedCount += 1
            }
        }

        if deletedCount > 0 {
            try? context.save()
            print("Cleaned \(deletedCount) orphaned nodes after profile disable.")

            // Clear pending writes for remaining configs so SyncEngine can rebuild diffs cleanly
            for config in remainingConfigs {
                WriteQueue.shared.removePendingWrites(for: config.bookmarkFilePath)
            }
        }
    }

    func addProfileSet() {
        guard profileSets.count < 9 else { return }
        guard let context = modelContext else { return }

        // Find the maximum existing Set number to prevent duplicates
        let existingNums = profileSets.compactMap { set -> Int? in
            let prefix = "Set "
            guard set.name.hasPrefix(prefix) else { return nil }
            return Int(set.name.dropFirst(prefix.count))
        }
        let nextNum = (existingNums.max() ?? 0) + 1

        let newSet = ProfileSet(name: "Set \(nextNum)")
        context.insert(newSet)
        try? context.save()
        
        loadProfileSets()
        self.selectedProfileSetId = newSet.id
        UserDefaults.standard.set(newSet.id, forKey: "selectedProfileSetId")
    }
}
