import SwiftUI

struct OnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var currentPage = 0

    let slides = [
        (
            systemImage: "folder.badge.person.crop",
            title: "Unified Syncing",
            description: "BookmarkSync acts as a hub that keeps your bookmarks in sync across all connected browser profiles."
        ),
        (
            systemImage: "list.bullet.indent",
            title: "Preserved Organization",
            description: "Your hierarchy is strictly maintained. The sync engine intelligently normalizes folder structures."
        ),
        (
            systemImage: "bookmark.square",
            title: "Unified Viewer",
            description: "Use the Unified Bookmarks window to explore your unified bookmarkes hierarchy for all connected browser profiles."
        ),
        (
            systemImage: "arrow.triangle.2.circlepath",
            title: "Live Activity Queue",
            description: "View synchronization diffs straight from the menu bar. We queue updates to your bookmarks until you close the browser app."
        ),
        (
            systemImage: "trash",
            title: "Safe Deletion Folder",
            description: "Items you delete in other browsers are moved into the 'Deleted by BookmarkSync' folder to prevent cloud resurrection loops."
        ),
        
        (
            systemImage: "clock.arrow.circlepath",
            title: "Automated Backups",
            description: "We auto backup your bookmarks before any changes. You can explore and restore your previous states via the Backups Manager."
        )
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Slide Content
            ZStack {
                ForEach(0..<slides.count, id: \.self) { index in
                    if index == currentPage {
                        OnboardingSlide(
                            systemImage: slides[index].systemImage,
                            title: slides[index].title,
                            description: slides[index].description
                        )
                        .transition(.opacity)
                    }
                }
            }
            .animation(.easeInOut, value: currentPage)
            .padding(.bottom, 10)

            // Custom Page Indicators
            HStack(spacing: 8) {
                ForEach(0..<slides.count, id: \.self) { index in
                    Circle()
                        .fill(currentPage == index ? Color.blue : Color.secondary.opacity(0.3))
                        .frame(width: 8, height: 8)
                        .onTapGesture {
                            withAnimation {
                                currentPage = index
                            }
                        }
                }
            }
            .padding(.bottom, 20)

            HStack {
                if currentPage > 0 {
                    Button("Back") {
                        withAnimation { currentPage -= 1 }
                    }
                    .controlSize(.large)
                }
                
                Spacer()
                
                if currentPage < slides.count - 1 {
                    Button("Next") {
                        withAnimation { currentPage += 1 }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                } else {
                    Button("Get Started") {
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }
            .padding(.horizontal, 30)
            .padding(.bottom, 30)
        }
        .frame(width: 450, height: 450)
        .background(Color(NSColor.windowBackgroundColor))
    }
}

struct OnboardingSlide: View {
    let systemImage: String
    let title: String
    let description: String

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            
            Image(systemName: systemImage)
                .resizable()
                .scaledToFit()
                .frame(width: 80, height: 80)
                .foregroundColor(.blue)
                .padding()
                .background(Color.blue.opacity(0.1))
                .clipShape(Circle())

            Text(title)
                .font(.system(size: 24, weight: .bold))
                .multilineTextAlignment(.center)

            Text(description)
                .font(.system(size: 14))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
                .lineSpacing(4)
            
            Spacer()
        }
    }
}
