import SwiftUI

/// Shown at the top of the tray when the website announces a newer version.
struct UpdateBanner: View {
    @ObservedObject var checker: UpdateChecker
    let release: UpdateChecker.Release

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 6) {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundColor(.accentColor)
                Text(verbatim: L10n.format("BookmarkSync %@ is available.", release.version))
                    .font(.system(size: 11, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Download") {
                    checker.openDownloadPage()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                Button {
                    checker.dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .help("Dismiss")
            }
            // Website text, shown verbatim: never interpreted as Markdown.
            ForEach(Array(release.notes.enumerated()), id: \.offset) { _, note in
                Text(verbatim: "• " + note)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.08))
        .cornerRadius(6)
    }
}

/// The opt-in switch and manual trigger for update checks.
struct UpdateCheckRow: View {
    @ObservedObject var checker: UpdateChecker

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Toggle("Check for updates weekly", isOn: $checker.isEnabled)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))
                    .help("Once a week, BookmarkSync asks bookmarksync.xazi.app for the latest version number. Only the app's own version is sent.")
                Spacer()
                if checker.status == .checking {
                    ProgressView()
                        .controlSize(.small)
                }
                Button("Check Now") {
                    checker.checkNow()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(checker.status == .checking)
            }
            switch checker.status {
            case .upToDate:
                Text("BookmarkSync is up to date.")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            case .failed(let message):
                Text(verbatim: L10n.format("Could not check for updates: %@", message))
                    .font(.system(size: 10))
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            case .idle, .checking:
                EmptyView()
            }
        }
    }
}
