# BookmarkSync Design Document

## 1. Overview
BookmarkSync is a local-only, serverless macOS application designed to synchronize bookmarks between multiple browsers (Safari, Chromium-based, Firefox). Instead of relying on cloud APIs, it operates directly on the local bookmark files used by these browsers, merging changes and relying on the browsers' native sync mechanisms (Google Sync, iCloud, Firefox Sync) to propagate changes to other devices.

## 2. Goals & Non-Goals
### Goals
*   **Local-first & Privacy-focused**: No external servers, APIs, or accounts required.
*   **N-way Synchronization**: Seamlessly merge additions, modifications, and deletions across any number of connected browsers.
*   **Native Cloud Leveraging**: Allow browsers to naturally pick up the modified files and sync them to their respective clouds.
*   **Non-Blocking Reads & Safe Writes**: Read updates immediately after file changes; queue writes until safe to apply.
*   **Tray Icon UI**: Provide visibility into sync status, queues, history, and connected browsers.

### Non-Goals
*   Directly syncing with external cloud servers.
*   Mobile companion apps.

## 3. System Architecture
The application runs as a macOS Menu Bar (Tray) app and consists of five main components:

1.  **File Watcher**: Uses `FSEvents` to monitor the file system for `mtime` changes on the targeted bookmark files.
2.  **State Manager**: Uses a local SQLite database to maintain the sync state, history, and configuration.
3.  **Sync Engine**: Parses browser-specific formats into a normalized internal representation, performs an N-way merge, and queues updates for serialization back to browsers.
4.  **Write Queue**: Holds pending writes and applies them when safe (e.g., when the target browser releases locks or is idle).
5.  **User Interface**: A Menu Bar popover that displays connected browsers, current sync status, pending queue, and recent history.

## 4. Data Formats & Storage Locations

### Chromium (Google Chrome, Brave, Edge, etc.)
*   **Format**: JSON.
*   **Structure**: Contains a `roots` object with `bookmark_bar`, `other`, and `synced`.

### Safari
*   **Format**: Binary Property List (plist).
*   **Structure**: A nested dictionary containing `Children`, `Title`, `URIDictionary`, `WebBookmarkType`.

### Firefox
*   **Format**: SQLite database (`places.sqlite`).
*   **Structure**: Contains `moz_bookmarks` and `moz_places` tables.

## 5. Synchronization Logic (N-Way Merge)
To sync accurately across multiple browsers, the app uses an SQLite database as the central source of truth.

**Identity**: A bookmark's unique identity is determined by its `folder prefix + url`.

**Merge Process**:
1.  **Read**: Upon `mtime` change (after a short delay), read the updated browser's bookmark file. Read is performed immediately, as files are typically readable even while the browser runs.
2.  **Normalize**: Convert to a common internal representation using the `folder prefix + title` (for folders) or `folder prefix + url` (for leaves) key.
3.  **Diff against Observed State**: 
    *   Compare the newly read file against the *last observed state* of that specific profile (stored in SwiftData as `observedStateData`). This prevents delayed writes (e.g. from a locked browser file) from being misinterpreted as user deletions.
4.  **N-Way Merge & Conflict Resolution**:
    *   Identify additions, deletions, or modifications relative to the observed state.
    *   Update the SQLite central state (Hub).
    *   **Conflict Policy**: Updates (renames/moves) always win over deletions. If one profile deletes a node but another profile modified it, the deletion is rejected and the node is preserved or resurrected.
    *   Generate a list of necessary changes for all *other* connected browsers.
5.  **Queue Writes**: Place the required updates for other browsers into the Write Queue.
6.  **Flush Writes**: When safe, apply the pending changes to the respective browser files and update the `observedStateData` to match the newly written state.

## 6. Folder Mapping
Browsers have different default top-level folders. We need a standardized mapping:
*   **Bookmarks Bar**: Chrome (`bookmark_bar`) <-> Safari (`FavoritesBar`) <-> Firefox (`toolbar`)
*   **Other Bookmarks**: Chrome (`other`) <-> Safari (`BookmarksMenu` / Unsorted) <-> Firefox (`unfiled`)
*   **Mobile Bookmarks**: Chrome (`synced`) <-> Safari (iCloud) <-> Firefox (`mobile`)

## 7. Lifecycle and Safety Constraints
**Execution Flow**:
1.  **Detect Change**: `FSEvents` detects an `mtime` change.
2.  **Immediate Read**: After a short debounce delay, the file is read and parsed.
3.  **Queue Sync**: Differences are calculated and write operations for other browsers are queued.
4.  **Execute Sync (Flush)**: The Write Queue attempts to flush changes to target browsers. If a browser aggressively locks its file, the write is deferred until it is safe (e.g. browser closes or file is unlocked).

## 8. Edge Cases to Handle
*   **Mass Deletions**: If a large number of bookmarks are deleted, the app introduces a delay before automatically applying the deletion to other browsers. It triggers an alert to the user, allowing them to review and revert the change if it was an error or file corruption.
*   **Browser Sync Conflicts**: Browsers might re-download a deleted bookmark from their cloud. The SQLite state must track deletion timestamps to avoid sync loops.

## 9. Proposed Technology Stack
*   **Language**: Swift (Native macOS APIs, ideal for Menu Bar apps).
*   **File Watching**: `FSEvents`.
*   **Local State**: SQLite.
*   **UI**: SwiftUI for the Menu Bar popover and preferences window.

## 10. User Interface (Tray App)
*   **Status Area**: Current sync status (Idle, Syncing, Queued).
*   **Connected Browsers**: Toggles to enable/disable syncing for detected browsers.
*   **Sync Queue**: List of pending writes waiting for safe execution.
*   **History**: Log of recently synced additions, modifications, and deletions.
*   **Alerts**: Notifications for mass deletions with a "Revert" action.
