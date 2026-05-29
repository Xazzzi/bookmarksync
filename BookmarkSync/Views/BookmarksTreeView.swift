import SwiftUI
import SwiftData

struct BookmarkTreeElement: Identifiable, Hashable {
    let id: String
    let title: String
    let url: String?
    let type: BookmarkType
    let mtime: Date
    let parentId: String?
    var children: [BookmarkTreeElement]?
}

struct BookmarksTreeView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \BookmarkNode.title) var allNodes: [BookmarkNode]
    @Query var configs: [BrowserConfig]
    @Query var profileSets: [ProfileSet]
    
    @ObservedObject var viewModel: AppViewModel
    
    @State private var selectedId: String?
    @State private var searchQuery: String = ""
    @State private var expandedIds: Set<String> = []
    @State private var filterProfileSetId: String = "global"
    
    private var filteredNodes: [BookmarkNode] {
        if filterProfileSetId == "global" {
            var mergedMap = [String: BookmarkNode]()
            let sortedAll = allNodes.sorted(by: { $0.mtime < $1.mtime })
            
            for node in sortedAll {
                let strippedId = stripProfileSetPrefix(node.id)
                let strippedParentId = node.parentId.map { stripProfileSetPrefix($0) }
                
                let mergedNode = BookmarkNode(
                    id: strippedId,
                    title: node.title,
                    url: node.url,
                    type: node.type,
                    parentId: strippedParentId,
                    mtime: node.mtime,
                    profileSetId: nil,
                    index: node.index
                )
                mergedMap[strippedId] = mergedNode
            }
            
            return Array(mergedMap.values).sorted(by: { $0.title < $1.title })
        } else {
            return allNodes.filter { $0.profileSetId == filterProfileSetId }
        }
    }
    
    var body: some View {
        NavigationSplitView {
            // Left Sidebar: Treeview / Search Results
            VStack(spacing: 0) {
                // Search Bar
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField("Search bookmarks...", text: $searchQuery)
                        .textFieldStyle(.plain)
                    if !searchQuery.isEmpty {
                        Button(action: { searchQuery = "" }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(8)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(8)
                .padding(.horizontal, 10)
                .padding(.top, 10)
                .padding(.bottom, 6)
                
                // Sidebar Toolbar & Filter Icons Row
                HStack(spacing: 8) {
                    // Filter icons
                    HStack(spacing: 4) {
                        Button(action: {
                            filterProfileSetId = "global"
                        }) {
                            GlobalSetIcon(isActive: filterProfileSetId == "global")
                        }
                        .buttonStyle(.plain)
                        .help("Global Bookmarks")
                        
                        ForEach(profileSets) { pSet in
                            Button(action: {
                                filterProfileSetId = pSet.id
                            }) {
                                ProfileSetIcon(name: pSet.name, isActive: filterProfileSetId == pSet.id)
                            }
                            .buttonStyle(.plain)
                            .help(pSet.name)
                        }
                        
                        if filterProfileSetId != "global" {
                            Button(action: {
                                let idToDelete = filterProfileSetId
                                filterProfileSetId = "global"
                                viewModel.deleteProfileSet(withId: idToDelete)
                            }) {
                                Image(systemName: "folder.badge.minus")
                                    .foregroundColor(.red)
                            }
                            .buttonStyle(.plain)
                            .help("Delete selected Profile Set")
                        }
                    }
                    
                    Spacer()
                    
                    if searchQuery.isEmpty {
                        Button(action: expandAll) {
                            Image(systemName: "chevron.down.square")
                        }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .help("Expand All")
                        
                        Button(action: collapseAll) {
                            Image(systemName: "chevron.up.square")
                        }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .help("Collapse All")
                    } else {
                        Text("\(filteredFlatNodes().count) found")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    Button(action: {
                        viewModel.rescanProfiles()
                    }) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .help("Rescan profiles")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                
                Divider()
                
                // List / ScrollView
                if filteredNodes.isEmpty {
                    VStack(spacing: 12) {
                        Spacer()
                        Image(systemName: "bookmark.slash")
                            .font(.system(size: 32))
                            .foregroundColor(.secondary)
                        Text("No Bookmarks")
                            .font(.headline)
                        Text("Connect profiles in the tray and sync to import them here.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 20)
                        Spacer()
                    }
                } else if !searchQuery.isEmpty {
                    // Search Flat List View
                    List(filteredFlatNodes(), id: \.id) { node in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Image(systemName: node.type == .folder ? "folder.fill" : "bookmark.fill")
                                    .foregroundColor(node.type == .folder ? .orange : .blue)
                                Text(node.title)
                                    .fontWeight(.medium)
                            }
                            
                            if let urlStr = node.url {
                                Text(urlStr)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                            
                            // Breadcrumbs path
                            let path = getBreadcrumbPath(for: node)
                            if !path.isEmpty {
                                Text(path)
                                    .font(.system(size: 9))
                                    .foregroundColor(.gray)
                                    .lineLimit(1)
                            }
                        }
                        .padding(.vertical, 2)
                        .contentShape(Rectangle())
                        .listRowBackground(selectedId == node.id ? Color.accentColor : Color.clear)
                        .foregroundColor(selectedId == node.id ? .white : .primary)
                        .onTapGesture {
                            selectedId = node.id
                        }
                        .contextMenu {
                            if node.type == .leaf, let urlStr = node.url, let url = URL(string: urlStr) {
                                Button("Open in Browser") {
                                    NSWorkspace.shared.open(url)
                                }
                                Button("Copy URL") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(urlStr, forType: .string)
                                }
                            }
                            Button("Copy ID") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(node.id, forType: .string)
                            }
                            Button("Reveal in Tree") {
                                revealInTree(node)
                            }
                        }
                    }
                } else {
                    // Recursive Tree ScrollView
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            let roots = buildTreeModel()
                            ForEach(roots) { root in
                                BookmarkTreeRow(
                                    element: root,
                                    expandedIds: $expandedIds,
                                    selectedId: $selectedId
                                )
                            }
                        }
                        .padding(10)
                    }
                    .focusable()
                    .focusEffectDisabled()
                    .onKeyPress { press in
                        let visible = getVisibleNodes()
                        guard !visible.isEmpty else { return .ignored }
                        
                        let currentIndex = selectedId.flatMap { selId in visible.firstIndex(where: { $0.id == selId }) }
                        
                        switch press.key {
                        case .upArrow:
                            if let idx = currentIndex {
                                if idx > 0 {
                                    selectedId = visible[idx - 1].id
                                }
                            } else {
                                selectedId = visible.first?.id
                            }
                            return .handled
                            
                        case .downArrow:
                            if let idx = currentIndex {
                                if idx < visible.count - 1 {
                                    selectedId = visible[idx + 1].id
                                }
                            } else {
                                selectedId = visible.first?.id
                            }
                            return .handled
                            
                        case .leftArrow:
                            guard let idx = currentIndex else { return .ignored }
                            let elem = visible[idx]
                            if elem.type == .folder && expandedIds.contains(elem.id) {
                                _ = withAnimation(.easeOut(duration: 0.15)) {
                                    expandedIds.remove(elem.id)
                                }
                            } else if let pId = elem.parentId, !pId.isEmpty {
                                selectedId = pId
                            }
                            return .handled
                            
                        case .rightArrow:
                            guard let idx = currentIndex else { return .ignored }
                            let elem = visible[idx]
                            if elem.type == .folder {
                                if !expandedIds.contains(elem.id) {
                                    _ = withAnimation(.easeOut(duration: 0.15)) {
                                        expandedIds.insert(elem.id)
                                    }
                                } else if let children = elem.children, !children.isEmpty {
                                    selectedId = children.first?.id
                                }
                            }
                            return .handled
                            
                        case .return, .space:
                            guard let idx = currentIndex else { return .ignored }
                            let elem = visible[idx]
                            if elem.type == .folder {
                                withAnimation(.easeOut(duration: 0.15)) {
                                    if expandedIds.contains(elem.id) {
                                        expandedIds.remove(elem.id)
                                    } else {
                                        expandedIds.insert(elem.id)
                                    }
                                }
                            } else if let urlStr = elem.url, let url = URL(string: urlStr) {
                                NSWorkspace.shared.open(url)
                            }
                            return .handled
                            
                        default:
                            return .ignored
                        }
                    }
                }
            }
            .frame(minWidth: 260, idealWidth: 300)
        } detail: {
            // Right Pane: Inspector Details
            if let node = selectedNode() {
                VStack(spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            // Large stylized header
                            HStack(spacing: 12) {
                                ZStack {
                                    Circle()
                                        .fill(node.type == .folder ? Color.orange.opacity(0.15) : Color.blue.opacity(0.15))
                                        .frame(width: 48, height: 48)
                                    Image(systemName: node.type == .folder ? "folder.fill" : "bookmark.fill")
                                        .font(.system(size: 22))
                                        .foregroundColor(node.type == .folder ? .orange : .blue)
                                }
                                
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(node.title)
                                        .font(.title3)
                                        .bold()
                                        .lineLimit(2)
                                    Text(node.type == .folder ? "Folder" : "Bookmark")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                            .padding(.top, 10)
                            
                            Divider()
                            
                            // Info Sections
                            VStack(alignment: .leading, spacing: 12) {
                                // Breadcrumbs location path
                                let breadcrumbs = getBreadcrumbsList(for: node)
                                if !breadcrumbs.isEmpty {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("Location").font(.caption).foregroundColor(.secondary).bold()
                                        ScrollView(.horizontal, showsIndicators: false) {
                                            HStack(spacing: 4) {
                                                ForEach(Array(breadcrumbs.enumerated()), id: \.offset) { index, parent in
                                                    Button(parent.title) {
                                                        revealInTree(parent)
                                                    }
                                                    .buttonStyle(.link)
                                                    .foregroundColor(.blue)
                                                    
                                                    if index < breadcrumbs.count - 1 {
                                                        Image(systemName: "chevron.right")
                                                            .font(.system(size: 8))
                                                            .foregroundColor(.secondary)
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                                
                                // Bookmark Target URL
                                if node.type == .leaf, let urlStr = node.url {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text("Target URL").font(.caption).foregroundColor(.secondary).bold()
                                        
                                        HStack(alignment: .center, spacing: 6) {
                                            if let url = URL(string: urlStr) {
                                                Button(action: {
                                                    NSWorkspace.shared.open(url)
                                                }) {
                                                    Text(urlStr)
                                                        .font(.system(.body, design: .monospaced))
                                                        .foregroundColor(.blue)
                                                        .underline()
                                                        .multilineTextAlignment(.leading)
                                                        .lineLimit(3)
                                                        .padding(6)
                                                        .background(Color(NSColor.controlBackgroundColor))
                                                        .cornerRadius(6)
                                                }
                                                .buttonStyle(.plain)
                                                .help("Click to open link in default browser")
                                            } else {
                                                Text(urlStr)
                                                    .font(.system(.body, design: .monospaced))
                                                    .foregroundColor(.primary)
                                                    .padding(6)
                                                    .background(Color(NSColor.controlBackgroundColor))
                                                    .cornerRadius(6)
                                            }
                                            
                                            Button(action: {
                                                NSPasteboard.general.clearContents()
                                                NSPasteboard.general.setString(urlStr, forType: .string)
                                            }) {
                                                Image(systemName: "doc.on.doc")
                                                    .foregroundColor(.secondary)
                                            }
                                            .buttonStyle(.plain)
                                            .help("Copy URL")
                                        }
                                    }
                                }
                                
                                // Database Properties
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Metadata").font(.caption).foregroundColor(.secondary).bold()
                                    
                                    VStack(spacing: 8) {
                                        MetadataRow(label: "Node ID", value: node.id)
                                        MetadataRow(label: "Parent ID", value: node.parentId ?? "None")
                                        MetadataRow(label: "Index", value: "\(node.index)")
                                        MetadataRow(label: "Last Modified", value: formattedDate(node.mtime))
                                    }
                                    .padding(10)
                                    .background(Color(NSColor.windowBackgroundColor))
                                    .cornerRadius(6)
                                }
                            }
                            
                            Divider()
                            
                            // Browser Sync Statuses
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Browser Synchronization").font(.headline)
                                
                                ForEach(configs.sorted(by: { $0.browserName < $1.browserName })) { config in
                                    let status = viewModel.syncStatus(for: node.id, config: config)
                                    let isGrayscale = status == .mismatch || status == .writePending
                                    
                                    HStack(spacing: 10) {
                                        if let icon = BrowserDiscoverer.getIcon(for: config.bundleId) {
                                            Image(nsImage: icon)
                                                .resizable()
                                                .frame(width: 18, height: 18)
                                                .grayscale(isGrayscale ? 1.0 : 0.0)
                                        } else {
                                            Image(systemName: "globe")
                                                .resizable()
                                                .frame(width: 18, height: 18)
                                                .foregroundColor(.secondary)
                                                .grayscale(isGrayscale ? 1.0 : 0.0)
                                        }
                                        
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(config.browserName)
                                                .font(.body)
                                                .bold()
                                            Text(config.profileName)
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                        }
                                        
                                        Spacer()
                                        
                                        // Status badge
                                        Text(status.rawValue)
                                            .font(.caption2)
                                            .bold()
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 3)
                                            .background(badgeColor(for: status).opacity(0.15))
                                            .foregroundColor(badgeColor(for: status))
                                            .cornerRadius(6)
                                    }
                                    .padding(8)
                                    .background(Color(NSColor.controlBackgroundColor))
                                    .cornerRadius(6)
                                }
                            }
                        }
                        .padding(20)
                    }
                    
                }
                .frame(minWidth: 320, idealWidth: 380)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "bookmark")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text("Select a bookmark or folder")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    Text("Browse hierarchies and inspect synchronized states across browsers.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }
                .frame(minWidth: 320, idealWidth: 380)
            }
        }
        .onAppear {
            viewModel.modelContext = modelContext
            viewModel.rescanProfiles()
        }
    }
    
    // Helpers
    private func selectedNode() -> BookmarkNode? {
        filteredNodes.first { $0.id == selectedId }
    }
    
    private func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }
    
    private func badgeColor(for status: AppViewModel.NodeSyncStatus) -> Color {
        switch status {
        case .synced: return .green
        case .mismatch: return .orange
        case .writePending: return .blue
        case .disabled: return .gray
        case .unknown: return .secondary
        }
    }
    
    private func buildTreeModel() -> [BookmarkTreeModelElement] {
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
    
    private func getVisibleNodes() -> [BookmarkTreeModelElement] {
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
    
    private func filteredFlatNodes() -> [BookmarkNode] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if query.isEmpty { return filteredNodes }
        return filteredNodes.filter { node in
            node.title.lowercased().contains(query) || (node.url ?? "").lowercased().contains(query)
        }
    }
    
    private func getBreadcrumbPath(for node: BookmarkNode) -> String {
        var path = [String]()
        var current: BookmarkNode? = node
        let nodeDict = Dictionary(filteredNodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        while let pId = current?.parentId, !pId.isEmpty, let parent = nodeDict[pId] {
            path.insert(parent.title, at: 0)
            current = parent
        }
        return path.joined(separator: " > ")
    }
    
    private func getBreadcrumbsList(for node: BookmarkNode) -> [BookmarkNode] {
        var list = [BookmarkNode]()
        var current: BookmarkNode? = node
        let nodeDict = Dictionary(filteredNodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        while let pId = current?.parentId, !pId.isEmpty, let parent = nodeDict[pId] {
            list.insert(parent, at: 0)
            current = parent
        }
        return list
    }
    
    private func expandAll() {
        let folderIds = filteredNodes.filter { $0.type == .folder }.map { $0.id }
        expandedIds = Set(folderIds)
    }
    
    private func collapseAll() {
        expandedIds.removeAll()
    }
    
    private func revealInTree(_ node: BookmarkNode) {
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

// Tree model structures
struct BookmarkTreeModelElement: Identifiable {
    let id: String
    let title: String
    let url: String?
    let type: BookmarkType
    let mtime: Date
    let parentId: String?
    let index: Int
    var children: [BookmarkTreeModelElement]?
}

struct BookmarkTreeRow: View {
    let element: BookmarkTreeModelElement
    @Binding var expandedIds: Set<String>
    @Binding var selectedId: String?
    
    var body: some View {
        if element.type == .folder {
            BookmarkFolderRow(element: element, expandedIds: $expandedIds, selectedId: $selectedId)
        } else {
            BookmarkLeafRow(element: element, selectedId: $selectedId)
        }
    }
}

struct BookmarkFolderRow: View {
    let element: BookmarkTreeModelElement
    @Binding var expandedIds: Set<String>
    @Binding var selectedId: String?
    
    @State private var isHovered = false
    
    var isExpanded: Bool {
        expandedIds.contains(element.id)
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                // Expanding chevron
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.secondary)
                    .rotationEffect(isExpanded ? .degrees(90) : .degrees(0))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        toggleExpand()
                    }
                
                Image(systemName: "folder.fill")
                    .font(.system(size: 13))
                    .foregroundColor(selectedId == element.id ? .white.opacity(0.9) : .blue)
                
                Text(element.title)
                    .font(.system(size: 13))
                    .lineLimit(1)
                
                Spacer()
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .background(
                selectedId == element.id ? Color.accentColor :
                (isHovered ? Color.gray.opacity(0.15) : Color.clear)
            )
            .foregroundColor(selectedId == element.id ? .white : .primary)
            .cornerRadius(4)
            .onTapGesture {
                selectedId = element.id
            }
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                toggleExpand()
            })
            .onHover { hovering in
                isHovered = hovering
            }
            
            if isExpanded, let children = element.children {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(children) { child in
                        BookmarkTreeRow(
                            element: child,
                            expandedIds: $expandedIds,
                            selectedId: $selectedId
                        )
                    }
                }
                .padding(.leading, 14)
            }
        }
    }
    
    private func toggleExpand() {
        withAnimation(.easeOut(duration: 0.15)) {
            if isExpanded {
                expandedIds.remove(element.id)
            } else {
                expandedIds.insert(element.id)
            }
        }
    }
}

struct BookmarkLeafRow: View {
    let element: BookmarkTreeModelElement
    @Binding var selectedId: String?
    
    @State private var isHovered = false
    
    var body: some View {
        HStack(spacing: 6) {
            // Spacer to align perfectly with folders (chevron width + folder offset)
//            Spacer()
//                .frame(width: 0)
            
            Image(systemName: "link")
                .font(.system(size: 12))
                .foregroundColor(selectedId == element.id ? .white.opacity(0.8) : .secondary)
            
            Text(element.title)
                .font(.system(size: 13))
                .lineLimit(1)
            
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .background(
            selectedId == element.id ? Color.accentColor :
            (isHovered ? Color.gray.opacity(0.15) : Color.clear)
        )
        .foregroundColor(selectedId == element.id ? .white : .primary)
        .cornerRadius(4)
        .onTapGesture {
            selectedId = element.id
        }
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            if let urlString = element.url, let url = URL(string: urlString) {
                NSWorkspace.shared.open(url)
            }
        })
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

struct MetadataRow: View {
    let label: String
    let value: String
    
    var body: some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.caption)
                .bold()
                .foregroundColor(.secondary)
                .frame(width: 100, alignment: .leading)
            
            Spacer()
            
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.primary)
                .lineLimit(5)
                .multilineTextAlignment(.trailing)
        }
    }
}

#Preview("Empty State") {
    do {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: BookmarkNode.self, BrowserConfig.self, ProfileSet.self, configurations: config)
        return BookmarksTreeView(viewModel: AppViewModel())
            .modelContainer(container)
    } catch {
        return Text("Failed to create container: \(error.localizedDescription)")
    }
}

#Preview("With Dummy Data") {
    do {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: BookmarkNode.self, BrowserConfig.self, ProfileSet.self, configurations: config)
        let context = container.mainContext
        
        let pSet = ProfileSet(name: "Set 1")
        context.insert(pSet)
        
        let browser = BrowserConfig(id: "safari-1", bundleId: "com.apple.Safari", browserName: "Safari", profileName: "Default", bookmarkFilePath: "/dummy/path", isEnabled: true, profileSetId: pSet.id)
        context.insert(browser)
        
        let folder1 = BookmarkNode(id: "\(pSet.id):folder1", title: "Development", type: .folder, mtime: Date(), profileSetId: pSet.id, index: 0)
        context.insert(folder1)
        
        let leaf1 = BookmarkNode(id: "\(pSet.id):node1", title: "Apple Developer", url: "https://developer.apple.com", type: .leaf, parentId: folder1.id, mtime: Date(), profileSetId: pSet.id, index: 0)
        context.insert(leaf1)
        
        let leaf2 = BookmarkNode(id: "\(pSet.id):node2", title: "SwiftUI Docs", url: "https://developer.apple.com/xcode/swiftui/", type: .leaf, parentId: folder1.id, mtime: Date(), profileSetId: pSet.id, index: 1)
        context.insert(leaf2)
        
        let leaf3 = BookmarkNode(id: "\(pSet.id):node3", title: "Google", url: "https://google.com", type: .leaf, mtime: Date(), profileSetId: pSet.id, index: 1)
        context.insert(leaf3)
        
        try context.save()
        
        let viewModel = AppViewModel()
        viewModel.profileSets = [pSet]
        viewModel.selectedProfileSetId = pSet.id
        
        return BookmarksTreeView(viewModel: viewModel)
            .modelContainer(container)
    } catch {
        return Text("Failed to create container: \(error.localizedDescription)")
    }
}

