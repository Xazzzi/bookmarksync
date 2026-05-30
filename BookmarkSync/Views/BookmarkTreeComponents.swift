import SwiftUI
import SwiftData

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
                
                Image(systemName: element.title == "Deleted by BookmarkSync" ? "trash.fill" : "folder.fill")
                    .font(.system(size: 13))
                    .foregroundColor(selectedId == element.id ? .white.opacity(0.9) : (element.title == "Deleted by BookmarkSync" ? .red : .blue))
                
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
