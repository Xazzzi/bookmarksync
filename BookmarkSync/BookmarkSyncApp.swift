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
        
        WindowGroup("Welcome to BookmarkSync", id: "onboarding") {
            OnboardingView()
        }
        .windowResizability(.contentSize)
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
            
            DockManager.shared.startMonitoring()
            DockManager.shared.updateDockIcon()
        }
    }
}

class DockManager {
    static let shared = DockManager()
    private var observers: [Any] = []
    
    weak var lastActiveBookmarksWindow: NSWindow?
    weak var lastActiveBackupsWindow: NSWindow?
    
    func startMonitoring() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { notification in
            if let window = notification.object as? NSWindow {
                if window.title == "Unified Bookmarks" {
                    self.lastActiveBookmarksWindow = window
                } else if window.title == "Backups Manager" {
                    self.lastActiveBackupsWindow = window
                }
            }
            self.updateDockIcon()
        })
        observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { _ in
            DispatchQueue.main.async {
                self.updateDockIcon()
            }
        })
    }
    
    func updateDockIcon() {
        let visibleMainWindows = NSApp.windows.filter { 
            ($0.title == "Unified Bookmarks" || $0.title == "Backups Manager") && $0.isVisible 
        }
        
        if visibleMainWindows.isEmpty {
            if NSApp.activationPolicy() != .accessory {
                NSApp.setActivationPolicy(.accessory)
            }
        } else {
            if NSApp.activationPolicy() != .regular {
                NSApp.setActivationPolicy(.regular)
            }
        }
    }
}
