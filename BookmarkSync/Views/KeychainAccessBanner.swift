import SwiftUI

/// Explains why BookmarkSync needs a Chromium browser's Keychain key before macOS asks for it.
/// Shown under the browser in the menu bar while its encrypted bookmarks cannot be read.
struct KeychainAccessBanner: View {
    @ObservedObject var viewModel: AppViewModel
    let bundleId: String
    let browserName: String
    let issue: ChromiumKeyIssue

    private var service: String { ChromiumSafeStorage.services[bundleId] ?? bundleId }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: issue == .needsConsent ? "key.fill" : "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                Text(verbatim: L10n.text(issue == .needsConsent ? "Keychain Access Needed" : "Keychain Access Denied"))
                    .font(.system(size: 11, weight: .bold))
            }

            switch issue {
            case .needsConsent:
                paragraph(L10n.format("%1$@ encrypts its bookmarks file. To sync it, BookmarkSync needs %1$@'s encryption key from your Keychain.", browserName))
                paragraph(L10n.format("macOS will then ask twice: to allow access to “%@”, and for your login keychain password. Choose Always Allow both times so it does not ask again.", service))
                paragraph(L10n.format("The same key also protects %@'s saved passwords and cookies. BookmarkSync uses it only for the bookmarks file, and the key never leaves this Mac.", browserName))
                paragraph(L10n.text("Until then, these profiles are not synced and nothing in them is changed."))
                Button("Allow Keychain Access") {
                    viewModel.allowKeychainAccess(bundleId: bundleId)
                }
                .font(.system(size: 10))
                .buttonStyle(.bordered)
                .controlSize(.small)
            case .failed(let reason):
                paragraph(L10n.format("BookmarkSync could not get %@'s encryption key, so these profiles are not synced. Nothing in them is changed.", browserName))
                    .help(reason)
                Button("Try Again") {
                    viewModel.allowKeychainAccess(bundleId: bundleId)
                }
                .font(.system(size: 10))
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(8)
        .background(Color.orange.opacity(0.1))
        .cornerRadius(6)
        .padding(.leading, 8)
    }

    private func paragraph(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.system(size: 10))
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
