import SwiftUI
import SwiftData
import AppKit

/// What the comparison panel is showing.
enum BackupDiffState: Equatable, Sendable {
    case idle
    case loading
    case ready(BookmarkDiff)
    case failed(String)
}

struct BackupsView: View {
    @ObservedObject var viewModel: AppViewModel
    @Query var configs: [BrowserConfig]
    @Environment(\.modelContext) private var modelContext

    @State private var selectedConfigId: String?
    @State private var backups: [BackupEntry] = []
    @State private var selectedBackup: BackupEntry?
    @State private var diffState: BackupDiffState = .idle
    @State private var alertMessage: String?
    @State private var showAlert = false

    private var selectedConfig: BrowserConfig? {
        configs.first { $0.id == selectedConfigId }
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("Backups Manager")
                .font(.title)
                .bold()
                .padding(.top, 16)
                .padding(.bottom, 8)

            Text("A backup is taken automatically right before BookmarkSync writes to a browser's bookmark file, and before every restore. Backups from the last 7 days are all kept, then one per day up to 30 days (200 at most); manual backups are never removed. Compare a backup with the current bookmarks before restoring it.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
                .padding(.bottom, 16)

            if configs.isEmpty {
                Spacer()
                Text("No browsers registered.")
                    .foregroundColor(.secondary)
                Spacer()
            } else {
                let sortedConfigs = configs.sorted(by: { $0.browserName < $1.browserName })

                if selectedConfigId != nil {
                    HStack {
                        Picker("Select Profile", selection: $selectedConfigId) {
                            ForEach(sortedConfigs) { config in
                                Text(verbatim: "\(config.browserName) - \(config.profileName)")
                                    .tag(config.id as String?)
                            }
                        }
                        .pickerStyle(.menu)
                        .onChange(of: selectedConfigId) {
                            loadBackups()
                        }

                        Button("Back Up Now") {
                            backUpNow()
                        }
                        .help("Copy this profile's bookmark file now. Manual backups are kept until you delete them.")
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                }

                Divider()

                if backups.isEmpty {
                    Spacer()
                    Text("No backups found for this profile.")
                        .foregroundColor(.secondary)
                    Spacer()
                } else {
                    // The list takes whatever height the comparison panel
                    // leaves, instead of a fixed 200 points.
                    List(backups) { item in
                        backupRow(item)
                    }
                    .frame(minHeight: 160, maxHeight: .infinity)

                    Divider()

                    comparisonPanel
                        .padding(16)
                        .layoutPriority(1)
                }
            }
        }
        .frame(width: 560, height: 640)
        .alert(isPresented: $showAlert) {
            Alert(title: Text("Status"), message: Text(verbatim: alertMessage ?? ""), dismissButton: .default(Text("OK")))
        }
        .onAppear {
            if selectedConfigId == nil {
                selectedConfigId = configs.sorted(by: { $0.browserName < $1.browserName }).first?.id
            }
            loadBackups()
        }
        .onChange(of: configs) {
            if selectedConfigId == nil {
                selectedConfigId = configs.sorted(by: { $0.browserName < $1.browserName }).first?.id
                loadBackups()
            }
        }
    }

    private func backupRow(_ item: BackupEntry) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(verbatim: formattedDate(item.date))
                        .font(.body)
                        .bold()
                    kindBadge(item.kind)
                }
                Text(verbatim: item.name)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Button("Compare") {
                compare(item)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.vertical, 4)
        .background(selectedBackup == item ? Color.accentColor.opacity(0.12) : Color.clear)
    }

    private func kindBadge(_ kind: BackupEntry.Kind) -> some View {
        let label: String
        let color: Color
        switch kind {
        case .timestamped:
            label = L10n.text("Automatic")
            color = .green
        case .manual:
            label = L10n.text("Manual")
            color = .orange
        case .legacyRotating:
            label = L10n.text("Old rotating")
            color = .gray
        case .legacyDaily:
            label = L10n.text("Old daily")
            color = .blue
        }
        return Text(verbatim: label)
            .font(.caption2)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(color.opacity(0.2))
            .foregroundColor(color)
            .cornerRadius(4)
    }

    @ViewBuilder
    private var comparisonPanel: some View {
        if let backup = selectedBackup {
            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: L10n.format("Restoring the backup from %@ would make these changes to the current bookmarks:", formattedDate(backup.date)))
                    .font(.system(size: 12, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)

                switch diffState {
                case .idle, .loading:
                    ProgressView()
                        .controlSize(.small)
                case .failed(let message):
                    Text(verbatim: L10n.format("Could not compare: %@", message))
                        .font(.caption)
                        .foregroundColor(.red)
                case .ready(let diff):
                    BookmarkDiffList(diff: diff, maxHeight: 240)

                    HStack {
                        Spacer()
                        Button("Restore This Backup") {
                            restoreSelected()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(diff.isEmpty)
                    }
                }
            }
        } else {
            Text("Select a backup and click Compare to see what restoring it would change.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }

    private func loadBackups() {
        selectedBackup = nil
        diffState = .idle
        guard let config = selectedConfig else {
            backups = []
            return
        }
        backups = BackupStore.listBackups(for: URL(fileURLWithPath: config.bookmarkFilePath))
    }

    private func backUpNow() {
        guard let config = selectedConfig else { return }
        do {
            if try BackupStore.createBackup(of: URL(fileURLWithPath: config.bookmarkFilePath), manual: true) != nil {
                alertMessage = L10n.format("Backed up %@ - %@.", config.browserName, config.profileName)
            } else {
                alertMessage = L10n.text("There is no bookmark file to back up.")
            }
        } catch {
            alertMessage = L10n.format("Backup failed: %@", error.localizedDescription)
        }
        showAlert = true
        loadBackups()
    }

    /// Parses the live file and the backup off the main thread and diffs them.
    private func compare(_ backup: BackupEntry) {
        guard let config = selectedConfig else { return }
        selectedBackup = backup
        diffState = .loading

        let bundleId = config.bundleId
        let profileName = config.profileName
        let liveURL = URL(fileURLWithPath: config.bookmarkFilePath)

        Task {
            let state = await Task.detached { () -> BackupDiffState in
                do {
                    let current = try makeBookmarkParser(bundleId: bundleId, profileName: profileName, fileURL: liveURL).read()
                    let restored = try makeBookmarkParser(bundleId: bundleId, profileName: profileName, fileURL: backup.url).read()
                    return .ready(BookmarkDiff(old: current, new: restored))
                } catch {
                    return .failed(error.localizedDescription)
                }
            }.value
            // Ignore a result for a backup the user has since moved away from.
            if selectedBackup == backup {
                diffState = state
            }
        }
    }

    private func restoreSelected() {
        guard let backup = selectedBackup, let config = selectedConfig else { return }

        // A running browser keeps its bookmarks in memory and writes them back
        // over the restored file, which then looks like a mass deletion followed
        // by a mass re-addition.
        let isRunning = NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == config.bundleId && !$0.isTerminated
        }
        if isRunning {
            alertMessage = L10n.format("Quit %@ (⌘Q) before restoring. While it is running it keeps its bookmarks in memory and would overwrite the restored file.", config.browserName)
            showAlert = true
            return
        }

        do {
            try BackupStore.restore(backup, over: URL(fileURLWithPath: config.bookmarkFilePath))
            alertMessage = L10n.format("Restored the backup from %@. Bookmarks it lacks will also be removed from your other browsers; a large removal is held in the menu bar for your confirmation first.", formattedDate(backup.date))
            showAlert = true
            loadBackups()

            // Use the app's engine: a second engine would run its own syncs
            // concurrently with the first. The path is passed explicitly because
            // the restored file keeps the backup's (older) modification date.
            viewModel.syncEngine?.triggerSync(changedPaths: [config.bookmarkFilePath], forceImmediate: true)
        } catch {
            alertMessage = L10n.format("Restore failed: %@", error.localizedDescription)
            showAlert = true
        }
    }
}

#Preview {
    do {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: BrowserConfig.self, BookmarkNode.self, ProfileSet.self, configurations: config)
        return BackupsView(viewModel: AppViewModel())
            .modelContainer(container)
    } catch {
        return Text(verbatim: L10n.format("Failed to create container: %@", error.localizedDescription))
    }
}
