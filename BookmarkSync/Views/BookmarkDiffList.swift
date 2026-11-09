import SwiftUI

/// A git-diff style list: `+` added, `−` removed, `~` changed, one row per item.
struct BookmarkDiffList: View {
    let diff: BookmarkDiff
    var maxHeight: CGFloat = 220

    /// Rows are about this tall; the scroll view gets an explicit height
    /// because one inside a popover collapses to zero otherwise.
    private let rowHeight: CGFloat = 46

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: L10n.format(
                "%ld added, %ld removed, %ld changed",
                diff.added.count, diff.removed.count, diff.changed.count
            ))
            .font(.caption)
            .foregroundColor(.secondary)

            if diff.isEmpty {
                Text("No differences")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(diff.entries) { entry in
                            BookmarkDiffRow(entry: entry)
                        }
                    }
                }
                .frame(height: min(CGFloat(diff.entries.count) * rowHeight, maxHeight))
            }
        }
    }
}

struct BookmarkDiffRow: View {
    let entry: BookmarkDiff.Entry

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Text(verbatim: symbol)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundColor(color)
                .frame(width: 12)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Image(systemName: entry.type == .folder ? "folder" : "bookmark")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                    Text(verbatim: entry.title)
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                if case .changed(let oldTitle, let oldURL) = entry.change {
                    if oldTitle != entry.title {
                        Text(verbatim: L10n.format("Was: %@", oldTitle))
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    if oldURL != entry.url, let oldURL {
                        Text(verbatim: L10n.format("Was: %@", oldURL))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                if let url = entry.url {
                    Text(verbatim: url)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Text(verbatim: pathText)
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(color.opacity(0.07))
        .cornerRadius(3)
    }

    private var symbol: String {
        switch entry.change {
        case .added: return "+"
        case .removed: return "−"
        case .changed: return "~"
        }
    }

    private var color: Color {
        switch entry.change {
        case .added: return .green
        case .removed: return .red
        case .changed: return .orange
        }
    }

    private var pathText: String {
        guard let root = entry.path.first else { return "" }
        let rootLabel: String
        switch root {
        case "bookmark_bar": rootLabel = L10n.text("Bookmarks Bar")
        case "other": rootLabel = L10n.text("Other Bookmarks")
        case "synced": rootLabel = L10n.text("Mobile Bookmarks")
        default: rootLabel = root
        }
        return ([rootLabel] + entry.path.dropFirst()).joined(separator: " / ")
    }
}
