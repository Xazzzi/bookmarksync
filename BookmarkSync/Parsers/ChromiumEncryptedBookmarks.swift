import Foundation
import CommonCrypto
import Security

/// Chromium's `EncryptedBookmarks2`: the same JSON as `Bookmarks`, under the os_crypt key.
/// Chrome loads it in preference to `Bookmarks` and rewrites `Bookmarks` from it,
/// so it is the source of truth whenever it exists.
struct ChromiumEncryptedBookmarks: Sendable {
    static let fileName = "EncryptedBookmarks2"
    static let plainFileName = "Bookmarks"

    let url: URL
    /// The 16-byte AES key; may show the Keychain prompt.
    let key: @Sendable () throws -> Data

    /// The encrypted store of a live Chromium `Bookmarks` file, or nil for any
    /// other file (backups, other browsers).
    static func forPlainFile(_ plainURL: URL, bundleId: String) -> ChromiumEncryptedBookmarks? {
        guard plainURL.lastPathComponent == plainFileName,
              let service = ChromiumSafeStorage.services[bundleId] else { return nil }
        return ChromiumEncryptedBookmarks(
            url: plainURL.deletingLastPathComponent().appendingPathComponent(fileName),
            key: { try ChromiumSafeStorage.key(service: service) }
        )
    }

    /// The live `Bookmarks` path an `EncryptedBookmarks2` path stands for.
    static func plainPath(forEncrypted path: String) -> String? {
        guard (path as NSString).lastPathComponent == fileName else { return nil }
        return ((path as NSString).deletingLastPathComponent as NSString).appendingPathComponent(plainFileName)
    }

    /// Every file holding a profile's bookmarks: the encrypted sibling too for Chromium.
    static func storagePaths(for bookmarkFilePath: String) -> [String] {
        guard (bookmarkFilePath as NSString).lastPathComponent == plainFileName else { return [bookmarkFilePath] }
        let dir = (bookmarkFilePath as NSString).deletingLastPathComponent
        return [bookmarkFilePath, (dir as NSString).appendingPathComponent(fileName)]
    }

    var exists: Bool { FileManager.default.fileExists(atPath: url.path) }

    func readJSON() throws -> Data {
        let sealed = try Data(contentsOf: url)
        return try ChromiumOSCrypt.decrypt(sealed, key: key())
    }

    func write(json: Data) throws {
        let sealed = try ChromiumOSCrypt.encrypt(json, key: key())
        try writePrivately(sealed, to: url)
    }
}

/// Writes atomically with owner-only permissions, as Chrome creates these files.
func writePrivately(_ data: Data, to url: URL) throws {
    try data.write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
}

enum ChromiumEncryptionError: LocalizedError {
    case unsupportedFormat
    case cryptFailed(Int32)
    case keychain(service: String, status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat:
            return "Encrypted bookmarks use an unsupported format (expected a \"v10\" prefix)."
        case .cryptFailed(let status):
            return "Encrypted bookmarks could not be decrypted (CommonCrypto status \(status))."
        case .keychain(let service, let status):
            let reason = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return "Could not read \"\(service)\" from the Keychain: \(reason). Allow access when asked; after a denial, restart BookmarkSync to be asked again."
        }
    }
}

/// macOS os_crypt "v10": AES-128-CBC, PKCS#7 padding, an IV of 16 spaces, and a
/// key derived from the Keychain password by PBKDF2-SHA1 (salt "saltysalt", 1003 rounds).
enum ChromiumOSCrypt {
    static let prefix = Data("v10".utf8)
    private static let salt = Data("saltysalt".utf8)
    private static let rounds: UInt32 = 1003
    private static let keyLength = kCCKeySizeAES128
    private static let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)

    static func deriveKey(password: Data) -> Data {
        var key = Data(count: keyLength)
        _ = key.withUnsafeMutableBytes { keyBytes in
            password.withUnsafeBytes { passwordBytes in
                salt.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.baseAddress?.assumingMemoryBound(to: CChar.self), password.count,
                        saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), rounds,
                        keyBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), keyLength
                    )
                }
            }
        }
        return key
    }

    static func decrypt(_ sealed: Data, key: Data) throws -> Data {
        guard sealed.starts(with: prefix) else { throw ChromiumEncryptionError.unsupportedFormat }
        return try crypt(CCOperation(kCCDecrypt), sealed.dropFirst(prefix.count), key: key)
    }

    static func encrypt(_ plaintext: Data, key: Data) throws -> Data {
        prefix + (try crypt(CCOperation(kCCEncrypt), plaintext, key: key))
    }

    private static func crypt(_ operation: CCOperation, _ input: Data, key: Data) throws -> Data {
        let input = Data(input)
        var output = Data(count: input.count + kCCBlockSizeAES128)
        var written = 0
        let status = output.withUnsafeMutableBytes { outBytes in
            input.withUnsafeBytes { inBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            operation, CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress, key.count, ivBytes.baseAddress,
                            inBytes.baseAddress, input.count,
                            outBytes.baseAddress, outBytes.count, &written
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw ChromiumEncryptionError.cryptFailed(status) }
        output.count = written
        return output
    }
}

/// Each Chromium browser's os_crypt key, from its "<Name> Safe Storage" Keychain item.
/// The key and a denial are both kept until the app quits, so syncs never prompt twice.
enum ChromiumSafeStorage {
    static let services: [String: String] = [
        "com.google.Chrome": "Chrome Safe Storage",
        "com.brave.Browser": "Brave Safe Storage",
        "com.microsoft.edgemac": "Microsoft Edge Safe Storage",
        "com.vivaldi.Vivaldi": "Vivaldi Safe Storage",
        "com.operasoftware.Opera": "Opera Safe Storage",
        "org.chromium.Chromium": "Chromium Safe Storage"
    ]

    // One lock for all browsers, so concurrent profile reads queue behind a single prompt.
    private static let lock = NSLock()
    private static var cache: [String: Result<Data, Error>] = [:]

    static func key(service: String) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[service] { return try cached.get() }

        let result = Result { try fetchKey(service: service) }
        switch result {
        case .success:
            cache[service] = result
        case .failure(ChromiumEncryptionError.keychain(_, let status))
            where status == errSecUserCanceled || status == errSecAuthFailed:
            cache[service] = result
        case .failure:
            break
        }
        return try result.get()
    }

    private static func fetchKey(service: String) throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let password = item as? Data else {
            throw ChromiumEncryptionError.keychain(service: service, status: status)
        }
        SyncLog.event("Read the \(service) key from the Keychain")
        return ChromiumOSCrypt.deriveKey(password: password)
    }
}
