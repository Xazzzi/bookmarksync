import XCTest
@testable import BookmarkSync

final class LocalizationTests: XCTestCase {
    private func languageBundle(_ language: String) throws -> Bundle {
        let appBundle = Bundle(for: AppViewModel.self)
        let path = try XCTUnwrap(appBundle.path(forResource: language, ofType: "lproj"))
        return try XCTUnwrap(Bundle(path: path))
    }

    func testBothLanguagesArePackagedAndResolveRuntimeStrings() throws {
        let english = try languageBundle("en")
        let chinese = try languageBundle("zh-Hans")
        XCTAssertEqual(L10n.text("Unified Bookmarks", bundle: english), "Unified Bookmarks")
        XCTAssertEqual(L10n.text("Unified Bookmarks", bundle: chinese), "统一书签")
        XCTAssertEqual(L10n.text("Write Pending", bundle: chinese), "等待浏览器退出后写入")
        XCTAssertEqual(L10n.text("untranslated-key", bundle: chinese), "untranslated-key")
    }

    func testLocalizedFormattingPreservesUserContent() throws {
        let chinese = try languageBundle("zh-Hans")
        let title = "My %@ bookmark / 中文 🔖"
        let format = L10n.text("Add: %@", bundle: chinese)
        XCTAssertEqual(String(format: format, title), "新增：" + title)
        XCTAssertEqual(L10n.activityTitle("Add: " + title), L10n.format("Add: %@", title))
        XCTAssertEqual(L10n.activityTitle(title), title)
        XCTAssertEqual(L10n.profileSetName("My Set 1"), "My Set 1")
        XCTAssertEqual(L10n.profileSetName("Set work"), "Set work")
    }

    func testSearchCountUsesNativePluralResources() throws {
        for language in ["en", "zh-Hans"] {
            let bundle = try languageBundle(language)
            for count in [0, 1, 2, 1000] {
                let format = L10n.text("bookmarks_found", bundle: bundle)
                let result = String.localizedStringWithFormat(format, count)
                let formattedCount = count.formatted(.number)
                let expected = language == "zh-Hans" ? "找到 \(formattedCount) 项" : "\(formattedCount) found"
                XCTAssertEqual(result, expected)
            }
        }
    }
}
