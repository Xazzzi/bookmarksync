import SwiftUI
import SwiftData

struct TrayMenu: View {
    @ObservedObject var viewModel: AppViewModel
    @Query var configs: [BrowserConfig]
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openWindow) private var openWindow
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header Row: App Name + Status + Sync Controls
            HStack(alignment: .center) {
                Text("BookmarkSync")
                    .font(.system(size: 14, weight: .bold))

                Spacer()

                HStack(spacing: 12) {

                    // Stop Button
                    Button(action: {
                        viewModel.syncState = .stopped
                    }) {
                        Image(systemName: "stop.fill")
                            .foregroundColor(viewModel.syncState == .stopped ? .red : .secondary)
                            .font(.system(size: 14))
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Stop Syncing")

                    // Pause (Read-Only) Button
                    Button(action: {
                        viewModel.syncState = .readOnly
                    }) {
                        Image(systemName: "pause.fill")
                            .foregroundColor(viewModel.syncState == .readOnly ? .orange : .secondary)
                            .font(.system(size: 14))
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Pause (Read-Only Mode)")

                    // Play (Active) Button
                    Button(action: {
                        viewModel.syncState = .active
                    }) {
                        Image(systemName: "play.fill")
                            .foregroundColor(viewModel.syncState == .active ? .green : .secondary)
                            .font(.system(size: 14))
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Start (Active Syncing)")
                }
            }

            Divider()

            // Connected Profiles Header
            HStack(alignment: .center) {
                Text("Profiles")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.secondary)

                Spacer()

                HStack(spacing: 4) {
                    if viewModel.profileSets.count > 1 {
                        ForEach(viewModel.profileSets) { pSet in
                            Button(action: {
                                viewModel.selectedProfileSetId = pSet.id
                                UserDefaults.standard.set(pSet.id, forKey: "selectedProfileSetId")
                                viewModel.syncEngine?.triggerSync(changedPaths: [], forceImmediate: true)
                            }) {
                                ProfileSetIcon(name: pSet.name, isActive: viewModel.selectedProfileSetId == pSet.id)
                            }
                            .buttonStyle(.plain)
                            .help(pSet.name)
                        }
                    }

                    Button(action: {
                        let newNum = viewModel.profileSets.count + 1
                        let newSet = ProfileSet(name: "Set \(newNum)")
                        modelContext.insert(newSet)
                        try? modelContext.save()
                        viewModel.loadProfileSets()
                        viewModel.selectedProfileSetId = newSet.id
                        UserDefaults.standard.set(newSet.id, forKey: "selectedProfileSetId")
                    }) {
                        Image(systemName: "plus")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.secondary)
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Add Profile Set")
                }
            }

            let browserNames = Set(configs.map { $0.browserName } + ["Safari"])
            ForEach(browserNames.sorted(), id: \.self) { browserName in
                let browserConfigs = configs.filter { $0.browserName == browserName }
                let bundleId = browserConfigs.first?.bundleId ?? (browserName == "Safari" ? "com.apple.Safari" : "")

                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .center) {
                        if let icon = BrowserDiscoverer.getIcon(for: bundleId) {
                            Image(nsImage: icon)
                                .resizable()
                                .frame(width: 18, height: 18)
                        }
                        Text(browserName)
                            .font(.system(size: 12, weight: .semibold))
                    }

                    if browserName == "Safari" && !viewModel.isFullDiskAccessGranted {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 4) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.orange)
                                Text("Full Disk Access Required")
                                    .font(.system(size: 11, weight: .bold))
                            }
                            Text("Grant Full Disk Access to BookmarkSync in System Settings to load Safari profiles.")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                                .lineLimit(nil)

                            Button("Open System Settings") {
                                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                            .font(.system(size: 10))
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                        .padding(8)
                        .background(Color.orange.opacity(0.1))
                        .cornerRadius(6)
                        .padding(.leading, 8)
                    } else if browserConfigs.isEmpty {
                        Text("No profiles found. Click Rescan.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .padding(.leading, 8)
                    } else {
                        ForEach(Array(browserConfigs.enumerated()), id: \.element.id) { index, config in
                            let isLast = index == browserConfigs.count - 1
                            let treeIcon = isLast ? "└─" : "├─"

                            HStack(alignment: .center) {
                                Text(treeIcon)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundColor(.secondary)

                                if config.profileSetId != nil && config.profileSetId != viewModel.selectedProfileSetId {
                                    let otherSetName = viewModel.profileSets.first(where: { $0.id == config.profileSetId })?.name ?? "Other Set"
                                    Text(config.profileName)
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                    Spacer()
                                    ProfileSetIcon(name: otherSetName, isActive: false)
                                        .help("Syncing in \(otherSetName)")
                                } else {
                                    Toggle(config.profileName, isOn: Binding(
                                        get: { config.isEnabled && config.profileSetId == viewModel.selectedProfileSetId },
                                        set: { newValue in
                                            if newValue {
                                                config.profileSetId = viewModel.selectedProfileSetId
                                                config.isEnabled = true
                                                config.lastSyncTime = nil
                                                config.observedStateData = nil
                                                viewModel.lastSyncTimes[config.id] = nil
                                                viewModel.latestBrowserNodes[config.id] = nil
                                            } else {
                                                config.profileSetId = nil
                                                config.isEnabled = false
                                                config.lastSyncTime = nil
                                                config.observedStateData = nil
                                                viewModel.latestBrowserNodes[config.id] = nil
                                                WriteQueue.shared.removePendingWrites(for: config.bookmarkFilePath)
                                                viewModel.removeDiffs(for: config.bundleId, profileName: config.profileName)

                                                viewModel.cleanOrphanedNodes(for: viewModel.selectedProfileSetId ?? "")
                                            }
                                            try? modelContext.save()
                                            viewModel.syncEngine?.triggerSync(changedPaths: [], forceImmediate: true)
                                        }
                                    ))
                                    .font(.system(size: 11))

                                    let pendingDiffs = viewModel.diffHistory.filter { diff in
                                        diff.isWaiting &&
                                        diff.targetBundleIds.contains(config.bundleId) &&
                                        diff.targetProfileNames.contains(config.profileName)
                                    }
                                    let adds = pendingDiffs.filter { $0.bookmarkTitle.hasPrefix("Add:") }.count
                                    let dels = pendingDiffs.filter { $0.bookmarkTitle.hasPrefix("Delete:") }.count
                                    let updates = pendingDiffs.filter { $0.bookmarkTitle.hasPrefix("Update:") }.count

                                    if adds > 0 || dels > 0 || updates > 0 {
                                        HStack(spacing: 3) {
                                            if adds > 0 {
                                                Text("+\(adds)")
                                                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                                                    .foregroundColor(.green)
                                            }
                                            if updates > 0 {
                                                Text("~\(updates)")
                                                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                                                    .foregroundColor(.yellow)
                                            }
                                            if dels > 0 {
                                                Text("-\(dels)")
                                                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                                                    .foregroundColor(.red)
                                            }
                                        }
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 1)
                                        .background(Color.gray.opacity(0.1))
                                        .cornerRadius(4)
                                        .padding(.leading, 4)
                                    }

                                    Spacer()

                                    if let lastSync = config.lastSyncTime, Date().timeIntervalSince(lastSync) < 300 {
                                        Circle()
                                            .fill(Color.green)
                                            .frame(width: 6, height: 6)
                                    }
                                }
                            }
                            .padding(.leading, 8)
                        }
                    }
                }
                .padding(.bottom, 4)
            }

            Divider()

            // Queue / History Header
            TrayMenuActivityView(viewModel: viewModel, configs: configs)

            Divider()

            // Last Row: Bookmarks, Backups (on the left) + Quit (on the right)
            HStack {
                HStack(spacing: 8) {
                    Button("Bookmarks") {
                        let isAltHeld = NSEvent.modifierFlags.contains(.option)
                        handleWindow(id: "bookmarks", title: "Unified Bookmarks", forceNew: isAltHeld)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button("Backups") {
                        let isAltHeld = NSEvent.modifierFlags.contains(.option)
                        handleWindow(id: "backups", title: "Backups Manager", forceNew: isAltHeld)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    
                    Button(action: {
                        handleWindow(id: "onboarding", title: "Welcome to BookmarkSync", forceNew: false)
                    }) {
                        Image(systemName: "questionmark.circle")
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                    .help("Open Onboarding & Help")
                }

                Spacer()

                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding()
        .frame(width: 280)
        .onAppear {
            if !hasSeenOnboarding {
                handleWindow(id: "onboarding", title: "Welcome to BookmarkSync", forceNew: false)
                hasSeenOnboarding = true
            }
            viewModel.modelContext = modelContext
            viewModel.loadProfileSets()
            viewModel.rescanProfiles()
        }
    }

    private func handleWindow(id: String, title: String, forceNew: Bool) {
        if forceNew {
            openWindow(id: id)
        } else {
            let tracked: NSWindow?
            if title == "Unified Bookmarks" {
                tracked = DockManager.shared.lastActiveBookmarksWindow
            } else if title == "Backups Manager" {
                tracked = DockManager.shared.lastActiveBackupsWindow
            } else {
                tracked = nil
            }
            
            let existing = NSApp.windows.filter { $0.title == title }
            
            // Fallback hierarchy: 
            // 1. Tracked window on current space
            // 2. Any window on current space
            // 3. Tracked window anywhere
            // 4. Any window anywhere
            let target = (tracked?.isOnActiveSpace == true ? tracked : nil)
                ?? existing.first(where: { $0.isOnActiveSpace })
                ?? tracked
                ?? existing.first
            
            if let window = target {
                window.makeKeyAndOrderFront(nil)
            } else {
                openWindow(id: id)
            }
        }

        NSApp.activate(ignoringOtherApps: true)
    }
}
