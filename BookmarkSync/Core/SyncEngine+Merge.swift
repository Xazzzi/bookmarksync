import Foundation
import SwiftData

extension SyncEngine {
    func filterEmptyFolders(nodes: [BookmarkNode]) -> [BookmarkNode] {
        var parentToChildren: [String?: [BookmarkNode]] = [:]
        for node in nodes {
            parentToChildren[node.parentId, default: []].append(node)
        }
        
        func hasLeafDescendant(_ node: BookmarkNode) -> Bool {
            if node.type == .leaf {
                return true
            }
            guard let children = parentToChildren[node.id] else {
                return false
            }
            for child in children {
                if hasLeafDescendant(child) {
                    return true
                }
            }
            return false
        }
        
        return nodes.filter { node in
            if node.type == .leaf {
                return true
            }
            return hasLeafDescendant(node)
        }
    }
    
    func merge(
        state: [BookmarkNode],
        browsers: [[BookmarkNode]],
        activeConfigs: [BrowserConfig],
        initialSyncMap: [String: Bool] = [:],
        profileSetId: String = ""
    ) -> ([BookmarkNode], [DiffRecord]) {
        var updatedStateNodes = state
        
        for (idx, config) in activeConfigs.enumerated() {
            guard idx < browsers.count else { continue }
            let currentNodes = browsers[idx]
            
            let latestNodes: [String: BookmarkNode]
            if let cached = viewModel.latestBrowserNodes[config.id] {
                latestNodes = cached
            } else if let data = config.observedStateData,
                      let decoded = try? JSONDecoder().decode([String: BookmarkNodeRecord].self, from: data) {
                var nodeMap: [String: BookmarkNode] = [:]
                for (id, record) in decoded {
                    nodeMap[id] = BookmarkNode(
                        id: id,
                        title: record.title,
                        url: record.url,
                        type: record.type,
                        parentId: record.parentId,
                        mtime: Date(),
                        profileSetId: profileSetId,
                        index: record.index ?? 0
                    )
                }
                latestNodes = nodeMap
            } else {
                latestNodes = [:]
            }
            
            let currentDict = Dictionary(currentNodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            
            let isNewlyEnabled = config.lastSyncTime == nil || initialSyncMap[config.id] == true
            
            // Handle deletions
            if !isNewlyEnabled {
                for (id, _) in latestNodes {
                    if currentDict[id] == nil {
                        if let idx = updatedStateNodes.firstIndex(where: { $0.id == id }) {
                            updatedStateNodes.remove(at: idx)
                        }
                    }
                }
            }
            
            // Handle additions and updates
            for (id, currentNode) in currentDict {
                if let latestNode = latestNodes[id] {
                    if !isNewlyEnabled {
                        if currentNode.title != latestNode.title || currentNode.url != latestNode.url || currentNode.parentId != latestNode.parentId || currentNode.index != latestNode.index {
                            if let stateNode = updatedStateNodes.first(where: { $0.id == id }) {
                                if stateNode.title != currentNode.title || stateNode.url != currentNode.url || stateNode.parentId != currentNode.parentId || stateNode.index != currentNode.index {
                                    stateNode.title = currentNode.title
                                    stateNode.url = currentNode.url
                                    stateNode.parentId = currentNode.parentId
                                    stateNode.index = currentNode.index
                                }
                            }
                        }
                    }
                } else {
                    if !updatedStateNodes.contains(where: { $0.id == id }) {
                        updatedStateNodes.append(currentNode)
                    }
                }
            }
        }
        
        let filtered = filterEmptyFolders(nodes: updatedStateNodes)
        
        var parentGroups: [String?: [BookmarkNode]] = [:]
        for node in filtered {
            parentGroups[node.parentId, default: []].append(node)
        }
        
        for (_, children) in parentGroups {
            let sortedChildren = children.sorted { 
                if $0.index == $1.index {
                    if $0.mtime == $1.mtime {
                        return $0.id < $1.id
                    }
                    return $0.mtime > $1.mtime
                }
                return $0.index < $1.index 
            }
            
            for (i, child) in sortedChildren.enumerated() {
                child.index = i
            }
        }
        
        return (filtered, [])
    }
}
