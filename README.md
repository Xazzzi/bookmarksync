# BookmarkSync

[简体中文说明](README.zh-CN.md) · English

A local-first, serverless macOS tray application that dynamically synchronizes bookmarks across multiple browsers (Safari, Chromium-based browsers, and Firefox) without relying on external cloud APIs or databases. 

By directly merging local browser bookmark files, it leverages each browser's native cloud synchronization mechanisms (iCloud, Google Sync, Firefox Sync) to seamlessly propagate updates to all of your other devices.

---

## 🚀 Key Features

* **Local-First & Private**: Operates strictly within the macOS sandbox. No external APIs, servers, or cloud credentials required. The only network request is the optional update check, which is off until you enable it.
* **Unified N-Way Merge**: An orchestrator resolves updates, deletes, and insertions dynamically across all connected browsers using a centralized SwiftData cache.
* **Dynamic File Watching**: Monitors parent directories of *only enabled browser profiles* recursively via `FSEvents`. Automatically ignores unrelated system changes (caches, logs, history) using precise file-level filters (`Bookmarks`, `Bookmarks.plist`, `places.sqlite`).
* **Zero-Latency Write Pipeline**: Pending writes are safely queued to prevent cache clobbering while a browser is running. Observing application terminations instantly flushes writes the moment you close a browser.
* **Lock-Resilient Sync via Observed Profile State**: Strict tracking of each profile's observed state prevents cascading deletions when browser files are locked, deferring writes until the target is ready.
* **URL Normalization**: Built-in Swift `URL` normalizer ignores the protocol (`http`/`https`), host case, a leading `www.`, default ports and trailing slashes, so equivalent URLs map to one stable composite ID. Paths, query strings, fragments and non-default ports are kept as-is, because they identify different pages.
* **Universal Folder Identity**: All browser parsers construct deterministic, title-based identities for folders, guaranteeing robust merging of same-named folders across Safari, Chrome, and Firefox.
* **Robust Rename Resolution & Conflict Handling**: Detects renames by comparing each browser's state against the last known database sync state. In conflicting situations (e.g., Profile A deletes, Profile B renames), updates and renames always win over deletions, preserving data intact.
* **Epoch-Based Timestamping**: Safe epoch fallback (`Jan 1, 1970`) for Safari bookmarks prevents Safari's blank timestamps from overriding active edits from other browsers.
* **Modern Menu Bar UI**: A lightweight SwiftUI popover shows real-time status indicators (green dots for recent sync), dynamic profile toggles with native application icons, scrollable diff history queues, and a dedicated Backups View.

---

## 🛠️ Architecture

```mermaid
graph TD
    App[BookmarkSyncApp] --> Tray[TrayMenu Popover]
    App --> VM[AppViewModel @MainActor]
    VM --> SE[SyncEngine @MainActor]
    SE --> DB[(SwiftData Cache)]
    SE --> Parsers[Browser Parsers]
    SE --> WQ[WriteQueue]
    Parsers --> Safari[SafariParser plist]
    Parsers --> Chrome[ChromeParser JSON]
    Parsers --> Firefox[FirefoxParser SQLite]
    WQ --> Files[Browser Files]
```

### File Hierarchy
```text
├── BookmarkSync/
│   ├── BookmarkSyncApp.swift     # Entry point & SwiftUI lifecycle
│   ├── TrayMenu.swift            # Menu Bar Extra popover UI
│   ├── Core/
│   │   ├── BrowserDiscoverer.swift # Dynamic Chromium/Firefox profiles scanning
│   │   ├── FileWatcher.swift     # Core FSEvent recursive directory monitor
│   │   ├── SyncEngine.swift      # N-way merge engine & DB manager
│   │   └── WriteQueue.swift      # Thread-safe serial write pipeline
│   ├── Models/
│   │   └── BookmarkNode.swift    # SwiftData node model & URL normalizer
│   ├── Parsers/
│   │   ├── BrowserParser.swift   # Read/Write protocol
│   │   ├── ChromeParser.swift    # JSON decoder & WebKit timestamp parser
│   │   ├── SafariParser.swift    # Plist decoder & URIDictionary writer
│   │   └── FirefoxParser.swift   # SQLite wrapper (places.sqlite)
│   └── Views/
│       └── BackupsView.swift     # Dynamic backups restoration manager
├── project.yml                   # XcodeGen declaration & build configuration
└── AGENTS.md                     # Architectural record & onboarding document
```

---

## 🏗️ Building and Running

The project layout is defined and generated dynamically via `XcodeGen`.

### Prerequisites
Ensure `xcodegen` is installed:
```bash
brew install xcodegen
```

### Steps to Generate and Build
1. Generate the Xcode project from the root folder:
   ```bash
   xcodegen generate
   ```
2. Open `BookmarkSync.xcodeproj` in Xcode.
3. Select the `BookmarkSync` scheme and build (`Cmd + B`) or run (`Cmd + R`).

### Custom Configurations (in `project.yml`)
* **Agent App Settings**: The application compiles as a background agent (`LSUIElement: true`), hiding it from the macOS Dock. Only the menu bar tray icon remains visible.
* **Code Signing**: Automatic code signing is pre-configured with team ID `MCC7MZGLZ8`. CI builds are signed with a persistent certificate; see [docs/ci-signing.md](docs/ci-signing.md).
* **Diagnostic Noise Suppression**: Scheme environment variable `OS_ACTIVITY_MODE: disable` is configured to automatically silence noisy Apple Intelligence / Greymatter diagnostic warnings in the Xcode console.

---

## 📂 Detailed Onboarding & History

For in-depth explanations on the dynamic file watcher, SwiftUI picker bugs, detached SwiftData context crashes, and lock-resilient synchronization, refer to the [AGENTS.md](AGENTS.md) file inside the project root.

---

## 🔔 Update Checks

Update checks are off by default. In the menu bar popover, enable **Check for updates weekly** or click **Check Now**.
The app then fetches `https://bookmarksync.xazi.app/latest.txt?v=<its version>`, at most once a week.
If a newer version exists, a banner shows its changelog, and **Download** opens the website.

To announce a release, update `Website/latest.txt`.
Line 1 holds the version, and each later line is one changelog entry:

```text
1.2.0
- Ukrainian and Spanish interface
- Weekly update check
```

---

## 🌐 Interface Languages

The app includes English, Simplified Chinese (`zh-Hans`), Ukrainian (`uk`) and
Spanish (`es`) using native macOS localization. It follows the system language
by default. To override it, open
**System Settings → General → Language & Region → Applications**, add
**BookmarkSync**, and choose a language. Quit and reopen the app after changing
the language.

Localization resources live in `BookmarkSync/Localization/{language}.lproj`.
SwiftUI literals use `Localizable.strings`; runtime messages use `L10n` and search
counts use `Localizable.stringsdict`. Add matching keys and format arguments in
every language. Run `python3 scripts/check_localizations.py` before submitting.

Bookmark titles, browser profile names, stored `Set N` names, activity tokens,
and the `Deleted by BookmarkSync` archive folder remain unchanged on disk.
Only generated group labels and activity prefixes are translated for display.

---

## 🙏 Contributors

* [JasonZhang1225](https://github.com/JasonZhang1225) ([bookmarksync-cn](https://github.com/JasonZhang1225/bookmarksync-cn)):
  * Simplified Chinese localization and `README.zh-CN.md`.
  * Deletion safety: parse-error detection and held mass deletions awaiting confirmation.
  * Timestamped backups with retention, manual backups, and diff preview before restore.
  * Case-preserving URL identity with stored-id migration.
  * Empty folder preservation and per-browser root mapping.
  * Incremental Firefox writer that keeps GUIDs, separators and Firefox Sync state.
  * Safari top-level and mobile bookmark folders.
  * Profile discovery that keeps unavailable profiles instead of deleting them.
  * Deleting bookmarks from the bookmarks window, write-wait banner, and version display.
  * macOS CI workflow with persistent-certificate signing.
