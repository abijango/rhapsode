# Cloudflare Backend Migration — Implementation Plan

> **Full research/findings:** https://claude.ai/code/artifact/fea934f7-59fb-4e29-a7e8-34342a51a4e9
> That artifact is the research memo (backend comparison, CadenceKit portability investigation, Synology/Rust/Python spikes, cost analysis). This document is the actionable plan derived from it — read the artifact for *why*, this file for *what to build and in what order*.
>
> **Decision made:** Cloudflare R2 + Workers + D1. CadenceKit stays exactly as it is (Swift/AVFoundation/Accelerate, unchanged). The Rust/Python portability spike and the Synology LAN-render idea are explicitly **out of scope for this plan** — they're independent, deferred investigations; see the artifact.

---

## 0. Sequencing (locked)

Two stages, in order. Stage 2 cannot usefully start until Stage 1's Worker/R2/D1 contract exists and has been exercised for real, because Stage 2's consumer-side code is validated against exactly what Stage 1 produces.

1. **Stage 1 — Mac companion app.** A new, standalone macOS app: renders with CadenceKit, uploads to Cloudflare, and monitors Cloudflare usage in-app. Does **not** touch the existing Rhapsode app or its Dropbox integration at all.
2. **Stage 2 — Rewrite Rhapsode.** Swap Rhapsode's storage/sync layer from Dropbox to the new backend; Rhapsode becomes consumer-only (see §3 for why this is a simplification, not a lateral move).

A small **Stage 0** (backend foundation) has to exist before Stage 1 can be exercised end-to-end — it's not a separate phase so much as the first piece of Stage 1's own work.

---

## 1. Stage 0 — Backend foundation

New top-level `backend/` directory in this repo (TypeScript, Wrangler-managed — a separate toolchain from the Swift app, same monorepo).

- **Cloudflare account + R2 bucket.** One-time manual setup (dashboard).
- **Worker** (`backend/src/`): bearer-token auth on every request; endpoints for:
  - `POST /uploads` → mints a presigned R2 PUT URL for a given key (audio artifact, sidecar JSON, cover). Client uploads directly to R2, bypassing the Worker for the large transfer.
  - `GET /downloads/:key` → presigned GET URL.
  - `DELETE /objects/:key` → deletes from R2 (idempotent — missing key is not an error).
  - `GET /usage` → wraps Cloudflare's `GET /accounts/{id}/r2/metrics` (lighter than the full GraphQL Analytics API for this purpose) and returns a simple `{ storageBytes, standardBytes, infrequentAccessBytes, classAOpsThisMonth, classBOpsThisMonth }` summary. Cloudflare disclaims this for billing accuracy — surface it as an approximate figure, not a precise gate.
  - `GET /sync/state` / `PUT /sync/state` → D1-backed progress + render-registry read/write, preserving the read-before-write last-write-wins guard the current `DropboxProgressSync` already implements (`Sources/Sync/DropboxProgressSync.swift:19-31`).
  - `GET /sync/changed-since?cursor=` → replaces Dropbox's longpoll; clients poll this on foreground instead of blocking on a longpoll connection.
  - `GET /stats/aggregate` → **new, for Nerd Stats (see §4).** `SELECT SUM(render_duration_seconds), SUM(saved_seconds), COUNT(*) FROM render_registry`. This is the *global* render-time total — computed from the table, not tracked as a separately-incremented counter. Single source of truth, no merge logic, no double-counting risk if an upload retries (insert is an upsert keyed on the same deterministic `content_hash + tier + versions` key the artifact filename already uses).
- **D1 schema** (`backend/migrations/`): `progress` (book_id, position, updated_at, device_id, **cadence_saved_seconds** — see §4), `render_registry` (content_hash, tier, artifact_key, created_at, **render_duration_seconds, saved_seconds** — populated straight from the sidecar the Mac app already uploads, no extra round-trip), `library_index` (a single monotonic `last_changed_at` for the changed-since poll), `stats` (a single row: `lifetime_saved_seconds`, `updated_at` — the one figure that's still genuinely multi-writer; see §4).
- **Secrets** (`wrangler secret put`): R2 S3-API credentials (data-plane), an app-facing bearer token, a Cloudflare API token scoped for the usage endpoint. Keep these three separate — never let the app-facing bearer token double as an R2 or Analytics credential.
- **Deploy:** `wrangler deploy` from `backend/`.

**Verification:** `curl` the Worker directly (upload → presigned PUT → confirm object exists via `GET /usage` bytes delta → delete → confirm gone) before writing a single line of Mac app code. This de-risks Stage 1 against Worker bugs before a GUI is in the loop.

---

## 2. Stage 1 — Mac companion app

New Xcode target in this repo's `project.yml` (XcodeGen — see §5 for build mechanics), e.g. `CadenceUploader`, source under `Sources/CadenceUploader/`. Links the existing local `CadenceKit` package (already liftable/standalone per `CLAUDE.md`) — no changes to CadenceKit itself.

### WP1.1 — Render pipeline (own copy, not shared with Rhapsode's coordinator)
Watches a local "Originals" folder, renders each new/changed file with CadenceKit directly (no SwiftData, no `Audiobook` model — this app operates on plain files). Output goes to a permanent local "Rendered" folder (not a cache — this app *is* the durable archive per the design decided in the artifact). Write a metadata sidecar per render, reusing the shape already defined in `Sources/Cadence/RenderedArtifact.swift` (`RenderedArtifactSidecar`): title/author/cover ref, source content hash, tier, analyzer/renderer versions, durations, timeline map, chapters. Content hash: plain whole-file SHA-256 (Dropbox's `content_hash` is gone; no need to replicate its 4MiB-block scheme unless you want it — a simple hash is fine since this is the new source of truth).

### WP1.2 — Upload, decoupled from render
One upload action, three possible sources: (a) a fresh render's output, (b) an existing entry in the local Rendered folder, (c) a user-picked file via a file picker. All three funnel into the same upload call: request a presigned PUT from the Worker, push the audio + sidecar + cover to R2, confirm via a verify-before-proceed check (adapt the pattern in `Sources/Cadence/RenderProducer.swift:20-39` — audio confirmed first, then sidecar, then cover). Unlike the old Dropbox producer flow, **there is no destructive delete step here** — nothing local ever gets removed by an upload; the Mac keeps both the original and the render regardless.

### WP1.3 — Usage monitoring
A view that calls the Worker's `/usage` endpoint and shows current storage against the free-tier threshold, with a pre-upload warning banner if the upload would push past it (approximate, per the billing-accuracy caveat above — a heads-up, not a block).

### WP1.4 — Manual remove-from-backend
A delete action in this same app (calls the Worker's `DELETE /objects/:key` for the audio + sidecar + cover). This gives you a complete render → upload → monitor → delete loop entirely within the new Mac app, provable before Rhapsode is touched at all.

### WP1.5 — Live render stats, and posting them as part of the upload (not a separate sync)
While a render runs, show live stats in the app: elapsed wall-clock time, which chapter/chunk is being processed, running saved-seconds tally. Reuse the existing `onProgress` callback mechanism already built for `CadenceRenderCoordinator`'s render-status bar (weighted by file duration, hopped off the render actor) — same idea, just hosted in this app instead. This is local UI only, no backend involved.

The render-completion stats (`renderDurationSeconds`, `savedSeconds`, `projectedSavedByTier`) already live in the sidecar (`RenderedArtifactSidecar` — WP1.1) that WP1.2 uploads. **Don't build a separate "push stats" call.** The Worker derives the `render_registry` row (§1) straight from the sidecar it just received. This is a deliberate simplification versus the current Dropbox-era design, where `CadenceStats.totalRenderSeconds` is a client-maintained lifetime counter synced by last-write-wins (`Sources/Cadence/CadenceStats.swift`, `CadenceStatsRecord`/`pushStats`/`pullStats` in `Sources/Sync/ProgressSync.swift:44-56`) — that pattern made sense with no database to aggregate from, but now that a real table exists, summing it server-side (§1's `/stats/aggregate`) is strictly more robust: no merge logic to write in this new app, no risk of the counter drifting from what's actually in R2.

**Verification:** CadenceKit `swift test` stays green (it's untouched). Manual round-trip against the real Worker/R2/D1 with a disposable test audiobook: render, upload, confirm the sidecar downloads and matches what Stage 2's importer will expect (§3, WP2.4), delete, confirm usage numbers move.

---

## 3. Stage 2 — Rewrite Rhapsode

**Key simplification, decided in this plan:** Rhapsode drops the producer role entirely, everywhere — iPhone, iPad, *and* Mac. The Mac companion app is now the sole renderer. This was already anticipated as a seam: the earlier producer/consumer work's own notes say "the producer pipeline... is the part that lifts into a standalone macOS tool... keep producer logic cohesive so extraction is a move, not a rewrite." This migration executes that move. Concretely, `RenderRolePreferences`, `CadenceRenderCoordinator`'s render-on-import triggers, and `RenderProducer` become dead code in Rhapsode and get deleted (WP2.5) — Rhapsode only ever plays what the companion app uploaded.

### WP2.1 — `R2Source: LibrarySource`
New `Sources/Source/R2Source.swift`. Implements the existing protocol (`Sources/Source/LibrarySource.swift:34-58`): `authenticate()`, `listFolder()`, `changes()`, `download()`, `ensureFolderExists()`, `latestCursor()`. `longpoll()`'s Dropbox semantics are replaced by polling the Worker's `GET /sync/changed-since` on app foreground.

### WP2.2 — `R2ProgressSync: ProgressSync`
New `Sources/Sync/R2ProgressSync.swift`, implementing `Sources/Sync/ProgressSync.swift:59-78` against the Worker's `/sync/state` endpoints. Preserve the exact read-before-write LWW guard from `DropboxProgressSync.push` (`Sources/Sync/DropboxProgressSync.swift:19-31`) — this is the one piece of logic that must not regress.

### WP2.3 — Fix the two casting sites
`BackgroundDownloader`/`SyncManager` currently do `if let dbx = source as? DropboxSource` to reach `downloadRequest()`/`readFile()`, which aren't on the `LibrarySource` protocol. Add them as protocol methods (or a small `LargeFileDownloadCapable` sub-protocol) so `R2Source` slots in without a cast. (Call sites: `SyncManager.process:561`, `SyncManager.processRenderedSidecar:301-302`.)

### WP2.4 — Reuse `ConsumerImporter` almost as-is
`Sources/Cadence/ConsumerImporter.swift` already builds a playable `Audiobook` + tracks + external `TrimmedRendition` from a sidecar JSON + downloaded artifact, with no original present — this is exactly Stage 2's consumer path, already written and tested against the Dropbox-based producer/consumer flow. Repoint it at R2-downloaded sidecars. Low risk: the sidecar shape (WP1.1) is deliberately unchanged from `RenderedArtifactSidecar`.

### WP2.5 — Delete the producer path from Rhapsode
Remove `RenderRolePreferences`, `CadenceRenderCoordinator`'s enqueue-on-import wiring, and `RenderProducer` from the app target (they move to `CadenceUploader` in spirit, but don't literally share code unless you choose to extract a shared package later — not required now). Audit call sites in `RhapsodeApp.swift`, `BackgroundDownloader`, `SyncManager`.

### WP2.6 — Delete-from-device-and-backend UI
A context-menu action on a finished book (shelf or `PlayerView`) that calls the Worker's delete endpoint and evicts the local external-artifact copy on that device. Safe by construction — the Mac companion still has the original and the render.

### WP2.7 — Nerd Stats (per-book + global panels)
See §4 for the full data-flow picture; this WP is the Rhapsode-side UI plus the one schema extension it needs.

- **Extend `PlaybackProgress`** (`Sources/Sync/ProgressSync.swift`) with `cadenceSavedSeconds: Double?`, stamped and synced with the exact same LWW-by-`updatedAt` mechanism already covering `lastOffsetSeconds`. Today `Audiobook.cadenceSavedSeconds` only accrues from whichever device is currently playing — this closes the gap so "time saved so far" is correct regardless of which device did the listening.
- **Per-book Nerd Stats panel** (new view, surfaced from `PlayerView` or the shelf detail): "time saved from rendering" = `TrimmedRendition.savedSeconds` (already populated by `ConsumerImporter` from the sidecar), "time saved so far" = the now-cross-device-synced `Audiobook.cadenceSavedSeconds`, "render took" = `TrimmedRendition.renderDurationSeconds` (already an existing field — just needs a UI reading it, since it's currently only consumed internally for the lifetime counter).
- **Global Nerd Stats panel** (new view, from `SettingsView`'s Cadence section, alongside the existing `CadenceTimeSavedCard`): "total time spent rendering across the library" from the Worker's `GET /stats/aggregate` (§1/§4 — server-computed from `render_registry`, not a synced counter); "total time saved from listening" from the `stats` table's single LWW row (carries forward `CadenceStatsRecord`'s existing saved-seconds half unchanged — only the render-seconds half of that record is being replaced by the aggregate query).

### WP2.8 — Dropbox cutover
Recommendation: don't delete Dropbox code in the same pass as the swap. Keep `DropboxSource`/`DropboxProgressSync`/`DropboxOAuth` in the tree but unused (feature-flagged off) until the R2 path has been exercised end-to-end on real devices for at least one full read-through of a book. Remove them in a follow-up cleanup PR once you trust the new path — this keeps a rollback available during the riskiest window.

**Verification:**
- Build: `xcodebuild -project Rhapsode.xcodeproj -scheme Rhapsode -sdk iphonesimulator26.5 -destination 'generic/platform=iOS Simulator' -derivedDataPath build -clonedSourcePackagesDirPath build/SourcePackages build` (see §5 for gotchas).
- iOS-sim self-test (`-phase0selftest 1`): `PhaseZeroSelfTest.run` currently forces `.producer` role for test purposes — once the producer role is gone from the app (WP2.5), that forcing is dead code too; update the harness alongside WP2.5, don't leave it forcing a role that no longer exists.
- Manual two-device test: Mac companion renders + uploads a disposable test book → Rhapsode on a fresh simulator/device pulls it, plays it, chapters/progress correct → progress syncs back → delete-from-device-and-backend round-trips cleanly (backend copy gone, Mac companion's local copy untouched).

---

## 4. Nerd Stats — data flow at a glance

Four figures, two genuinely different mechanisms. Don't force all four through one pattern.

| Figure | Scope | Writer(s) | Mechanism |
|---|---|---|---|
| Time saved from rendering | per-book | Mac companion, at render time | Already in the sidecar (`RenderedArtifactSidecar.savedSeconds`) → `TrimmedRendition.savedSeconds` via `ConsumerImporter`. No new plumbing. |
| How long rendering took | per-book | Mac companion, at render time | Same path: sidecar `renderDurationSeconds` → `TrimmedRendition.renderDurationSeconds`. Already an existing field — WP2.7 just reads it into a UI. |
| Time saved so far (this book, from listening) | per-book | **any** device currently playing it | `Audiobook.cadenceSavedSeconds`, extended onto `PlaybackProgress` (WP2.7) and synced with the same LWW-by-`updatedAt` guard as position. Multi-writer, so LWW is the right tool — same reason it's already used for position. |
| Total render time across the whole library | global | Mac companion only (single writer) | **Not** a synced counter. `GET /stats/aggregate` (§1) sums `render_registry` server-side. Single writer + a real table beats a hand-merged counter — no LWW needed at all here. |
| Total time saved across the whole library | global | any device | The `stats` table's one LWW row (§1), carrying forward `CadenceStatsRecord`'s existing saved-seconds behavior unchanged, just repointed at the Worker instead of Dropbox. |

The dividing line: **single-writer figures (render stats) get aggregated from a table; multi-writer figures (listening stats) keep the existing LWW-blob pattern.** Don't build a merge path for data that only one process ever produces — that's the mistake this design avoids.

---

## 5. Build mechanics (carry over from existing project conventions)

- XcodeGen, not a checked-in `.xcodeproj`. Adding the `CadenceUploader` target means editing `project.yml`, then `xcodegen generate` — required after *any* new source file, not just target changes.
- Use `-scheme`, not `-target`, in `xcodebuild` calls (a `-target` build hits a spurious `Minizip.modulemap not found` error in Readium's SPM graph).
- The `Rhapsode` scheme is a **shared** scheme via a top-level `schemes:` block in `project.yml` — give `CadenceUploader` the same treatment, or `xcodegen generate` will only emit a user scheme that a clean checkout won't have.
- SourceKit/editor squiggles in this repo are unreliable after cross-file edits (index lag) — trust `xcodebuild`'s `** BUILD SUCCEEDED **`, not IDE diagnostics.

## 6. Explicitly deferred (not part of this plan)

- **Usage-warning approximation tightening / archive-to-Infrequent-Access.** WP1.3 ships the basic warning; true "archive anything untouched in N days" needs app-tracked last-access (R2's native Lifecycle Rules only do age-since-upload) — fine as a fast-follow once the backend is live and actually holding content.
- **Rust/Python CadenceKit portability spike, Synology LAN renderer.** Fully out of scope here — independent tracks, see the artifact.
- **React/web ingest console.** Not needed to hit the two stages above; the Mac companion app *is* the ingest tool for Stage 1. Revisit only if a non-Mac uploader becomes a real requirement.
