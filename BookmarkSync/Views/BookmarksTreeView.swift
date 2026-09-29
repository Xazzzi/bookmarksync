import SwiftUI
import SwiftData

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

    /// Cached projection of `allNodes`. Rebuilt only when the store or the
    /// profile-set filter changes — never per view-body evaluation.
    @State private var snapshot: BookmarkTreeSnapshot = .empty
    /// Cached flattening of the visible rows for the current expansion state.
    @State private var visibleRows: [BookmarkFlatRow] = []
    /// Cached search results for the current query.
    @State private var searchResults: [BookmarkItem] = []

    var body: some View {
        NavigationSplitView {
            // Left Sidebar: Treeview / Search Results
            VStack(spacing: 0) {
                searchBar
                filterRow

                Divider()

                if snapshot.isEmpty {
                    emptyState
                } else if !searchQuery.isEmpty {
                    searchList
                } else {
                    treeList
                }
            }
            .frame(minWidth: 260, idealWidth: 300)
        } detail: {
            // Right Pane: Inspector Details
            if let item = snapshot.item(id: selectedId) {
                BookmarkTreeDetailView(
                    item: item,
                    breadcrumbs: snapshot.breadcrumbs(for: item.id),
                    configs: configs.map { $0 },
                    viewModel: viewModel,
                    revealInTree: revealInTree
                )
                .frame(minWidth: 320, idealWidth: 380)
            } else {
                noSelectionState
            }
        }
        .onAppear {
            viewModel.modelContext = modelContext
            viewModel.rescanProfiles()
            rebuildSnapshot()
        }
        // Recompute the cached projections only on the changes that affect them.
        .onChange(of: allNodes.count) { _, _ in rebuildSnapshot() }
        .onChange(of: viewModel.bookmarkDataRevision) { _, _ in rebuildSnapshot() }
        .onChange(of: filterProfileSetId) { _, _ in rebuildSnapshot() }
        .onChange(of: expandedIds) { _, _ in rebuildVisibleRows() }
        .onChange(of: searchQuery) { _, _ in rebuildSearchResults() }
    }

    // MARK: - Cached state maintenance

    private func rebuildSnapshot() {
        snapshot = BookmarkTreeSnapshot(
            nodes: allNodes,
            profileSetFilter: filterProfileSetId == "global" ? nil : filterProfileSetId
        )
        // Drop expansion/selection state that no longer refers to a live node.
        // Only assign when something actually changed, so we don't trigger a
        // redundant `onChange(of: expandedIds)` pass.
        let prunedExpanded = expandedIds.filter { snapshot.byId[$0] != nil }
        if prunedExpanded != expandedIds {
            expandedIds = prunedExpanded
        }
        if let selectedId, snapshot.byId[selectedId] == nil {
            self.selectedId = nil
        }
        rebuildVisibleRows()
        rebuildSearchResults()
    }

    private func rebuildVisibleRows() {
        visibleRows = snapshot.flattenVisible(expandedIds: expandedIds)
    }

    private func rebuildSearchResults() {
        searchResults = searchQuery.isEmpty ? [] : snapshot.search(query: searchQuery)
    }

    // MARK: - Sidebar chrome

    private var searchBar: some View {
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
    }

    private var filterRow: some View {
        HStack(spacing: 8) {
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
                Text("\(searchResults.count) found")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - Lists

    private var searchList: some View {
        List(searchResults) { item in
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: item.type == .folder ? (item.title == "Deleted by BookmarkSync" ? "trash.fill" : "folder.fill") : "bookmark.fill")
                        .foregroundColor(item.type == .folder ? (item.title == "Deleted by BookmarkSync" ? .red : .orange) : .blue)
                    Text(item.title)
                        .fontWeight(.medium)
                }

                if let urlStr = item.url {
                    Text(urlStr)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                // Breadcrumbs path — a dictionary walk against the cached
                // snapshot, not a rebuild of the whole node map.
                Text(snapshot.breadcrumbPath(for: item.id))
                    .font(.system(size: 9))
                    .foregroundColor(.gray)
                    .lineLimit(1)
            }
            .padding(.vertical, 2)
            // Claim the full row width before setting the hit area: a VStack is
            // only as wide as its widest child, so with a short title and URL the
            // tappable region ended partway across the sidebar and clicks to the
            // right of the text did nothing.
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .listRowBackground(selectedId == item.id ? Color.accentColor : Color.clear)
            .foregroundColor(selectedId == item.id ? .white : .primary)
            .onTapGesture {
                selectedId = item.id
            }
            .contextMenu {
                if item.type == .leaf, let urlStr = item.url, let url = URL(string: urlStr) {
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
                    NSPasteboard.general.setString(item.id, forType: .string)
                }
                Button("Reveal in Tree") {
                    revealInTree(item.id)
                }
            }
        }
    }

    /// Lazy tree: only the rows on screen are instantiated, and the flattened
    /// row list is cached rather than rebuilt per body evaluation.
    private var treeList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(visibleRows) { row in
                    BookmarkTreeRow(
                        row: row,
                        isSelected: selectedId == row.item.id,
                        isExpanded: expandedIds.contains(row.item.id),
                        onSelect: { selectedId = $0 },
                        onToggleExpand: toggleExpand,
                        onOpenURL: { urlString in
                            if let url = URL(string: urlString) {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    )
                    .equatable()
                }
            }
            .padding(10)
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress { press in handleKeyPress(press) }
    }

    private var emptyState: some View {
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
    }

    private var noSelectionState: some View {
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

    // MARK: - Interaction

    private func toggleExpand(_ id: String) {
        withAnimation(.easeOut(duration: 0.15)) {
            if expandedIds.contains(id) {
                expandedIds.remove(id)
            } else {
                expandedIds.insert(id)
            }
        }
    }

    /// Arrow-key navigation over the cached visible-row list.
    private func handleKeyPress(_ press: KeyPress) -> KeyPress.Result {
        guard !visibleRows.isEmpty else { return .ignored }

        let currentIndex = selectedId.flatMap { selId in
            visibleRows.firstIndex(where: { $0.item.id == selId })
        }

        switch press.key {
        case .upArrow:
            if let idx = currentIndex {
                if idx > 0 { selectedId = visibleRows[idx - 1].item.id }
            } else {
                selectedId = visibleRows.first?.item.id
            }
            return .handled

        case .downArrow:
            if let idx = currentIndex {
                if idx < visibleRows.count - 1 { selectedId = visibleRows[idx + 1].item.id }
            } else {
                selectedId = visibleRows.first?.item.id
            }
            return .handled

        case .leftArrow:
            guard let idx = currentIndex else { return .ignored }
            let row = visibleRows[idx]
            if row.item.type == .folder && expandedIds.contains(row.item.id) {
                toggleExpand(row.item.id)
            } else if let pId = row.item.parentId, !pId.isEmpty {
                selectedId = pId
            }
            return .handled

        case .rightArrow:
            guard let idx = currentIndex else { return .ignored }
            let row = visibleRows[idx]
            if row.item.type == .folder {
                if !expandedIds.contains(row.item.id) {
                    toggleExpand(row.item.id)
                } else {
                    selectedId = snapshot.children(of: row.item.id).first?.id ?? selectedId
                }
            }
            return .handled

        case .return, .space:
            guard let idx = currentIndex else { return .ignored }
            let row = visibleRows[idx]
            if row.item.type == .folder {
                toggleExpand(row.item.id)
            } else if let urlStr = row.item.url, let url = URL(string: urlStr) {
                NSWorkspace.shared.open(url)
            }
            return .handled

        default:
            return .ignored
        }
    }

    func expandAll() {
        expandedIds = Set(snapshot.folderIds)
    }

    func collapseAll() {
        expandedIds.removeAll()
    }

    func revealInTree(_ id: String) {
        var toExpand = expandedIds
        for parent in snapshot.breadcrumbs(for: id) {
            toExpand.insert(parent.id)
        }
        expandedIds = toExpand
        selectedId = id
        searchQuery = "" // Reset search to switch to tree tab and highlight node!
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
