# Audiobookshelf secondary library source (audio + e-books)

> **DO NOT IMPLEMENT.** Deferred. Active path: [`../rhapsode-server/`](../rhapsode-server/). See [`README.md`](./README.md) in this folder.

**Status:** DONOTIMPLEMENT (historical research)  
**Audience:** Reference only  
**Scope:** ~~ABS secondary backend~~ superseded by Rhapsode Server.

---

## 1. Goal

Let a user point Rhapsode at a self-hosted [Audiobookshelf](https://audiobookshelf.org/) server (e.g. on Synology) so that:

1. **Library catalog** comes from ABS (metadata only — cheap; multi‑GB libraries OK).
2. **Media download is selective** — user (or explicit rules) chooses titles; **never** auto-mirror the entire library.
3. Chosen **audio** files download in full into Application Support; play via existing SmartSpeech path.
4. Chosen **EPUBs** download in full; open via existing Readium reader.
5. **Resume / “where was I?”** for ABS-origin items lives on ABS:
   - Audiobooks: `currentTime` / `isFinished` (**source-domain** seconds)
   - E-books: `ebookProgress` / `ebookLocation` / `isFinished`
6. **Rhapsode extra stats** (SmartSpeech `savedSeconds`, cumulative `listenedSeconds` / `readingSeconds`, lifetime Nerd Stats, optional collections) sync via a **small JSON store on the NAS** (WebDAV or HTTPS), **not** via ABS schema and **not** requiring Dropbox for ABS users.
7. Design stays **portable** for a future Android client: same ABS APIs + same stats folder contract.

Dropbox remains available for dual-source / migration. ABS + NAS stats should be enough for a self-hosted user to drop Dropbox entirely later.

### Architecture (two channels)

```text
Synology NAS (example)
├── Audiobookshelf
│     ├── media libraries (multi-GB)
│     └── mediaProgress (resume per user)
└── /rhapsode-sync/          ← TINY JSON only (not an ABS library path)
      ├── stats.json
      └── items/… or extras.json

Rhapsode device
├── Catalog list (metadata)     ← always, lightweight
├── Selected downloads only     ← offline play/read
├── Resume                      ← ABS /api/me/progress
└── SmartSpeech / Nerd Stats    ← NAS rhapsode-sync (WebDAV/HTTPS)
```

| Concern | System of record |
|---------|------------------|
| Files (audio/EPUB) | ABS libraries |
| Resume position | ABS `mediaProgress` |
| SmartSpeech time saved, lifetime totals | **NAS `rhapsode-sync` folder** |
| Collections (optional) | NAS stats store (or later ABS collections mapping) |
| Social scrobble | Hardcover (separate spec) |

### Why e-books belong in this plan

ABS book items can carry audio, `ebookFile`, or both. Media progress stores audio + ebook fields on one row. Implement both shelves against ABS.

### Why stats are *not* only on ABS

Stock ABS does **not** model SmartSpeech silence reclaimed or Rhapsode Nerd Stats. Do **not** fork ABS for v1. Do **not** assume `extraData` round-trips client fields (optional spike only). Use the NAS JSON store instead.

---

## 2. Explicit non-goals

| Non-goal | Why |
|----------|-----|
| **Auto-download entire ABS library** | Multi-GB; wasteful; bad default. Catalog ≠ download. |
| Network streaming into SmartSpeech | Engine needs local seekable files. |
| SmartSpeechKit / live engine changes | Integration must not touch DSP. |
| Streaming EPUB without download | v1 offline-first. |
| Hard Dropbox cutover in first ship | Dual-source first. |
| Podcasts | v1: `mediaType == "book"` only. |
| ABS HLS / transcode play path | Original file download only. |
| Forking ABS / upstream schema for SmartSpeech | NAS stats store instead. |
| Non-EPUB ebooks in v1 | Readium/EPUB only. |
| Putting `rhapsode-sync` **inside** an ABS scanned media folder | ABS may try to index it — keep outside library paths. |

---

## 3. Current architecture (bind here)

| Piece | Path | Role |
|-------|------|------|
| Source protocol | `Sources/Source/LibrarySource.swift` | Dropbox-shaped folder API |
| Dropbox | `DropboxSource`, `DropboxProgressSync` | Media + JSON stats today |
| Progress protocol | `Sources/Sync/ProgressSync.swift` | `PlaybackProgress` (incl. `savedSeconds`, `listenedSeconds`, `readingSeconds`), `SmartSpeechStatsRecord`, collections |
| Models | `Audiobook`, `Book` | Local resume + per-book stats fields |
| Player / reader | `AudiobookPlayer`, `EbookReader` | Accrue stats; push hooks |
| Live engine | `Sources/SmartSpeechLive/*` | **Do not modify** |

Reuse the **wire shapes** already in `ProgressSync` / `SmartSpeechStatsRecord` for the NAS store (same merge rules: monotonic `max` for cumulative fields, LWW where appropriate).

---

## 4. Product behavior (v1)

### 4.1 Settings

**Audiobookshelf**

- Server URL, username/password or API token  
- Connect / Disconnect / Test  
- Toggles: use ABS for audiobooks / e-books (or one combined toggle)

**Rhapsode stats store (NAS)** — required for full cross-device Nerd Stats when using ABS

- Enable **Stats backup**  
- Protocol: **WebDAV** (recommended) or HTTPS base URL with basic auth  
- Base URL (e.g. `https://nas.example/rhapsode-sync/` or WebDAV path)  
- Username / password (prefer a Synology user with **only** that folder RW)  
- Test: write+read a tiny probe file  
- Help copy: *“Store SmartSpeech and lifetime stats on your NAS (same machine as ABS). Keep this folder outside your audiobook libraries.”*

**Dropbox**

- Still optional. If ABS media + NAS stats are configured, Dropbox is not required for ABS-origin items.  
- Dropbox-origin items keep using Dropbox progress/stats until migrated.

### 4.2 Catalog sync vs media download (critical)

These are **separate** pipelines.

#### Catalog sync (default, automatic)

- `GET /api/libraries` + paginated `GET /api/libraries/:id/items`  
- Cache metadata + cover thumbs as needed  
- Show items as **Not on device** / **Downloaded**  
- Pull ABS progress for “Continue listening/reading” **without** downloading media  
- **Does not** pull multi-GB audio  

#### Media download (explicit / selective only)

Triggers (v1):

| Trigger | Behavior |
|---------|----------|
| User taps **Download** on an item | Queue that item’s audio and/or EPUB |
| User multi-select download | Queue selection only |
| Optional later: “Download next in series” / Wi‑Fi-only | Rules must be opt-in and size-aware |
| **Forbidden default** | “Download all” of entire library with no confirmation + size estimate |

After download → import (`AudiobookImporter` / `EbookImporter`) → local play/read.

Delete download → free device storage; **ABS progress and NAS stats remain**.

### 4.3 Download endpoints (full file of selected items only)

| Media | Endpoint |
|-------|----------|
| Audio | `GET /api/items/:id/file/:fileid/download` |
| Ebook | `GET /api/items/:id/ebook` (+ optional `/:fileid`) |
| Cover | `GET /api/items/:id/cover` |

Rules: `permissions.download`; Application Support + relative paths; BackgroundDownloader; never remote URLs into SmartSpeech/Readium as sole source.

### 4.4 Playback & reading

Unchanged engines. Audio positions **source-domain** only.

### 4.5 Resume progress (ABS channel)

| Local | ABS |
|-------|-----|
| Source seconds / track offsets | `currentTime`, `duration`, `isFinished` |
| Readium locator + `totalProgression` | `ebookLocation` (codec), `ebookProgress`, `isFinished` |

- Merge-safe updates when one library item has both audio + ebook.  
- Codec: `ABSEbookLocationCodec` (document format; tests).  
- Push on pause / background / finish; pull on launch / foreground / open item.

**ABS is source of truth for resume** for `sourceBackend == audiobookshelf`.

### 4.6 Rhapsode extra stats (NAS `rhapsode-sync` channel)

#### What goes here (not on ABS)

| Data | Notes |
|------|--------|
| Per-item `savedSeconds` | SmartSpeech silence reclaimed |
| Per-item `listenedSeconds` | Cumulative content listened (Rhapsode definition) |
| Per-item `readingSeconds` | Foreground ebook time |
| Lifetime `SmartSpeechStatsRecord` | Global saved + played |
| Optional collections manifests | Same as Dropbox collections sync |

#### Folder layout (contract)

Keep **outside** ABS media library paths, e.g. `/volume1/rhapsode-sync` on Synology:

```text
rhapsode-sync/
  stats.json                 # SmartSpeechStatsRecord
  extras.json                # map absLibraryItemId → per-item extras
  # OR extras/<libraryItemId>.json  (either OK; pick one and stick to it)
  collections-audiobooks.json
  collections-books.json
```

**`stats.json`** — same fields as existing `SmartSpeechStatsRecord`:

```json
{
  "savedSeconds": 90000,
  "playedSeconds": 400000,
  "updatedAt": "2026-07-10T12:00:00Z"
}
```

**`extras.json`** (recommended single-file map for small libraries):

```json
{
  "v": 1,
  "updatedAt": "2026-07-10T12:00:00Z",
  "items": {
    "li_abc123": {
      "savedSeconds": 1820,
      "listenedSeconds": 12040,
      "readingSeconds": 0,
      "kind": "audiobook",
      "updatedAt": "2026-07-10T12:00:00Z"
    }
  }
}
```

Join key: **`absLibraryItemId`** for ABS-origin items. (Dropbox-origin items may keep Dropbox keys if dual-source.)

#### Transport: WebDAV (recommended) or HTTPS

Implement `NasStatsStore` / `WebDAVProgressSync`-style client:

- Auth: basic (or digest if required) over **HTTPS**  
- `GET` / `PUT` (WebDAV PUT) of JSON files  
- Create parent path if needed (`MKCOL` for WebDAV)  
- User-Agent: `Rhapsode/iOS (nas-stats)`  
- Keychain: `rhapsodeStats.baseURL`, `rhapsodeStats.user`, `rhapsodeStats.password`

Settings should allow the **same host** as ABS with a **different path** (typical Synology setup).

#### Merge rules (mandatory)

When pulling/pushing stats:

| Field | Merge |
|-------|--------|
| `savedSeconds`, `listenedSeconds`, `readingSeconds`, lifetime totals | **`max(local, remote)`** (monotonic) |
| `updatedAt` on records | Bump on local change; use for overall file LWW only when not field-wise max |
| Resume fields | **Not in this store** — ABS owns them |

Read-before-write: GET → merge → PUT. On 412/conflict, re-GET and retry once.

#### When to sync stats

- Accrual remains local (player/reader) as today  
- Push stats store: pause, background, finish, periodic (throttled)  
- Pull: launch, foreground, before showing Nerd Stats  

If stats store is **not** configured: stats stay device-local; UI should say cross-device SmartSpeech history needs stats backup (NAS or Dropbox).

### 4.7 Identity (SwiftData)

| Field | On | Purpose |
|-------|-----|---------|
| `sourceBackend` | Audiobook, Book | `dropbox` / `audiobookshelf` |
| `absLibraryItemId` | both | Progress + stats join key |
| `absLibraryId` | both | Optional |
| `downloadState` / flags | both | on-device vs catalog-only |
| Track/ebook file ids | as needed | re-download |

Catalog-only rows (metadata without local files) are allowed so Continue works before download.

### 4.8 Cross-platform

```text
Any Rhapsode client
  ├─ ABS: catalog, selective download, resume
  └─ NAS rhapsode-sync: SmartSpeech + lifetime stats (same JSON contract)
```

No iOS-only assumptions in clients (HTTP + JSON + file cache).

---

## 5. API notes

### ABS

- Auth: `POST /login`, Bearer token  
- Catalog: libraries + items  
- Files: per-file / ebook download  
- Progress: `GET/PATCH /api/me/progress/:libraryItemId`  
- Docs: https://api.audiobookshelf.org/ (verify if stale)

### NAS stats store

- WebDAV class 1/2 as supported by Synology, **or** HTTPS PUT/GET to a reverse-proxied folder  
- Not part of ABS API  
- Folder must not be an ABS library root  

---

## 6. Protocol design guidance

### Catalog + selective download

```swift
protocol CatalogLibrarySource: Sendable {
    func authenticate() async throws
    func listBookItems() async throws -> [RemoteCatalogItem]  // metadata only
    func downloadAudio(_ item: RemoteCatalogItem, to directory: URL) async throws -> [URL]
    func downloadEbook(_ item: RemoteCatalogItem, to destination: URL) async throws -> URL
    func downloadCover(_ item: RemoteCatalogItem, to destination: URL) async throws -> URL?
}
```

`SyncManager` (or successor):

- **Refresh catalog** ≠ **enqueue all downloads**  
- Download queue only for user-selected (or rule-selected) item IDs  

### Progress (ABS)

```swift
func pushAudioResume(libraryItemId:currentTime:duration:isFinished:)
func pushEbookResume(libraryItemId:ebookProgress:ebookLocation:isFinished:)
func pullResume(libraryItemId:)
```

### Stats (NAS)

Conform to existing `ProgressSync` **stats/collections** methods (`pushStats` / `pullStats` / collections) via a new `NasWebDAVStatsSync` (or implement a dedicated `RhapsodeStatsSync` protocol if cleaner). Per-item extras can extend `push` with keys `abs:<libraryItemId>` or a dedicated API.

**Do not** implement SmartSpeech fields by forking ABS.

---

## 7. Files likely touched

```
Sources/Source/AudiobookshelfClient.swift
Sources/Source/AudiobookshelfSource.swift
Sources/Source/KeychainTokenStore.swift
Sources/Sync/AudiobookshelfProgressSync.swift      # resume only
Sources/Sync/NasWebDAVStatsSync.swift              # NEW — stats JSON on NAS
Sources/Sync/ABSEbookLocationCodec.swift
Sources/Sync/SyncManager.swift                     # catalog vs download split
Sources/Sync/BackgroundDownloader.swift
Sources/Model/Models.swift
Sources/Audiobook/*
Sources/Ebook/*
Sources/App/SettingsView.swift                     # ABS + stats store sections
project.yml
```

**Do not modify:** `Sources/SmartSpeechLive/**`, `SmartSpeechKit/**`

---

## 8. Security

- ABS token and WebDAV credentials in Keychain; never logs.  
- HTTPS preferred for both; cleartext LAN only with explicit risk.  
- Stats user: least privilege on `rhapsode-sync` only.  
- Stats files are private (listening habits) — same care as progress JSON.

---

## 9. Testing

| Layer | What |
|-------|------|
| Catalog | Large fixture item list does **not** enqueue downloads |
| Selective download | Only selected id hits file endpoints |
| Resume | ABS currentTime / ebookProgress without local file still shows Continue |
| Stats | WebDAV put/get round-trip; max-merge for savedSeconds across two “devices” (mock) |
| Dual medium | Audio + ebook progress don’t clobber |
| Regression | Dropbox path still works; SmartSpeech code untouched |
| Manual | Real ABS on Synology + WebDAV folder; download one book; play with SmartSpeech; second device sees resume + saved time |

---

## 10. Acceptance criteria

1. Catalog sync does **not** download the whole library.  
2. User can download **one** audiobook and **one** EPUB selectively.  
3. SmartSpeech plays local audio; no engine file changes.  
4. Resume syncs via ABS (source-domain audio; ebook codec).  
5. With NAS stats store configured, SmartSpeech `savedSeconds` + lifetime totals survive reinstall / second device.  
6. Without stats store, app still works; stats remain local (clear UX).  
7. Dual-format items don’t wipe sibling progress fields.  
8. Dropbox still works for non-ABS users.  
9. `rhapsode-sync` documented as outside ABS library paths.

---

## 11. PR Plan (suggested DAG)

### PR 1: ABS HTTP client + Keychain

- Login, list libraries/items, download URL builders (file + ebook). No bulk download.  
- **Dependencies:** None  

### PR 2: Catalog sync + on-device flags (no auto-download)

- List metadata into shelf as not-downloaded; covers optional.  
- **Dependencies:** PR 1  

### PR 3: Selective audio download + import

- Download action → queue one item → `Audiobook` + abs ids.  
- **Dependencies:** PR 2  

### PR 4: Selective ebook download + import

- EPUB only; skip other formats.  
- **Dependencies:** PR 2  

### PR 5: ABS resume progress (audio + ebook)

- Push/pull resume; merge-safe dual medium; codec.  
- **Dependencies:** PR 3, PR 4  

### PR 6: NAS WebDAV (or HTTPS) stats store

- Settings UI; `NasWebDAVStatsSync`; `stats.json` + per-item extras; max-merge; wire player/reader accrual to push/pull.  
- **Dependencies:** PR 1 (can parallel with PR 3–5 once Keychain patterns exist; functionally needs abs ids from PR 3–4 for keys)  
- **Practical deps:** PR 3 (absLibraryItemId on audiobooks) for meaningful per-item keys  

### PR 7: Settings polish + dual-source + docs in UI

- ABS + stats store copy; disconnect policies; source badges; size warning if user selects multi-download.  
- **Dependencies:** PR 5, PR 6  

**Parallelism:** PR 3 ∥ PR 4 after PR 2; PR 6 can start after PR 3 for keys (ebook keys after PR 4).

---

## 12. Defaults for open questions

| Decision | Default |
|----------|---------|
| Whole-library download | **Off**; never implicit |
| Stats transport | **WebDAV over HTTPS** on NAS |
| Stats path | Outside ABS libraries (`rhapsode-sync`) |
| SmartSpeech on ABS schema | **No** (v1) |
| `extraData` on ABS progress | Optional spike only; not required |
| Dual source with Dropbox | Yes |
| Non-EPUB | Skip |
| Podcasts | Skip |

---

## 13. Synology operator notes (for implementer docs / Settings help)

1. Create folder share e.g. `rhapsode-sync` **not** under audiobook/ebook library paths.  
2. Create a user with RW only on that folder.  
3. Enable WebDAV (or reverse-proxy HTTPS to that folder).  
4. Use the same reachability path as ABS (LAN / VPN / Tailscale / reverse proxy).  
5. In Rhapsode: set ABS URL + stats WebDAV URL (may share host, different path).

---

## 14. References

- ABS API: https://api.audiobookshelf.org/  
- Ebook: `GET /api/items/:id/ebook`  
- Progress: `currentTime`, `ebookProgress`, `ebookLocation`, `isFinished`  
- Rhapsode stats shapes: `Sources/Sync/ProgressSync.swift` (`PlaybackProgress`, `SmartSpeechStatsRecord`)  
- Orchestration: `specs/integrations/agent-orchestration-playbook.md`  
- Hardcover (listen scrobble only): `specs/integrations/hardcover-progress-scrobble.md`  
