import SwiftUI

/// Explains why changes have not reached a browser yet: writes wait until the
/// browser is fully quit, because a running browser keeps its bookmarks in
/// memory and would overwrite the file.
struct WriteWaitBanner: View {
    @ObservedObject var viewModel: AppViewModel
    let configs: [BrowserConfig]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(viewModel.browsersAwaitingQuit.sorted(), id: \.self) { bundleId in
                HStack(alignment: .top, spacing: 4) {
                    Image(systemName: "hourglass")
                        .foregroundColor(.blue)
                        .font(.system(size: 10))
                    Text(verbatim: message(for: bundleId))
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.blue.opacity(0.08))
        .cornerRadius(6)
    }

    private func message(for bundleId: String) -> String {
        let name = configs.first { $0.bundleId == bundleId }?.browserName ?? bundleId
        let pending = viewModel.diffHistory.filter { $0.isWaiting && $0.targetBundleIds.contains(bundleId) }.count
        // A queued write is not always itemised (e.g. a pure reorder), so a
        // count of zero must not read as "nothing to write".
        if pending == 0 {
            return L10n.format(
                "Quit %@ and its web apps (PWAs) completely (⌘Q) to write the pending changes; closing its windows is not enough.",
                name
            )
        }
        return L10n.format(
            "Quit %@ and its web apps (PWAs) completely (⌘Q) to write %ld pending change(s); closing its windows is not enough.",
            name, pending
        )
    }
}
