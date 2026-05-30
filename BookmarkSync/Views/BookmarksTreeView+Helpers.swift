import SwiftUI

extension BookmarksTreeView {
    func selectedNode() -> BookmarkNode? {
        filteredNodes.first { $0.id == selectedId }
    }
    
    func buildTreeModel() -> [BookmarkTreeModelElement] {
        // Quick helper structure that is fully unmanaged
        struct LocalNode {
            let id: String
            let title: String
            let url: String?
            let type: BookmarkType
            let mtime: Date
            let parentId: String?
            let index: Int
        }
        
        let localNodes = filteredNodes.map { LocalNode(id: $0.id, title: $0.title, url: $0.url, type: $0.type, mtime: $0.mtime, parentId: $0.parentId, index: $0.index) }
        
        class TreeNode {
            let id: String
            let title: String
            let url: String?
            let type: BookmarkType
            let mtime: Date
            let parentId: String?
            let index: Int
            var children: [TreeNode]
            
            init(node: LocalNode) {
                self.id = node.id
                self.title = node.title
                self.url = node.url
                self.type = node.type
                self.mtime = node.mtime
                self.parentId = node.parentId
                self.index = node.index
                self.children = []
            }
            
            func toModelElement() -> BookmarkTreeModelElement {
                BookmarkTreeModelElement(
                    id: id,
                    title: title,
                    url: url,
                    type: type,
                    mtime: mtime,
                    parentId: parentId,
                    index: index,
                    children: type == .folder ? children.map { $0.toModelElement() } : nil
                )
            }
        }
        
        var dict = [String: TreeNode]()
        for node in localNodes {
            dict[node.id] = TreeNode(node: node)
        }
        
        var roots = [TreeNode]()
        for node in localNodes {
            guard let elem = dict[node.id] else { continue }
            if let pId = node.parentId, !pId.isEmpty, let parent = dict[pId] {
                parent.children.append(elem)
            } else {
                roots.append(elem)
            }
        }
        
        let rootModels = roots.map { $0.toModelElement() }
        
        func sortTree(_ elements: [BookmarkTreeModelElement]) -> [BookmarkTreeModelElement] {
            return elements.map { e -> BookmarkTreeModelElement in
                var copy = e
                if let children = copy.children {
                    copy.children = sortTree(children)
                }
                return copy
            }.sorted { a, b in
                if a.title == "Deleted by BookmarkSync" && b.title != "Deleted by BookmarkSync" { return false }
                if b.title == "Deleted by BookmarkSync" && a.title != "Deleted by BookmarkSync" { return true }
                
                if a.index == b.index {
                    if a.type != b.type {
                        return a.type == .folder
                    }
                    return a.title.localizedCompare(b.title) == .orderedAscending
                }
                return a.index < b.index
            }
        }
        
        return sortTree(rootModels)
    }
    
    func getVisibleNodes() -> [BookmarkTreeModelElement] {
        let roots = buildTreeModel()
        var result = [BookmarkTreeModelElement]()
        
        func traverse(_ element: BookmarkTreeModelElement) {
            result.append(element)
            if element.type == .folder && expandedIds.contains(element.id), let children = element.children {
                for child in children {
                    traverse(child)
                }
            }
        }
        
        for root in roots {
            traverse(root)
        }
        
        return result
    }
    
    func filteredFlatNodes() -> [BookmarkNode] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if query.isEmpty { return filteredNodes }
        return filteredNodes.filter { node in
            node.title.lowercased().contains(query) || (node.url ?? "").lowercased().contains(query)
        }
    }
    
    func getBreadcrumbPath(for node: BookmarkNode) -> String {
        var path = [String]()
        var current: BookmarkNode? = node
        let nodeDict = Dictionary(filteredNodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        while let pId = current?.parentId, !pId.isEmpty, let parent = nodeDict[pId] {
            path.insert(parent.title, at: 0)
            current = parent
        }
        return path.isEmpty ? "Root" : path.joined(separator: " > ")
    }
    
    func getBreadcrumbsList(for node: BookmarkNode) -> [BookmarkNode] {
        var list = [BookmarkNode]()
        var current: BookmarkNode? = node
        let nodeDict = Dictionary(filteredNodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        while let pId = current?.parentId, !pId.isEmpty, let parent = nodeDict[pId] {
            list.insert(parent, at: 0)
            current = parent
        }
        return list
    }
    
    func expandAll() {
        let folderIds = filteredNodes.filter { $0.type == .folder }.map { $0.id }
        expandedIds = Set(folderIds)
    }
    
    func collapseAll() {
        expandedIds.removeAll()
    }
    
    func revealInTree(_ node: BookmarkNode) {
        // Expand all parent nodes up to this node
        let nodeDict = Dictionary(filteredNodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var current: BookmarkNode? = node
        while let pId = current?.parentId, !pId.isEmpty, let parent = nodeDict[pId] {
            expandedIds.insert(parent.id)
            current = parent
        }
        
        selectedId = node.id
        searchQuery = "" // Reset search to switch to tree tab and highlight node!
    }
}
