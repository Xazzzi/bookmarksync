import SwiftUI
import SwiftData

struct TrayMenu: View {
    @ObservedObject var viewModel: AppViewModel
    @Query var configs: [BrowserConfig]
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header Row: App Name + Status + Sync Controls
            HStack(alignment: .center) {
                Text("BookmarkSync")
                    .font(.system(size: 14, weight: .bold))

                Text("(\(viewModel.syncStatus))")
                    .font(.system(size: 11))
                    .foregroundColor(viewModel.syncStatus == "Idle" ? .secondary : .green)

                Spacer()

                HStack(spacing: 12) {
                    // Stop Button
                    Button(action: {
                        viewModel.syncState = .stopped
                    }) {
                        Image(systemName: "stop.fill")
                            .foregroundColor(viewModel.syncState == .stopped ? .red : .secondary)
                            .font(.system(size: 13))
                    }
                    .buttonStyle(.plain)

                    // Play-Pause Button
                    Button(action: {
                        switch viewModel.syncState {
                        case .stopped:
                            viewModel.syncState = .readOnly
                        case .readOnly:
                            viewModel.syncState = .active
                        case .active:
                            viewModel.syncState = .readOnly
                        }
                    }) {
                        Image(systemName: viewModel.syncState == .active ? "pause.fill" : "play.fill")
                            .foregroundColor(
                                viewModel.syncState == .active ? .green :
                                (viewModel.syncState == .readOnly ? .orange : .secondary)
                            )
                            .font(.system(size: 13))
                    }
                    .buttonStyle(.plain)
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
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                    }
                    .buttonStyle(.plain)
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
                                                viewModel.lastSyncTimes[config.id] = nil
                                                viewModel.latestBrowserNodes[config.id] = nil
                                            } else {
                                                config.profileSetId = nil
                                                config.isEnabled = false
                                                config.lastSyncTime = nil
                                                viewModel.latestBrowserNodes[config.id] = nil
                                                WriteQueue.shared.removePendingWrites(for: config.bookmarkFilePath)
                                                viewModel.removeDiffs(for: config.bundleId)
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
            HStack {
                Text("Activity")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.secondary)
                
                Spacer()
                
                Button(action: {
                    viewModel.isActivityFilterGlobal.toggle()
                }) {
                    HStack(spacing: 3) {
                        Image(systemName: viewModel.isActivityFilterGlobal ? "globe" : "person.crop.circle")
                        Text(viewModel.isActivityFilterGlobal ? "Global" : "Profile")
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(4)
                }
                .buttonStyle(.plain)
                .help("Toggle Global/Profile Set Activity Filter")
                
                Button(action: {
                    viewModel.clearHistory()
                }) {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear Activity")
            }

            let filteredDiffs = viewModel.diffHistory.filter { diff in
                viewModel.isActivityFilterGlobal ? true : diff.profileSetId == viewModel.selectedProfileSetId
            }

            if filteredDiffs.isEmpty {
                let currentSetId = viewModel.selectedProfileSetId
                let hasActive = configs.contains(where: { $0.isEnabled && $0.profileSetId == currentSetId })
                Text(hasActive ? "In sync" : "Idle")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .padding(.leading, 8)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(filteredDiffs) { diff in
                            HStack(spacing: 4) {
                                if viewModel.isActivityFilterGlobal, let psId = diff.profileSetId {
                                    let setName = viewModel.profileSets.first(where: { $0.id == psId })?.name ?? "Set"
                                    ProfileSetIcon(name: setName, isActive: false)
                                        .padding(.trailing, 2)
                                }
                                
                                HStack(spacing: 2) {
                                    ForEach(Array(diff.sourceBundleIds.enumerated()), id: \.element) { index, bid in
                                        if let icon = BrowserDiscoverer.getIcon(for: bid) {
                                            let profileName = index < diff.sourceProfileNames.count ? diff.sourceProfileNames[index] : ""
                                            let browserName = bid == "com.apple.Safari" ? "Safari" : (bid == "com.google.Chrome" ? "Chrome" : (bid == "org.mozilla.firefox" ? "Firefox" : bid))
                                            let tooltip = profileName.isEmpty ? browserName : "\(browserName) (\(profileName))"
                                            Image(nsImage: icon)
                                                .resizable()
                                                .frame(width: 16, height: 16)
                                                .help(tooltip)
                                        }
                                    }
                                }

                                Text(diff.bookmarkTitle)
                                    .font(.system(size: 12))
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .frame(maxWidth: .infinity, alignment: .leading)

                                Image(systemName: "arrow.right")
                                    .font(.system(size: 8))
                                    .foregroundColor(.secondary)

                                HStack(spacing: 2) {
                                    ForEach(Array(diff.targetBundleIds.enumerated()), id: \.element) { index, bid in
                                        if let icon = BrowserDiscoverer.getIcon(for: bid) {
                                            let profileName = index < diff.targetProfileNames.count ? diff.targetProfileNames[index] : ""
                                            let browserName = bid == "com.apple.Safari" ? "Safari" : (bid == "com.google.Chrome" ? "Chrome" : (bid == "org.mozilla.firefox" ? "Firefox" : bid))
                                            let tooltip = profileName.isEmpty ? browserName : "\(browserName) (\(profileName))"
                                            Image(nsImage: icon)
                                                .resizable()
                                                .frame(width: 16, height: 16)
                                                .grayscale(diff.isWaiting ? 1.0 : 0.0)
                                                .help(tooltip)
                                        }
                                    }
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                    .padding(.trailing, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.trailing, -12)
                .frame(height: min(CGFloat(filteredDiffs.count) * 24, 150))
            }

            Divider()

            // Last Row: Bookmarks, Backups (on the left) + Quit (on the right)
            HStack {
                HStack(spacing: 8) {
                    Button("Bookmarks") {
                        let isAltHeld = NSEvent.modifierFlags.contains(.option)
                        if !isAltHeld, let window = NSApp.windows.first(where: { $0.title == "Unified Bookmarks" }) {
                            window.makeKeyAndOrderFront(nil)
                            NSApp.activate(ignoringOtherApps: true)
                        } else {
                            openWindow(id: "bookmarks")
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                NSApp.activate(ignoringOtherApps: true)
                                if let window = NSApp.windows.first(where: { $0.title == "Unified Bookmarks" }) {
                                    window.makeKeyAndOrderFront(nil)
                                }
                            }
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button("Backups") {
                        let isAltHeld = NSEvent.modifierFlags.contains(.option)
                        if !isAltHeld, let window = NSApp.windows.first(where: { $0.title == "Backups Manager" }) {
                            window.makeKeyAndOrderFront(nil)
                            NSApp.activate(ignoringOtherApps: true)
                        } else {
                            openWindow(id: "backups")
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                NSApp.activate(ignoringOtherApps: true)
                                if let window = NSApp.windows.first(where: { $0.title == "Backups Manager" }) {
                                    window.makeKeyAndOrderFront(nil)
                                }
                            }
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
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
            viewModel.modelContext = modelContext
            viewModel.loadProfileSets()
            viewModel.rescanProfiles()
        }
    }
}

