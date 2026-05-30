import SwiftUI
import SwiftData

struct BookmarkTreeDetailView: View {
    let node: BookmarkNode
    let configs: [BrowserConfig]
    @ObservedObject var viewModel: AppViewModel
    let revealInTree: (BookmarkNode) -> Void
    let getBreadcrumbsList: (BookmarkNode) -> [BookmarkNode]
    
    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    // Large stylized header
                    HStack(spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(node.type == .folder ? (node.title == "Deleted by BookmarkSync" ? Color.red.opacity(0.15) : Color.orange.opacity(0.15)) : Color.blue.opacity(0.15))
                                .frame(width: 48, height: 48)
                            Image(systemName: node.type == .folder ? (node.title == "Deleted by BookmarkSync" ? "trash.fill" : "folder.fill") : "bookmark.fill")
                                .font(.system(size: 22))
                                .foregroundColor(node.type == .folder ? (node.title == "Deleted by BookmarkSync" ? .red : .orange) : .blue)
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
                        let breadcrumbs = getBreadcrumbsList(node)
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
}
