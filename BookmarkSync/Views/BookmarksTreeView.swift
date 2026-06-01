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
    
    @State var selectedId: String?
    @State var searchQuery: String = ""
    @State var expandedIds: Set<String> = []
    @State var filterProfileSetId: String = "global"
    
    var filteredNodes: [BookmarkNode] {
        let validNodes = allNodes.filter { !$0.isDeleted }
        
        if filterProfileSetId == "global" {
            var mergedMap = [String: BookmarkNode]()
            let sortedAll = validNodes.sorted(by: { $0.mtime < $1.mtime })
            
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
            return validNodes.filter { $0.profileSetId == filterProfileSetId }
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
                        
                        ForEach(profileSets.filter { !$0.isDeleted }) { pSet in
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
                                selectedId = nil
                                let idToDelete = filterProfileSetId
                                filterProfileSetId = "global"
                                
                                DispatchQueue.main.async {
                                    viewModel.deleteProfileSet(withId: idToDelete)
                                }
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
                                Image(systemName: node.type == .folder ? (node.title == "Deleted by BookmarkSync" ? "trash.fill" : "folder.fill") : "bookmark.fill")
                                    .foregroundColor(node.type == .folder ? (node.title == "Deleted by BookmarkSync" ? .red : .orange) : .blue)
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
                BookmarkTreeDetailView(
                    node: node,
                    configs: configs.map { $0 },
                    viewModel: viewModel,
                    revealInTree: revealInTree,
                    getBreadcrumbsList: getBreadcrumbsList
                )
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
    

}

// Tree model structures


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

