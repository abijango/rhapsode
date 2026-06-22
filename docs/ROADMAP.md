# Rhapsode — Post-MVP Roadmap

Forward-looking engineering plan for the three efforts after the in-app MVP:
**(3) background sync**, **(4) iPad + macOS**, **(5) cross-device progress sync**.

Written against the current codebase (Phases 0–2). Key existing pieces this builds on:
- `SyncManager` (`Sources/Sync/`) — owns scan / watcher / download queue (`DownloadItem`) / notifications. The single transfer call is isolated in `SyncManager.transfer(_:to:)`.
- `DropboxSource` (`Sources/Source/`) — raw HTTP, read-only scopes, OAuth PKCE, token in Keychain.
- `AudiobookPlayer` / `EbookReader` — persist progress to `Audiobook.lastTrackIndex/lastOffsetSeconds` and `Book.readingLocator`.
- `AppSchema` — five `@Model`s; **no `@Attribute(.unique)`** (already CloudKit-friendly), relative paths only, stable `UUID`s.

Recommended order: **3 → 4a (iPad) → 5 (sync) → 4b (macOS)**. Rationale at the end.

---

## Status — resume here (Phase 3 + 4a landed)

**Built + working in-app (Phases 0–2):** connect Dropbox, manual Scan now, foreground auto-detect (longpoll watcher), download queue (`DownloadsView`), foreground notifications, cover art, delete (with file removal), Readium reader, audiobook player.

**Phase 3 (background sync, single-file) + Phase 4a (iPad adaptive layout) — DONE (2026-06-22, commits `ebffae6`, `50524a5`).** Built by two parallel Sonnet agents, integrated + verified by the orchestrator. Headless self-test now **53 checks, all green** (37 base + 12 Phase 3 `P3:` + 4 Phase 4a), confirmed on the committed tree (incl. the `UIApplicationSupportsMultipleScenes` manifest add). Build/run commands + constraints live in the memory files (`rhapsode-build-workflow`, `rhapsode-phase-constraints`).

> **Coverage caveat (important for the next session):** the 53 green checks do **not** exercise the new background-download path. The mock still routes Scan→download→import through the *inline foreground* branch (so check #8 stays green), and the new `P3:` checks are pure-helper unit tests (ASCII escape, `TaskPayload` round-trip, `downloadRequest` headers, orphan detection). The entire `DropboxSource → BackgroundDownloader.enqueue → delegate` pipeline is **device-only unverified** — not partially covered. Likewise `UIApplicationSupportsMultipleScenes` is *enabled but unverified*, and multi-window is the first thing that would stress the `BackgroundDownloader.shared` / app-wide `SyncManager` single-instance assumptions.

**Still device-only PENDING (orchestrator/user's on-device step):** OS suspension + background completion delivery; cold-relaunch `handleEventsForBackgroundURLSession`→`urlSessionDidFinishEvents`; `BGTaskScheduler` firing; 401-after-suspension re-enqueue; iPad hardware-keyboard shortcuts (space=play/pause, arrow=page-turn — arrows may be eaten by Readium's webview); multi-window scene stress. Plus the open MVP live check: real M4B + MP3-folder download from Dropbox.

**Remaining phases:** 3b (MP3-folder background groups — needs `groupID` on `DownloadItem`, a `Models.swift` edit, do serially), 5 (CloudKit progress sync), 4b (macOS Catalyst).

**Pending on-device verification (simulator can't show these):** lock-screen / Control-Center Now Playing controls; true background downloads; `BGTaskScheduler` firing. Plus a user-side check: live **M4B + MP3-folder** download from real Dropbox (only single-file EPUB confirmed live so far).

**Loose ends (small):** ASCII-escape the `Dropbox-API-Arg` header (non-ASCII filenames 400); strip DEBUG scaffolding (`PhaseZeroSelfTest`, `DebugReaderHarness`, 🐞 buttons, `Fixtures/`, `RHAPSODE-SYNC` logs) from Release.

**Hard constraints (do not regress):** Dropbox HTTP-not-SDK + App-folder + read-only scopes; relative paths only via `ContainerPaths`; no `@Attribute(.unique)`; `@preconcurrency import` for non-Swift-6 libs (Readium, BackgroundTasks); **all framework callbacks hop via `Task { @MainActor }`** (AVPlayer observers, remote commands, MediaPlayer artwork must be `nonisolated`) — three playback crashes came from violating this.

---

## Cross-cutting prerequisites (do these regardless)

- **ASCII-escape the `Dropbox-API-Arg` header.** Dropbox requires this header be ASCII; non-ASCII paths (accented author/title) currently 400. Harmless to defer in the foreground, but in the **background** a silent 400 is much worse to debug — fix it as part of Phase 3. Add a JSON `\uXXXX` escaper in `DropboxSource.downloadFile`/`rpc`.
- **Strip DEBUG scaffolding before any release build.** `PhaseZeroSelfTest`, `DebugReaderHarness`, the 🐞 "Load samples" buttons, `Fixtures/SampleLibrary`, and `RHAPSODE-SYNC` logs are all `#if DEBUG`-gated already — confirm none ship in Release.

---

## Phase 3 — Background sync (iOS, no paid entitlement)

**Goal:** downloads continue when the app is backgrounded/suspended, and new files are pulled while the app is closed — so a book can "finish downloading on the lock screen."

**Why it's a real change, not a flag:** today `transfer()` is an inline `await source.download(...)`; the OS suspends it when the app backgrounds. Background transfers are handed to the OS, which can **relaunch the app** to deliver completion — so the "download → import → mark done → notify" logic must move from an inline call into **delegate callbacks** that may fire after a cold relaunch.

### 3a. Background `URLSession` for single files (EPUB, M4B)

**New: `BackgroundDownloader`** (`Sources/Sync/`), a `URLSessionDownloadDelegate`:
- `URLSession` with `URLSessionConfiguration.background(withIdentifier: "com.naufalmir.rhapsode.bg-downloads")`, `sessionSendsLaunchEvents = true`, `isDiscretionary = false`.
- Recreated as a singleton at launch with the **same identifier** so in-flight tasks reattach to the delegate after relaunch.

**`DropboxSource` change:** expose `func downloadRequest(for path: String) async throws -> URLRequest` that refreshes the token and sets `Authorization` + (ASCII-escaped) `Dropbox-API-Arg`. Background tasks can't refresh mid-flight, so the token is baked into the request at enqueue time. (If a task fails 401 after a long suspension, re-enqueue with a fresh token.)

**Pipeline split (in `SyncManager`):**
- `process()` → `enqueue()`: create `DownloadItem(.downloading)`, build the request, create a `URLSessionDownloadTask`, set `task.taskDescription` to a small payload (`DownloadItem.id` + destination rel path + kind + title) so the mapping **survives the app being killed**, `resume()`, fire the "start" notification, return.
- Delegate `urlSession(_:downloadTask:didFinishDownloadingTo:)`: decode `taskDescription` → move temp file to the container destination → import (`AudiobookImporter`/`EbookImporter`) → mark `DownloadItem.done` → "finish" notification. Hops to `@MainActor` for SwiftData.
- `didWriteData` → update `DownloadItem.bytesReceived/totalBytes` (now we get real progress; the `DownloadsView` bar becomes meaningful).
- `didCompleteWithError` → mark `.failed`.

**AppDelegate (required):** add a minimal `UIApplicationDelegateAdaptor`. Implement `application(_:handleEventsForBackgroundURLSession:completionHandler:)` to **store** the completion handler; `urlSessionDidFinishEvents(forBackgroundURLSession:)` calls it on the main thread. Without this the OS won't deliver background completions. (This AppDelegate can also absorb the `BGTaskScheduler` registration currently in `RhapsodeApp.init`.)

**Launch reconciliation:** on launch, ask the session for `getAllTasks` and mark any `DownloadItem` stuck in `.downloading` with no live task as `.failed` (or re-enqueue). Handles the "killed mid-download, task lost" case.

### 3b. MP3-folder audiobooks (the hard sub-case)

A folder isn't one transfer. Add `groupID: String?` to `DownloadItem` (additive, optional → safe migration). For a folder entry: `listFolder` its children, create one `DownloadItem` per child sharing a `groupID`, enqueue each as a background task. On each child completion, check whether **all** items in the group are `.done`; if so, run the folder import once. Group state lives in the `DownloadItem` rows, so it survives relaunch. **Ship 3a first; 3b is a follow-up** (single files cover EPUB + the common single-file M4B).

### 3c. Wire `BGTaskScheduler` to the background session

`BackgroundRefresh.backgroundDeltaCheck()` already exists but calls the foreground download. Change it to **enqueue** into `BackgroundDownloader` and return quickly (the OS continues the transfers outside the refresh window). Keep the existing registration + scheduling.

### Entitlements / Info.plist
- **None new / no paid account.** Background `URLSession` and `BGTaskScheduler` work on the free provisioning profile (deliberate spec constraint). `UIBackgroundModes: fetch` and `BGTaskSchedulerPermittedIdentifiers` are already set.

### Verification (device-only)
1. Start a download, background the app → it completes; lock-screen "Download complete" notification fires.
2. Start a download, **force-quit** the app → relaunch → it finishes (proves `handleEvents` + reconciliation).
3. `BGTaskScheduler`: pause in Xcode debugger and run
   `e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"com.naufalmir.rhapsode.refresh"]`.
4. Drop a file in Dropbox with the app **closed** → reopen later → it's there (BGTask pulled it).

*Not verifiable in the simulator* — the sim can't truly suspend/relaunch for background transfers.

---

## Phase 4 — iPad + macOS (shared SwiftUI codebase)

### 4a. iPad (low effort — already universal)
`TARGETED_DEVICE_FAMILY = "1,2"` already builds for iPad; Readium's navigator and `AVPlayer` both run there. Work is **adaptive layout**, not new architecture:
- Library → `NavigationSplitView` (sidebar of shelves / detail grid) on regular size classes; keep the `TabView` on compact (iPhone).
- Wider shelf grid columns; player/reader sized for the larger canvas; support Slide Over / Split View / multiple scenes.
- Pointer + hardware-keyboard affordances (page-turn keys in the reader, space = play/pause).
- No entitlement changes.

### 4b. macOS via **Mac Catalyst** (not native AppKit)
**Key constraint:** the Readium Swift toolkit's navigator is **UIKit-based** — it runs on iOS and **Mac Catalyst**, but **not** native macOS/AppKit. So a native SwiftUI-for-macOS target can't reuse the reader. **Use Mac Catalyst** to share the entire codebase (verify Readium's current Catalyst support first — check the swift-toolkit platforms before committing).
- `project.yml`: enable `SUPPORTS_MACCATALYST = YES`, set a macOS deployment target, add a Catalyst destination.
- Add menu-bar `Commands`, window sizing, keyboard shortcuts, pointer support.
- `ASWebAuthenticationSession` (Dropbox OAuth) and Keychain both work on Catalyst.
- **Background differs on macOS:** `BGTaskScheduler` is iOS-only. On macOS, rely on the app being open (longpoll watcher) + background `URLSession` (works on Catalyst). Document the reduced "while fully closed" behavior on Mac.

---

## Phase 5 — Cross-device progress sync (Dropbox app folder) — BUILT

**Goal:** start an audiobook on iPhone, resume at the same spot on iPad/Mac; same for EPUB reading position.

> **Decision (2026-06-22): Dropbox app-folder sync, NOT CloudKit.** Rationale: cross-device sync means writing shared state somewhere every device reads. CloudKit is Apple-only (zero Android story — you'd build a second backend later) and needs a paid Apple Developer account. The Dropbox app folder ports to the planned **Android** client unchanged (plain HTTP + JSON, per the SPEC's own portability rationale) and needs no paid account. Cost: broaden the scope to include **app-folder write** (`files.content.write`) — still narrow, never Full Dropbox. The earlier "keep Dropbox read-only / use CloudKit" rejection below was written before weighting Android; Android being a real goal flips the decision. A server is out (violates "no server/webhook/push").

### Design: sync *progress*, not files
Media files are **not** synced — they're re-downloaded from Dropbox per device (offline-first; Dropbox is the source of truth). The **container-relative paths are identical across devices** (same app folder, same import logic), so `Audiobook.sourcePath` / `Book.fileRelPath` are **stable cross-device keys**.

**Implemented:**
- `PlaybackProgress` **wire struct** (Codable, NOT a SwiftData model): `key`, `kind`, `lastTrackIndex`, `lastOffsetSeconds`, `readingLocatorJSON?`, `updatedAt`. Local source of truth stays in `Audiobook`/`Book`.
- `ProgressSync` protocol + `DropboxProgressSync` conformer (one JSON file per item under `/.rhapsode-sync`, named by SHA-256 of the key; read-before-write LWW guard) + `NoopProgressSync` (default) + `MockProgressSync` (tests). This is the seam that ports to Android.
- `DropboxSource.writeFile`/`readFile` (`files/upload` overwrite + `files/download`, 409→nil).
- Schema: additive optional `progressUpdatedAt: Date?` on `Audiobook` + `Book` (drives LWW). **No CloudKit-compat optional-everything refactor** — not needed without `NSPersistentCloudKitContainer`.
- Write points: `SyncManager.pushAudiobookProgress`/`pushBookProgress`, triggered by `PlayerView`/`ReaderView` `onDisappear` (player/reader untouched — they already persist locally). Pull+merge on foreground via `ensureWatching` → `pullAndMergeProgress` (LWW by `progressUpdatedAt`).
- Self-test: +9 Phase 5 `P5:` checks (wire round-trip, LWW decision, path encoding, SyncManager merge both directions, push guard).

**Known gaps / device-only:**
- Real Dropbox upload/download is live-only (self-test uses `MockProgressSync`).
- **Push misses while the player stays open:** `onDisappear` fires on normal navigation-away (the unstructured `Task {}` survives teardown), but a book left **playing in the background** or the **app killed with the player open** won't push that session's final position until the next foreground re-sync. No periodic remote push yet.
- **Foreground pull cost:** `pullAndMergeProgress` runs on every activation (`listFolder` + N `readFile`). Fine for a small library; with many books it's N+1 Dropbox round-trips per app open — future: pull only changed / cache a sync-folder cursor.
- **LWW is wall-clock based:** clock skew between devices (not just simultaneous playback) can pick the wrong winner. Acceptable for single-user.
- Existing connections must **reconnect** to grant the new `files.content.write` scope (first push 401s on a pre-Phase-5 token).

### Verification (device-only)
Two devices on the same Dropbox app folder: listen on A, leave the player, open the book on B → position resumes. Repeat for EPUB locator. Confirm reconnect grants `files.content.write` (first push 401s on a pre-Phase-5 token).

---

## Sequencing rationale
1. **Phase 3 (background sync)** — pure iOS, no paid account, completes the spec's download story. Do the ASCII-header fix here.
2. **Phase 4a (iPad)** — nearly free (already universal); good value before sync.
3. **Phase 5 (CloudKit progress sync)** — needs the paid account; do the schema-compat refactor first. Most valuable once there's a second device (iPad).
4. **Phase 4b (macOS Catalyst)** — gated on verifying Readium's Catalyst support; benefits from sync already existing.

Items 5 and 4b can swap depending on whether a Mac or sync matters more to you.

---

## Parallel agent orchestration (for a fresh session)

This codebase is now safe to build with **parallel agents** (it has commit history, an objective test gate, and clean module boundaries). Best practice:

### Isolation
- **Give each agent its own git worktree** (`isolation: "worktree"` on the Agent tool). Each agent runs its own `xcodegen generate` + `xcodebuild`, so there's no contention over the generated `.xcodeproj` / `build/` (this was the blocker that forced Phase 1 to be sequential — there were no commits then; now there are).
- The orchestrator (main session) owns the **merge + integration build + on-device verification**.

### Partition by disjoint file ownership
Shared/foundational files must have a **single owner** or be edited only by the orchestrator at integration: `Sources/Model/Models.swift`, `project.yml`, `Sources/App/RhapsodeApp.swift`, `Sources/App/RootTabView.swift`. If two agents both need one, that work is **not** parallel — serialize it or have the orchestrator land the shared change first (contract-first, like Phase 1's `LibrarySource`).

### What can run in parallel vs must serialize
- **First wave (parallel-safe, disjoint areas):**
  - **Agent A → Phase 3 (background sync):** `Sources/Sync/*`, a new `BackgroundDownloader`, a new `AppDelegate`, `DropboxSource.downloadRequest(...)`, the ASCII-header fix. Touches `project.yml` only for the AppDelegate adaptor — coordinate that one line with the orchestrator.
  - **Agent B → Phase 4a (iPad):** `Sources/App/*` layout (split view, adaptive grids). Mostly UI; disjoint from the Sync layer.
- **Serialize after the wave:**
  - **Phase 5 (CloudKit)** — starts with the schema-compat refactor to `Models.swift` (shared, foundational) + new `PlaybackProgress`; do it alone/first in its phase. Its write-point edits touch `AudiobookPlayer`/`EbookReader`.
  - **Phase 4b (macOS Catalyst)** — small, gated on verifying Readium Catalyst support.

### Brief every agent (fresh agents have zero context)
Each prompt must point at: `docs/SPEC.md`, this roadmap, and the two memory files — and restate the **Hard constraints** from the Status section above. Don't assume; the `Task { @MainActor }` and `@preconcurrency` rules in particular are non-obvious and caused real crashes.

### Acceptance gate (objective, per agent)
Every agent must, before declaring done: `xcodegen generate` → `xcodebuild ... build` succeeds → run the self-test (`-phase0selftest`) green, and **add new self-test checks** for new behavior. State the device-only caveat in each prompt so agents don't over-claim background/CloudKit/lock-screen as "verified" — those are the orchestrator's on-device step.

### Model
Sonnet builder agents are well-suited to these well-scoped implementation tasks (clear acceptance criteria + the self-test as the gate). Set `model: sonnet` per agent. Keep planning/integration/review in the orchestrator session.

### Kickoff prompt (paste into a fresh session)

```
Read docs/SPEC.md, docs/ROADMAP.md (especially "Status — resume here" and
"Parallel agent orchestration"), and the project memory files, then orchestrate
the post-MVP build.

First wave — launch these TWO Sonnet builder agents IN PARALLEL, each in its own
git worktree (isolation: "worktree", model: sonnet):

  • Agent A — Phase 3 (background sync): background URLSession (3a single-file
    first), AppDelegate for handleEventsForBackgroundURLSession, wire
    BGTaskScheduler (3c), and the ASCII Dropbox-API-Arg fix. Owns Sources/Sync,
    Sources/Source. Coordinate the one project.yml line (AppDelegate) with me.

  • Agent B — Phase 4a (iPad): adaptive layout (NavigationSplitView, wider grids,
    keyboard/pointer). Owns Sources/App UI.

Do NOT touch shared files (Models.swift, project.yml, RhapsodeApp.swift,
RootTabView.swift) without routing through me. Each agent must: obey the Hard
Constraints in the roadmap Status section (esp. Task { @MainActor } for framework
callbacks, @preconcurrency imports, read-only Dropbox, relative paths, no
.unique); build via `xcodegen generate` + xcodebuild for iphonesimulator26.5; run
the self-test (-phase0selftest) green; add new self-test checks for new behavior;
and NOT claim background/lock-screen behavior as verified (device-only — that's my
on-device step).

After both return: I merge the worktrees, run a unified build + self-test, resolve
any conflicts, and hand back for on-device verification. Then do Phase 5 (CloudKit
progress sync) SERIALLY — it refactors Models.swift — and Phase 4b (macOS Catalyst)
last. Do not parallelize Phase 5.
```


