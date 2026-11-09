import SwiftUI

/// Asks the user to confirm or reject deletions that `DeletionGuard` held back.
struct DeletionHoldBanner: View {
    @ObservedObject var viewModel: AppViewModel
    let hold: PendingDeletionHold
    @State private var showsDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.octagon.fill")
                    .foregroundColor(.red)
                Text("Deletion Paused")
                    .font(.system(size: 11, weight: .bold))
            }

            Text(verbatim: message)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                showsDetails.toggle()
            } label: {
                Label {
                    Text(verbatim: L10n.text(showsDetails ? "Hide Details" : "Show Details"))
                } icon: {
                    Image(systemName: showsDetails ? "chevron.down" : "chevron.right")
                }
                .font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .foregroundColor(.accentColor)

            if showsDetails {
                BookmarkDiffList(diff: hold.diff, maxHeight: 200)
            }

            HStack(spacing: 6) {
                Button("Restore Bookmarks") {
                    viewModel.rejectDeletionHold(configId: hold.configId)
                }
                .help("Keep these bookmarks and write them back to this browser")

                Button("Apply Deletion") {
                    viewModel.approveDeletionHold(configId: hold.configId)
                }
                .help("Delete these bookmarks in every synced browser")
            }
            .font(.system(size: 10))
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.08))
        .cornerRadius(6)
    }

    private var message: String {
        let profile = "\(hold.browserName) (\(hold.profileName))"
        switch hold.reason {
        case .emptyRead:
            return L10n.format(
                "%@ returned no bookmarks, but had %ld last time. This may be a read error. Nothing has been deleted in other browsers yet.",
                profile, hold.previousCount
            )
        case .massDeletion:
            return L10n.format(
                "%@ lost %ld of its %ld bookmarks at once. This may be a read error or a deliberate deletion. Nothing has been deleted in other browsers yet.",
                profile, hold.deletedIds.count, hold.previousCount
            )
        }
    }
}
