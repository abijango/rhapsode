# Audiobook + E-book Player — MVP Build Spec

> Working title TBD. An app for listening to audiobooks and reading EPUBs, with files sourced from a Dropbox **App folder**. Built iOS-first (iPhone, then iPad/macOS via the shared SwiftUI codebase); Android is a planned later port (see Platform roadmap). Targeting eventual production publication, so all source-access decisions favour the narrowest scope and lightest review.

## Platform roadmap

1. **iPhone** — primary target, this spec.
2. **iPad / macOS** — same SwiftUI codebase, minimal extra work; not in MVP.
3. **Android** — later port. Not a recompile (SwiftUI/Apple frameworks don't run on Android), but the design is deliberately port-friendly: the Dropbox client is plain HTTP (re-implementable in Kotlin), the data model and domain logic copy over, and Readium has a sibling **Kotlin toolkit**. The UI (→ Jetpack Compose) and platform layers (audio → Media3/ExoPlayer, downloads → WorkManager, storage → Android Keystore) are a rewrite. If cross-platform sharing later becomes a goal, the path is Kotlin Multiplatform for the domain/data/source layers with native UI on each side.

## Constraints (read first — they shape the design)

- **Native SwiftUI**, iOS 26 styling (Liquid Glass). No web/cross-platform frameworks.
- **Offline-first.** Every file is downloaded fully and played/read from the local container. Nothing streams.
- **Dropbox via its HTTP API directly** (REST + OAuth2 PKCE). Do **not** use the Dropbox Swift SDK.
- **App-folder access only** (not Full Dropbox) — see Sources. The app reads and writes only within `/Apps/<AppName>/`.
- **No paid-entitlement features in the MVP** (no APNs push, no iCloud container), so the same build runs on a free provisioning profile during development. Used instead: local notifications, `BGTaskScheduler`, background `URLSession`. (A paid Apple Developer account is still required to ship to the App Store later — see the build guide.)
- Single-user, single-device assumption for now, but persistence must not block a later CloudKit sync (see Data Model).

## Tech stack

- SwiftUI + Swift Concurrency (`async`/`await`)
- SwiftData for persistence
- `AVPlayer` + `MPNowPlayingInfoCenter` / `MPRemoteCommandCenter` for audio
- [Readium Swift toolkit](https://github.com/readium/swift-toolkit) (SPM) for EPUB rendering
- Background `URLSession` for downloads; `UNUserNotificationCenter` for notifications
- Keychain for the Dropbox token

## App shape

A `TabView` with two tabs: **Audiobooks** and **E-books**, plus a **Settings** screen. Each tab shows a library/shelf (cover art + title) backed by SwiftData. Settings holds the Dropbox connection and the two watched-folder selections.

## Sources (why Dropbox App folder)

The source layer was chosen for the cleanest path to a **published** app that still keeps programmatic folder browsing + change detection + auto-download.

- **Dropbox, App folder — chosen.** Grants scoped access only to a dedicated `/Apps/<AppName>/` folder. The full API (`list_folder`, `longpoll`, `download`) works *within* that folder, so no feature is lost — users just keep their library in the app's folder rather than an arbitrary one. Production approval is a free one-time review, and requesting the narrow App-folder scope makes that review easier. Plain HTTP, so it ports to Android unchanged.
- **Dropbox, Full Dropbox — rejected for now.** Same features, but the production review scrutinises why whole-account access is needed. Only revisit if watching users' *pre-existing* arbitrary folders becomes essential.
- **Google Drive — set aside.** The folder-watch UX requires the *restricted* `drive.readonly` scope, which forces an annual paid third-party CASA security assessment (~$500+/yr) and is limited to qualifying app types. The cheap alternative (`drive.file` + Picker) is per-file only — no folder browsing or change detection, which defeats the feature. May be added later only as a manual-import secondary source.
- **iCloud / Files import — set aside.** Files integration can't list or watch arbitrary remote folders; `NSMetadataQuery` only watches the app's own iCloud container (a paid entitlement) and changes the UX to "put files in our folder."

**Path convention:** `/Apps/<AppName>/Audiobooks/` and `/Apps/<AppName>/Books/`. These are the two watched roots; the user does not pick arbitrary paths.



All remote access goes through one protocol so Dropbox is swappable later. The download/watch pipeline sits **above** this boundary and never knows the backend.

```swift
struct RemoteEntry { let id: String; let name: String; let path: String; let size: Int64; let isFolder: Bool }

protocol LibrarySource {
    func authenticate() async throws
    func listFolder(_ path: String) async throws -> [RemoteEntry]
    func changes(since cursor: String?) async throws -> (entries: [RemoteEntry], cursor: String)
    func longpoll(cursor: String) async throws -> Bool        // true if changes pending
    func download(_ entry: RemoteEntry, to destination: URL) async throws
}
```

MVP ships one conformer: `DropboxSource`, using `files/list_folder`, `files/list_folder/continue`, `files/list_folder/longpoll`, `files/download`. Scopes: `files.metadata.read`, `files.content.read`. App registered with **App folder** access; all paths are relative to the app folder root (Dropbox namespaces them automatically, so the API sees `/Audiobooks` and `/Books`).

## Data model (SwiftData)

Keep progress fields isolated and use stable `UUID`s; store **relative** container paths, never absolute URLs (so a future CloudKit sync is a toggle, not a rewrite).

- `Audiobook` — id, title, author?, coverPath?, sourcePath, ordered `[AudiobookTrack]`, `lastTrackIndex`, `lastOffsetSeconds`, totalDuration
- `AudiobookTrack` — id, title, fileRelPath, duration, order
- `Book` — id, title, author?, coverPath?, fileRelPath, `readingLocator` (Readium `Locator` JSON)
- `WatchedFolder` — id, kind (`.audiobooks` / `.books`), remotePath, cursor?
- `DownloadItem` — id, remoteEntryID, kind, state (`pending`/`downloading`/`done`/`failed`), bytesReceived, totalBytes

## Audiobook model rule (handle either format)

One `Audiobook` owns an ordered list of tracks:
- **M4B** → tracks come from `AVAsset` chapter metadata; the single file is shared by all tracks with chapter time ranges.
- **MP3 folder** → each file is a track, ordered by ID3 track number, filename sort as fallback.
- **Cover art** → embedded artwork; fallback to `cover.jpg` / `folder.jpg` in an MP3 folder.
- **Resume** is always `(lastTrackIndex, lastOffsetSeconds)` — identical for both formats.

## MVP features

**Audiobooks**
- Library shelf from downloaded books
- Player: play/pause, scrub, skip ±15/30s, playback speed, resume from last position
- Background audio + lock-screen / Control Center controls (`AVAudioSession` `.playback`; `UIBackgroundModes: audio` in Info.plist)
- Chapter/track list with tap-to-jump

**E-books**
- Library shelf
- Readium reader: paginated reflowable EPUB, font size, light/dark/sepia theme, TOC navigation, resume from last `Locator`
- System fonts only (custom fonts are post-MVP)

**Source + sync (Dropbox App folder)**
- Connect Dropbox (OAuth PKCE; token in Keychain)
- The two watched roots are fixed: `/Audiobooks` and `/Books` inside the app folder (no arbitrary folder picker). First connect creates them if missing.
- **Foreground auto-detect**: while the app is open, `longpoll` the two roots; on a new file, auto-download it
- Background `URLSession` downloads with a visible queue/progress
- **Local notifications** on download start and completion (title + which book)
- Manual "Scan now" button as the reliable fallback

## Explicitly OUT of MVP (do not build)

- Background detection while app is closed (`BGTaskScheduler` delta-check) — **Phase 2 fast-follow**
- Any second `LibrarySource` (iCloud, Google Drive, Files import)
- Custom/Google fonts, highlights, notes, in-book search, sleep timer, bookmarks
- PDF / CBZ / fixed-layout EPUB
- Cross-device sync, stats, collections, widgets, Siri
- Any server, webhook, or push

## MVP definition of done

Connect Dropbox → pick two folders → drop an M4B, an MP3 folder, and an EPUB into them on a laptop → with the app open, each auto-downloads, fires start + done notifications, and appears on the right shelf → play the audiobook (resumes correctly, controls work from the lock screen) → read the EPUB (resumes to last page).

## Suggested Claude Code agent plan

**Phase 0 — Foundation (sequential, one agent).** Everything else depends on this.
- Xcode project, SPM deps (Readium), `TabView` shell, Settings scaffold
- SwiftData models above + a thin `LibraryStore` repository
- Container path helpers (Application Support) + a small design-system file

**Phase 1 — Parallel (three agents, independent after Phase 0).**
- **Agent A — Dropbox source**: `LibrarySource` + `DropboxSource` (OAuth PKCE, Keychain, the four API calls). Mock conformer for the other agents to test against.
- **Agent B — Audiobook domain**: import/parse (M4B chapters + MP3 folder), `AVPlayer` engine, now-playing/remote commands, player UI + track list.
- **Agent C — E-book domain**: Readium integration, reader view, settings sheet (font size/theme), `Locator` persistence.

**Phase 2 — Integration (one agent).**
- Download + watch pipeline (background `URLSession` manager, foreground `longpoll` watcher, `UNUserNotificationCenter`) on top of `LibrarySource`
- Wire watched-folder selection in Settings; connect downloads → shelves
- Then the `BGTaskScheduler` background-detect fast-follow

**Conventions for the agents**
- A root `CLAUDE.md` pinning: HTTP-API-not-SDK for Dropbox, **App-folder access (paths relative to app folder, never Full Dropbox)**, Application-Support-not-Caches for files, relative-paths-in-SwiftData, no paid entitlements in the MVP.
- Agents B and C develop against Agent A's mock so they don't block on real OAuth.