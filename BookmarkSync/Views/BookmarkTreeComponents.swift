import SwiftUI
import SwiftData

private let deletedFolderTitle = "Deleted by BookmarkSync"

/// A single row of the flattened tree.
///
/// Takes plain values rather than `Binding<Set<String>>` / `Binding<String?>`:
/// bindings to shared collections force every row in the tree to re-render when
/// selection or expansion changes. With value inputs plus `Equatable`, only the
/// rows whose own state actually changed are rebuilt.
struct BookmarkTreeRow: View, Equatable {
    let row: BookmarkFlatRow
    let isSelected: Bool
    let isExpanded: Bool
    let onSelect: (String) -> Void
    let onToggleExpand: (String) -> Void
    let onOpenURL: (String) -> Void

    @State private var isHovered = false

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.row == rhs.row
            && lhs.isSelected == rhs.isSelected
            && lhs.isExpanded == rhs.isExpanded
    }

    private var isFolder: Bool { row.item.type == .folder }
    private var isTrashFolder: Bool { row.item.title == deletedFolderTitle }

    var body: some View {
        HStack(spacing: 6) {
            // Indentation for this row's depth. Drawn as a spacer rather than
            // nested VStacks so the list can stay flat and lazy.
            if row.depth > 0 {
                Spacer()
                    .frame(width: CGFloat(row.depth) * 14)
            }

            if isFolder {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.secondary)
                    .rotationEffect(isExpanded ? .degrees(90) : .degrees(0))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        onToggleExpand(row.item.id)
                    }

                Image(systemName: isTrashFolder ? "trash.fill" : "folder.fill")
                    .font(.system(size: 13))
                    .foregroundColor(isSelected ? .white.opacity(0.9) : (isTrashFolder ? .red : .blue))
            } else {
                Image(systemName: "link")
                    .font(.system(size: 12))
                    .foregroundColor(isSelected ? .white.opacity(0.8) : .secondary)
                    .padding(.leading, 4)
            }

            Text(row.item.title)
                .font(.system(size: 13))
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, isFolder ? 6 : 10)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .background(
            isSelected ? Color.accentColor :
                (isHovered ? Color.gray.opacity(0.15) : Color.clear)
        )
        .foregroundColor(isSelected ? .white : .primary)
        .cornerRadius(4)
        .onTapGesture {
            onSelect(row.item.id)
        }
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            if isFolder {
                onToggleExpand(row.item.id)
            } else if let urlString = row.item.url {
                onOpenURL(urlString)
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
