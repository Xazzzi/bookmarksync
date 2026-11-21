import XCTest
@testable import BookmarkSync

final class ChromiumOSCryptTests: XCTestCase {
    /// Vector produced independently with Python's pbkdf2_hmac and `openssl enc -aes-128-cbc`.
    func testMatchesOpenSSLVector() throws {
        let key = ChromiumOSCrypt.deriveKey(password: Data("peanuts".utf8))
        XCTAssertEqual(key.map { String(format: "%02x", $0) }.joined(), "d9a09d499b4e1b7461f28e67972c6dbd")

        let sealed = Data("v10".utf8) + Data(base64Encoded: "Jw7h6ifQAC84Fx6ZEqyG0g==")!
        XCTAssertEqual(try ChromiumOSCrypt.encrypt(Data("hello bookmarks".utf8), key: key), sealed)
        XCTAssertEqual(try ChromiumOSCrypt.decrypt(sealed, key: key), Data("hello bookmarks".utf8))
    }

    func testRejectsUnknownPrefix() {
        let key = ChromiumOSCrypt.deriveKey(password: Data("peanuts".utf8))
        XCTAssertThrowsError(try ChromiumOSCrypt.decrypt(Data("v11abcdefabcdefabcdef".utf8), key: key))
    }

    /// CBC padding can pass by chance with a wrong key; the garbage must still never parse.
    func testWrongKeyNeverYieldsBookmarks() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("WrongKey_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let sealedURL = dir.appendingPathComponent("EncryptedBookmarks2")
        let json = Data(#"{"roots":{"bookmark_bar":{"name":"b","type":"folder","children":[]},"other":{"name":"o","type":"folder","children":[]},"synced":{"name":"s","type":"folder","children":[]}},"version":1}"#.utf8)
        try ChromiumOSCrypt.encrypt(json, key: ChromiumOSCrypt.deriveKey(password: Data("a".utf8))).write(to: sealedURL)

        let wrongKey = ChromiumOSCrypt.deriveKey(password: Data("b".utf8))
        let parser = ChromeParser(filePath: dir.appendingPathComponent("Bookmarks"), encrypted: ChromiumEncryptedBookmarks(url: sealedURL, key: { wrongKey }))
        XCTAssertThrowsError(try parser.read())
    }
}

final class ChromeEncryptedBookmarksTests: XCTestCase {
    private var dir: URL!
    private var plain: URL!
    private var sealedURL: URL!
    private let key = ChromiumOSCrypt.deriveKey(password: Data("test-password".utf8))

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ChromeEncrypted_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        plain = dir.appendingPathComponent("Bookmarks")
        sealedURL = dir.appendingPathComponent("EncryptedBookmarks2")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func json(_ bar: [(String, String)]) -> Data {
        let children = bar.enumerated().map { i, item in
            ["id": String(i + 10), "guid": UUID().uuidString.lowercased(), "name": item.0, "type": "url", "url": item.1, "date_added": "13300000000000000"]
        }
        func root(_ id: String, _ name: String, _ kids: [[String: Any]]) -> [String: Any] {
            ["id": id, "guid": UUID().uuidString.lowercased(), "name": name, "type": "folder", "date_added": "13300000000000000", "children": kids]
        }
        let doc: [String: Any] = [
            "roots": [
                "bookmark_bar": root("1", "Bookmarks bar", children),
                "other": root("2", "Other bookmarks", []),
                "synced": root("3", "Mobile bookmarks", [])
            ],
            "version": 1
        ]
        return try! JSONSerialization.data(withJSONObject: doc, options: .prettyPrinted)
    }

    private func seal(_ data: Data) throws {
        try ChromiumOSCrypt.encrypt(data, key: key).write(to: sealedURL)
    }

    private func unseal() throws -> Data {
        try ChromiumOSCrypt.decrypt(Data(contentsOf: sealedURL), key: key)
    }

    private final class Counter: @unchecked Sendable { var value = 0 }

    private func parser(keyRequests: Counter = Counter()) -> ChromeParser {
        let key = self.key
        return ChromeParser(filePath: plain, encrypted: ChromiumEncryptedBookmarks(url: sealedURL, key: {
            keyRequests.value += 1
            return key
        }))
    }

    private func titles(_ data: Data) throws -> [String] {
        let url = dir.appendingPathComponent("probe-\(UUID().uuidString)")
        try data.write(to: url)
        return try ChromeParser(filePath: url).read().map(\.title)
    }

    func testEncryptedFileWinsOverPlain() throws {
        try json([("Stale", "https://stale.example")]).write(to: plain)
        try seal(json([("Current", "https://current.example")]))

        XCTAssertEqual(try parser().read().map(\.title), ["Current"])
    }

    func testEncryptedOnlyProfileIsRead() throws {
        try seal(json([("Only", "https://only.example")]))
        XCTAssertEqual(try parser().read().map(\.title), ["Only"])
    }

    func testPlainOnlyProfileNeverAsksForKey() throws {
        try json([("Plain", "https://plain.example")]).write(to: plain)
        let requests = Counter()
        let parser = parser(keyRequests: requests)

        let nodes = try parser.read()
        try parser.write(nodes: nodes + [ParsedBookmark(id: "bookmark_bar:new.example", title: "New", url: "https://new.example", type: .leaf, parentId: nil, mtime: Date(), index: 1)])
        try parser.createBackup(manual: true)

        XCTAssertEqual(requests.value, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sealedURL.path))
        XCTAssertEqual(try parser.read().map(\.title), ["Plain", "New"])
    }

    func testWriteUpdatesBothFilesIdentically() throws {
        try json([("A", "https://a.example")]).write(to: plain)
        try seal(json([("A", "https://a.example")]))
        let parser = parser()

        let added = ParsedBookmark(id: "bookmark_bar:b.example", title: "B", url: "https://b.example", type: .leaf, parentId: nil, mtime: Date(), index: 1)
        try parser.write(nodes: try parser.read() + [added])

        XCTAssertEqual(try titles(unseal()), ["A", "B"])
        XCTAssertEqual(try unseal(), try Data(contentsOf: plain))
        let mode = try FileManager.default.attributesOfItem(atPath: sealedURL.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }

    func testWriteDoesNotRecreateRemovedPlainFile() throws {
        try seal(json([("A", "https://a.example")]))
        let parser = parser()
        try parser.write(nodes: try parser.read())

        XCTAssertFalse(FileManager.default.fileExists(atPath: plain.path))
        XCTAssertEqual(try titles(unseal()), ["A"])
    }

    func testBackupHoldsDecryptedJSONAndRestoreReencrypts() throws {
        try seal(json([("Before", "https://before.example")]))
        let parser = parser()

        let backupURL = try XCTUnwrap(try parser.createBackup(manual: true))
        XCTAssertEqual(try titles(Data(contentsOf: backupURL)), ["Before"])

        try seal(json([("After", "https://after.example")]))
        let entry = try XCTUnwrap(BackupStore.listBackups(for: plain).first { $0.url == backupURL })
        try parser.restore(entry)

        XCTAssertEqual(try parser.read().map(\.title), ["Before"])
        let undo = BackupStore.listBackups(for: plain).filter { $0.kind == .timestamped }
        XCTAssertEqual(try undo.map { try titles(Data(contentsOf: $0.url)) }, [["After"]], "The restore itself can be undone")
    }

    func testFactoryOnlyAttachesEncryptionToLiveChromiumFile() {
        let live = makeBookmarkParser(bundleId: "com.google.Chrome", profileName: "Default", fileURL: plain) as? ChromeParser
        XCTAssertEqual(live?.encrypted?.url, sealedURL)

        let backup = dir.appendingPathComponent("Bookmarks.backup.2026-11-21T10-00-00")
        let fromBackup = makeBookmarkParser(bundleId: "com.google.Chrome", profileName: "Default", fileURL: backup) as? ChromeParser
        XCTAssertNil(fromBackup?.encrypted)
    }

    func testEncryptedPathMapsToPlainPath() {
        XCTAssertEqual(ChromiumEncryptedBookmarks.plainPath(forEncrypted: sealedURL.path), plain.path)
        XCTAssertNil(ChromiumEncryptedBookmarks.plainPath(forEncrypted: plain.path))
        XCTAssertEqual(ChromiumEncryptedBookmarks.storagePaths(for: plain.path), [plain.path, sealedURL.path])
        XCTAssertEqual(ChromiumEncryptedBookmarks.storagePaths(for: "/x/places.sqlite"), ["/x/places.sqlite"])
    }
}

final class ChromiumSafeStorageTests: XCTestCase {
    private var suiteName: String!
    private var suite: UserDefaults!
    private var savedDefaults: UserDefaults!
    private var savedRead: ((String) throws -> Data)!
    private var service: String!

    override func setUp() {
        suiteName = "ChromiumSafeStorageTests_\(UUID().uuidString)"
        suite = UserDefaults(suiteName: suiteName)
        savedDefaults = ChromiumSafeStorage.defaults
        savedRead = ChromiumSafeStorage.readPassword
        ChromiumSafeStorage.defaults = suite
        service = "Test Safe Storage \(UUID().uuidString)"
    }

    override func tearDown() {
        ChromiumSafeStorage.defaults = savedDefaults
        ChromiumSafeStorage.readPassword = savedRead
        suite.removePersistentDomain(forName: suiteName)
    }

    func testKeychainIsNotAskedBeforeConsent() throws {
        var calls = 0
        ChromiumSafeStorage.readPassword = { _ in calls += 1; return Data("pw".utf8) }

        XCTAssertThrowsError(try ChromiumSafeStorage.key(service: service)) { error in
            XCTAssertEqual(ChromiumKeyIssue(error), .needsConsent)
        }
        XCTAssertEqual(calls, 0)

        ChromiumSafeStorage.grantConsent(service: service)
        XCTAssertEqual(try ChromiumSafeStorage.key(service: service), ChromiumOSCrypt.deriveKey(password: Data("pw".utf8)))
        _ = try ChromiumSafeStorage.key(service: service)
        XCTAssertEqual(calls, 1, "The key is cached after the first read")
        XCTAssertTrue(ChromiumSafeStorage.hasConsent(service: service), "Consent persists across launches")
    }

    func testDenialIsRememberedUntilTryAgain() throws {
        var calls = 0
        var deny = true
        let service = self.service!
        ChromiumSafeStorage.readPassword = { _ in
            calls += 1
            if deny { throw ChromiumEncryptionError.keychain(service: service, status: errSecUserCanceled) }
            return Data("pw".utf8)
        }
        ChromiumSafeStorage.grantConsent(service: service)

        XCTAssertThrowsError(try ChromiumSafeStorage.key(service: service)) { error in
            guard case .failed = ChromiumKeyIssue(error) else { return XCTFail("Expected a failed issue, got \(error)") }
        }
        XCTAssertThrowsError(try ChromiumSafeStorage.key(service: service))
        XCTAssertEqual(calls, 1, "A denial does not prompt again on every sync")

        deny = false
        ChromiumSafeStorage.grantConsent(service: service)
        XCTAssertNoThrow(try ChromiumSafeStorage.key(service: service))
        XCTAssertEqual(calls, 2)
    }

    func testEncryptedChromeProfileWithoutConsentIsSkippedWithoutPrompt() throws {
        var calls = 0
        ChromiumSafeStorage.readPassword = { _ in calls += 1; return Data("pw".utf8) }
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("NoConsent_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("v10 sealed".utf8).write(to: dir.appendingPathComponent("EncryptedBookmarks2"))

        let parser = makeBookmarkParser(bundleId: "com.google.Chrome", profileName: "Default", fileURL: dir.appendingPathComponent("Bookmarks"))
        XCTAssertThrowsError(try parser.read()) { error in
            XCTAssertEqual(ChromiumKeyIssue(error), .needsConsent)
        }
        XCTAssertEqual(calls, 0)
    }
}
