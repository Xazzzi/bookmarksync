import SwiftUI
import SwiftData

@main
struct BookmarkSyncApp: App {
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            BookmarkNode.self,
            BrowserConfig.self,
            ProfileSet.self
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()
    
    @StateObject private var viewModel = AppViewModel()
    @State private var engine: SyncEngine?


    var body: some Scene {
        MenuBarExtra("BookmarkSync", systemImage: "bookmark.fill") {
            TrayMenu(viewModel: viewModel)
                .modelContainer(sharedModelContainer)
                .onAppear {
                    setupSync()
                }
        }
        .menuBarExtraStyle(.window)
        
        WindowGroup("Backups Manager", id: "backups") {
            BackupsView(viewModel: viewModel)
                .modelContainer(sharedModelContainer)
        }
        .windowResizability(.contentSize)
        
        WindowGroup("Unified Bookmarks", id: "bookmarks") {
            BookmarksTreeView(viewModel: viewModel)
                .modelContainer(sharedModelContainer)
        }
    }
    
    private func setupSync() {
        if engine == nil {
            viewModel.modelContext = sharedModelContainer.mainContext
            viewModel.loadProfileSets()
            
            let newEngine = SyncEngine(modelContext: sharedModelContainer.mainContext, viewModel: viewModel)
            engine = newEngine
            viewModel.syncEngine = newEngine
            
            // Initial Sync
            newEngine.triggerSync(changedPaths: [], forceImmediate: true)
        }
    }
}
