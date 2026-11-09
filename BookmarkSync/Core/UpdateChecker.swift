import Foundation
import AppKit

/// Opt-in check for a newer release, announced in a plain text file on the website.
///
/// Off by default: nothing is requested until the user enables weekly checks or
/// clicks "Check Now". The request carries only the app's own version, in its User-Agent.
@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    /// First line is the latest version, e.g. `1.2.0`; later lines are its changelog.
    static let feedURL = URL(string: "https://bookmarksync.xazi.app/latest.txt")!
    static let downloadURL = URL(string: "https://bookmarksync.xazi.app/")!
    static let interval: TimeInterval = 7 * 86_400

    static let enabledKey = "updateCheckEnabled"
    static let lastCheckKey = "updateCheckLastDate"
    static let dismissedKey = "updateCheckDismissedVersion"

    /// The announced release: its version and the changelog lines shown to the user.
    struct Release: Equatable {
        let version: String
        let notes: [String]
    }

    /// At most this many changelog lines are shown.
    static let maxNotes = 10

    enum Status: Equatable {
        case idle
        case checking
        case upToDate
        case failed(String)
    }

    @Published private(set) var status: Status = .idle
    /// A newer release than the running one, unless the user dismissed it.
    @Published private(set) var available: Release?

    @Published var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: Self.enabledKey)
            if isEnabled { checkIfDue() }
        }
    }

    private let defaults: UserDefaults
    private var timer: Timer?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.isEnabled = defaults.bool(forKey: Self.enabledKey)
    }

    /// Re-evaluates hourly, so a menu bar app that runs for weeks still checks weekly.
    func start() {
        guard timer == nil else { return }
        checkIfDue()
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
            Task { @MainActor in UpdateChecker.shared.checkIfDue() }
        }
    }

    func checkIfDue(now: Date = Date()) {
        guard isEnabled, Self.isDue(lastCheck: defaults.object(forKey: Self.lastCheckKey) as? Date, now: now) else { return }
        checkNow(userInitiated: false)
    }

    /// A user-initiated check shows an update even if its banner was dismissed.
    func checkNow(userInitiated: Bool = true) {
        guard status != .checking else { return }
        status = .checking
        Task {
            do {
                let latest = try await Self.fetchLatest(current: AppVersion.short)
                defaults.set(Date(), forKey: Self.lastCheckKey)
                if Self.isNewer(latest.version, than: AppVersion.short) {
                    let dismissed = !userInitiated && defaults.string(forKey: Self.dismissedKey) == latest.version
                    available = dismissed ? nil : latest
                    status = .idle
                } else {
                    available = nil
                    status = .upToDate
                }
            } catch {
                SyncLog.error("[Update] Check failed: \(error)")
                status = .failed(error.localizedDescription)
            }
        }
    }

    func openDownloadPage() {
        NSWorkspace.shared.open(Self.downloadURL)
    }

    /// Hides the banner for this version; a later version shows it again.
    func dismiss() {
        guard let version = available?.version else { return }
        defaults.set(version, forKey: Self.dismissedKey)
        available = nil
    }

    // MARK: Pure helpers

    static func isDue(lastCheck: Date?, now: Date) -> Bool {
        guard let lastCheck else { return true }
        return now.timeIntervalSince(lastCheck) >= interval
    }

    /// The version on the first non-empty line, or nil if it is not dotted numbers.
    /// Each later non-empty line is one changelog entry; a leading `-`, `*` or `•` is dropped.
    static func parseLatest(_ text: String) -> Release? {
        let lines = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let version = lines.first, components(version) != nil else { return nil }
        let notes = lines.dropFirst().prefix(maxNotes).map { line in
            ["- ", "* ", "• "].first { line.hasPrefix($0) }.map { String(line.dropFirst($0.count)) } ?? line
        }
        return Release(version: version, notes: notes)
    }

    static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard var lhs = components(candidate), var rhs = components(current) else { return false }
        let count = max(lhs.count, rhs.count)
        lhs += Array(repeating: 0, count: count - lhs.count)
        rhs += Array(repeating: 0, count: count - rhs.count)
        return rhs.lexicographicallyPrecedes(lhs)
    }

    private static func components(_ version: String) -> [Int]? {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        let numbers = parts.compactMap { Int($0) }
        return !parts.isEmpty && numbers.count == parts.count ? numbers : nil
    }

    enum CheckError: LocalizedError {
        case badResponse(Int)
        case unreadable

        var errorDescription: String? {
            switch self {
            case .badResponse(let code): return "HTTP \(code)"
            case .unreadable: return L10n.text("Unexpected update file contents")
            }
        }
    }

    /// No cookies, cache or credentials are kept between checks.
    private static let session = URLSession(configuration: .ephemeral)

    private static func fetchLatest(current: String) async throws -> Release {
        var request = URLRequest(url: feedURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpShouldHandleCookies = false
        // Replaces the default agent, which would also reveal CFNetwork and Darwin versions.
        request.setValue("BookmarkSync/\(current)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw CheckError.badResponse(http.statusCode)
        }
        guard let text = String(data: data, encoding: .utf8), let latest = parseLatest(text) else {
            throw CheckError.unreadable
        }
        return latest
    }
}
