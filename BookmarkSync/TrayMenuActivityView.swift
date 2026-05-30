import SwiftUI

struct TrayMenuActivityView: View {
    @ObservedObject var viewModel: AppViewModel
    let configs: [BrowserConfig]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Activity")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.secondary)

                Spacer()

                Button(action: {
                    viewModel.isActivityFilterGlobal.toggle()
                }) {
                    HStack(spacing: 3) {
                        Image(systemName: viewModel.isActivityFilterGlobal ? "globe" : "person.crop.circle")
                            .font(.system(size: 14))
                        Text(viewModel.isActivityFilterGlobal ? "Global" : "Profile")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(4)
                }
                .buttonStyle(.plain)
                .help("Toggle Global/Profile Set Activity Filter")

                Button(action: {
                    viewModel.clearHistory()
                }) {
                    Image(systemName: "trash")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Clear Activity")
            }
            .padding(.vertical, 4)

            let filteredDiffs = viewModel.diffHistory.filter { diff in
                viewModel.isActivityFilterGlobal ? true : diff.profileSetId == viewModel.selectedProfileSetId
            }

            if let errorStr = viewModel.queueError {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                        .font(.system(size: 11))
                    Text(errorStr)
                        .font(.system(size: 11))
                        .foregroundColor(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(6)
                .background(Color.red.opacity(0.1))
                .cornerRadius(4)
                .padding(.vertical, 4)
            }

            if filteredDiffs.isEmpty {
                let currentSetId = viewModel.selectedProfileSetId
                let hasActive = configs.contains(where: { $0.isEnabled && $0.profileSetId == currentSetId })
                Text(hasActive ? "In sync" : "Idle")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .padding(.leading, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(filteredDiffs) { diff in
                            HStack(spacing: 4) {
                                if viewModel.isActivityFilterGlobal, let psId = diff.profileSetId {
                                    let setName = viewModel.profileSets.first(where: { $0.id == psId })?.name ?? "Set"
                                    ProfileSetIcon(name: setName, isActive: false)
                                        .padding(.trailing, 2)
                                }

                                HStack(spacing: 2) {
                                    ForEach(Array(diff.sourceBundleIds.enumerated()), id: \.element) { index, bid in
                                        if let icon = BrowserDiscoverer.getIcon(for: bid) {
                                            let profileName = index < diff.sourceProfileNames.count ? diff.sourceProfileNames[index] : ""
                                            let browserName = bid == "com.apple.Safari" ? "Safari" : (bid == "com.google.Chrome" ? "Chrome" : (bid == "org.mozilla.firefox" ? "Firefox" : bid))
                                            let tooltip = profileName.isEmpty ? browserName : "\(browserName) (\(profileName))"
                                            Image(nsImage: icon)
                                                .resizable()
                                                .frame(width: 16, height: 16)
                                                .help(tooltip)
                                        }
                                    }
                                }

                                Text(diff.bookmarkTitle)
                                    .font(.system(size: 12))
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .frame(maxWidth: .infinity, alignment: .leading)

                                Image(systemName: "arrow.right")
                                    .font(.system(size: 8))
                                    .foregroundColor(.secondary)

                                HStack(spacing: 2) {
                                    ForEach(Array(diff.targetBundleIds.enumerated()), id: \.element) { index, bid in
                                        if let icon = BrowserDiscoverer.getIcon(for: bid) {
                                            let profileName = index < diff.targetProfileNames.count ? diff.targetProfileNames[index] : ""
                                            let browserName = bid == "com.apple.Safari" ? "Safari" : (bid == "com.google.Chrome" ? "Chrome" : (bid == "org.mozilla.firefox" ? "Firefox" : bid))
                                            let tooltip = profileName.isEmpty ? browserName : "\(browserName) (\(profileName))"
                                            Image(nsImage: icon)
                                                .resizable()
                                                .frame(width: 16, height: 16)
                                                .grayscale(diff.isWaiting ? 1.0 : 0.0)
                                                .help(tooltip)
                                        }
                                    }
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                    .padding(.trailing, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.trailing, -12)
                .frame(height: min(CGFloat(filteredDiffs.count) * 24, 150))
            }
        }
    }
}
