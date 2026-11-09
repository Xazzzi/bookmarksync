import XCTest
import SwiftData
@testable import BookmarkSync

final class ProfileDiscoveryTests: XCTestCase {
    @MainActor
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([BrowserConfig.self, BookmarkNode.self, ProfileSet.self])
        return try ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    @MainActor
    func testIncompleteDiscoveryPreservesEnabledProfilesAndBookmarks() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let config = BrowserConfig(id: "com.apple.Safari:Default", bundleId: "com.apple.Safari", browserName: "Safari", profileName: "Default", bookmarkFilePath: "/Safari/Bookmarks.plist", profileSetId: "set")
        let observed = Data("saved observation".utf8)
        config.observedStateData = observed
        config.lastSyncTime = Date(timeIntervalSince1970: 123)
        context.insert(config)
        context.insert(BookmarkNode(id: "set:example", title: "Example", url: "https://example.com", type: .leaf, mtime: Date(), profileSetId: "set"))
        try context.save()
        let model = AppViewModel()
        model.modelContext = context

        model.reconcileProfiles([])

        XCTAssertEqual(try context.fetchCount(FetchDescriptor<BrowserConfig>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<BookmarkNode>()), 1)
        XCTAssertTrue(config.isEnabled)
        XCTAssertEqual(config.profileSetId, "set")
        XCTAssertEqual(config.observedStateData, observed)
        XCTAssertEqual(config.lastSyncTime, Date(timeIntervalSince1970: 123))
        XCTAssertTrue(model.unavailableProfileIds.contains(config.id))

        model.reconcileProfiles([DiscoveredProfile(bundleId: config.bundleId, browserName: config.browserName, profileName: config.profileName, bookmarkFilePath: config.bookmarkFilePath, appPath: "/Safari.app")])
        XCTAssertTrue(model.unavailableProfileIds.isEmpty)
        XCTAssertTrue(config.isEnabled)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<BookmarkNode>()), 1)
    }

    @MainActor
    func testDisplayNameFallbackKeepsSameProfileAndSyncState() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let config = BrowserConfig(id: "com.google.Chrome:Personal", bundleId: "com.google.Chrome", browserName: "Google Chrome", profileName: "Personal", bookmarkFilePath: "/Chrome/Default/Bookmarks", profileSetId: "set", observedStateData: Data([1, 2, 3]))
        context.insert(config)
        try context.save()
        let model = AppViewModel()
        model.modelContext = context

        for name in ["Default", "Personal"] {
            model.reconcileProfiles([DiscoveredProfile(bundleId: config.bundleId, browserName: config.browserName, profileName: name, bookmarkFilePath: config.bookmarkFilePath, appPath: "/Chrome.app")])
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<BrowserConfig>()), 1)
            XCTAssertEqual(config.id, "com.google.Chrome:Personal")
            XCTAssertEqual(config.profileName, name)
            XCTAssertTrue(config.isEnabled)
            XCTAssertEqual(config.profileSetId, "set")
            XCTAssertEqual(config.observedStateData, Data([1, 2, 3]))
        }
    }

    @MainActor
    func testSafariProfilesSharingOneFileStaySeparateAndNewProfilesStayDisabled() throws {
        let container = try makeContainer()
        let model = AppViewModel()
        model.modelContext = container.mainContext
        let profiles = ["Default", "Work"].map {
            DiscoveredProfile(bundleId: "com.apple.Safari", browserName: "Safari", profileName: $0, bookmarkFilePath: "/Safari/Bookmarks.plist", appPath: "/Safari.app")
        }
        model.reconcileProfiles(profiles)
        model.reconcileProfiles(profiles)
        let configs = try container.mainContext.fetch(FetchDescriptor<BrowserConfig>())
        XCTAssertEqual(configs.count, 2)
        XCTAssertTrue(configs.allSatisfy { !$0.isEnabled })
    }
}
