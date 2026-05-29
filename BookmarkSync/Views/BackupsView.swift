import SwiftUI
import SwiftData

struct BackupItem: Identifiable {
    let id = UUID()
    let fileURL: URL
    let name: String
    let dateModified: Date
    let isDaily: Bool
}

struct BackupsView: View {
    @ObservedObject var viewModel: AppViewModel
    @Query var configs: [BrowserConfig]
    @Environment(\.modelContext) private var modelContext
    
    @State private var selectedConfigId: String?
    @State private var backups: [BackupItem] = []
    @State private var alertMessage: String?
    @State private var showAlert = false
    
    var body: some View {
        VStack(spacing: 0) {
            Text("Backups Manager")
                .font(.title)
                .bold()
                .padding(.top, 16)
                .padding(.bottom, 8)
            
            Text("Safely restore bookmarks from rotating and daily backups.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .padding(.bottom, 16)
            
            if configs.isEmpty {
                Spacer()
                Text("No browsers registered.")
                    .foregroundColor(.secondary)
                Spacer()
            } else {
                let sortedConfigs = configs.sorted(by: { $0.browserName < $1.browserName })
                
                if selectedConfigId != nil {
                    Picker("Select Profile", selection: $selectedConfigId) {
                        ForEach(sortedConfigs) { config in
                            Text("\(config.browserName) - \(config.profileName)")
                                .tag(config.id as String?)
                        }
                    }
                    .pickerStyle(.menu)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                    .onChange(of: selectedConfigId) {
                        loadBackups()
                    }
                }
                
                Divider()
                
                if backups.isEmpty {
                    Spacer()
                    Text("No backups found for this profile.")
                        .foregroundColor(.secondary)
                    Spacer()
                } else {
                    List {
                        ForEach(backups) { item in
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(item.name)
                                            .font(.body)
                                            .bold()
                                        if item.isDaily {
                                            Text("Daily")
                                                .font(.caption2)
                                                .padding(.horizontal, 4)
                                                .padding(.vertical, 2)
                                                .background(Color.blue.opacity(0.2))
                                                .foregroundColor(.blue)
                                                .cornerRadius(4)
                                        } else {
                                            Text("Rotating")
                                                .font(.caption2)
                                                .padding(.horizontal, 4)
                                                .padding(.vertical, 2)
                                                .background(Color.green.opacity(0.2))
                                                .foregroundColor(.green)
                                                .cornerRadius(4)
                                        }
                                    }
                                    Text("Modified: \(formattedDate(item.dateModified))")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                
                                Spacer()
                                
                                Button("Restore") {
                                    restoreBackup(item)
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
        }
        .frame(width: 450, height: 400)
        .alert(isPresented: $showAlert) {
            Alert(title: Text("Status"), message: Text(alertMessage ?? ""), dismissButton: .default(Text("OK")))
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
    
    private func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }
    
    private func loadBackups() {
        backups = []
        guard let configId = selectedConfigId,
              let config = configs.first(where: { $0.id == configId }) else { return }
        
        let fileURL = URL(fileURLWithPath: config.bookmarkFilePath)
        let baseDir = fileURL.deletingLastPathComponent()
        let filename = fileURL.lastPathComponent
        
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: baseDir, includingPropertiesForKeys: [.contentModificationDateKey], options: []) else { return }
        
        var items: [BackupItem] = []
        for url in contents {
            let name = url.lastPathComponent
            if name.hasPrefix("\(filename).backup.") {
                let attrs = try? fm.attributesOfItem(atPath: url.path)
                let modDate = attrs?[.modificationDate] as? Date ?? Date()
                let isDaily = name.contains(".daily.")
                
                items.append(BackupItem(
                    fileURL: url,
                    name: name,
                    dateModified: modDate,
                    isDaily: isDaily
                ))
            }
        }
        
        backups = items.sorted(by: { $0.dateModified > $1.dateModified })
    }
    
    private func restoreBackup(_ item: BackupItem) {
        guard let configId = selectedConfigId,
              let config = configs.first(where: { $0.id == configId }) else { return }
        
        let liveURL = URL(fileURLWithPath: config.bookmarkFilePath)
        
        // 1. Create a dummy parser to leverage performBackup() on the current live file
        var parser: BrowserParser?
        if config.bundleId == "com.apple.Safari" {
            parser = SafariParser(filePath: liveURL, profileName: config.profileName)
        } else if config.bundleId == "org.mozilla.firefox" {
            parser = FirefoxParser(filePath: liveURL)
        } else {
            parser = ChromeParser(filePath: liveURL)
        }
        
        do {
            // First back up current state so we don't lose it
            if let parser = parser {
                try parser.performBackup()
            }
            
            // Overwrite live with backup
            let fm = FileManager.default
            try fm.removeItem(at: liveURL)
            try fm.copyItem(at: item.fileURL, to: liveURL)
            
            alertMessage = "Successfully restored \(item.name) over live bookmarks."
            showAlert = true
            
            // Reload backups list
            loadBackups()
            
            // Trigger a manual sync to pull in the restored bookmarks immediately!
            if let engine = SyncEngine(modelContext: modelContext, viewModel: viewModel) as SyncEngine? {
                engine.triggerSync(changedPaths: [])
            }
        } catch {
            alertMessage = "Restore failed: \(error.localizedDescription)"
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
        return Text("Failed to create container: \(error.localizedDescription)")
    }
}
