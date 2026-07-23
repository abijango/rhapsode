# Ebook reader migration plan

**Status:** Path 1 complete + **Path 3 (KOSync) landed** (3a–3c). Manual CrossInk/device check (3d) pending  
**Date:** 2026-07-17  
**Context:** Readest’s smoothness comes from **foliate-js** owning pagination inside one web view. Rhapsode’s old Readium navigator path fought multi-`WKWebView` spreads with JS `scrollLeft` hacks — removed in 1c. KOReader sync is a separate protocol (partialMD5 + XPointer).

---

## Goals

1. **Page turns feel instant** (no poll loops, no “find visible WKWebView”).
2. **Reliable resume** via CFI / fraction (and later XPointer for KOSync).
3. **KOReader Progress API** for ebook position (plan E in NAS SMB).
4. Keep audiobook + SmartSpeech + library sources unchanged.

Non-goals for this migration: full annotation UI, PDF/MOBI, TTS, Readest cloud.

---

## Path 1 — Embed foliate-js (primary)

### Architecture

```
SwiftUI ReaderView
  └── FoliateWebReader (@Observable)
        └── WKWebView
              ├── rhapsode://reader/*  → bundled shell + foliate-js (ES modules)
              └── rhapsode://book/*    → on-disk EPUB bytes
        bridge: next/prev/goTo/setStyles ↔ relocate/toc/error
```

| Piece | Responsibility |
|-------|----------------|
| `SupportingFiles/ReaderWeb/` | `index.html`, `bridge.js`, CSS for host chrome hole |
| `Vendor/foliate-js/` | Upstream renderer (git clone / submodule) |
| `FoliateSchemeHandler` | Serve bundle + current book with correct MIME types |
| `FoliateWebReader` | Open book, page turns, settings, TOC, progress JSON |
| `ReaderView` | Chrome (toolbar, settings sheet, edge taps) — same UX as today |

### Position format

Persist in `Book.readingLocator` (reuse column; document new shape):

```json
{
  "engine": "foliate",
  "cfi": "epubcfi(...)",
  "locations": { "totalProgression": 0.42 }
}
```

- `Book.fractionComplete` already reads `locations.totalProgression` via `JSONSerialization` — no model change required for shelf progress.
- **Migration:** if `readingLocator` is a Readium Locator (has `href` + `locations` without `engine: foliate`), resume with `goToFraction(totalProgression)` only (CFI is not portable). First full re-read rewrites Foliate CFI.

### Bridge protocol (JS ↔ native)

**Native → JS** (`window.__rhapsode`):

| Message | Payload |
|---------|---------|
| `open` | `{ name }` (bytes via `rhapsode://book/…`) + optional `{ cfi \| fraction }` |
| `next` / `prev` | — |
| `goTo` | `{ cfi }` or `{ href }` or `{ fraction }` |
| `setStyles` | `{ theme, fontSize, fontFamily }` |
| `getTOC` | — (or TOC pushed on open) |

**JS → native** (`webkit.messageHandlers.rhapsode`):

| Type | Payload |
|------|---------|
| `ready` | — |
| `opened` | `{ title?, toc: [{ label, href }] }` |
| `relocate` | `{ cfi, fraction, sectionLabel? }` |
| `error` | `{ message }` |
| `log` | `{ message }` (DEBUG) |

### Page-turn rules

- Edge taps / toolbar / keycommands call `FoliateWebReader.goForward/goBackward` → `view.next()` / `view.prev()` only.
- No mid-chapter `scrollLeft`, no spine-index polling.
- Prefers `renderer` attributes: paginated (not scrolled) for MVP; optional later: `gpu-composite` if beneficial on iOS WKWebView.

### Settings mapping

| App | Foliate |
|-----|---------|
| Theme light/dark/sepia | Inject CSS variables + `color-scheme` / background |
| Font size 0.5…2.0 | CSS `font-size` on `html` via `renderer.setStyles` |
| Font choice | `@font-face` from bundled fonts (Literata / Atkinson) served under `rhapsode://reader/fonts/…`, or system fallback for publisher |
| Publisher styles | Minimal override CSS when choice is publisher |

### Phases

| Phase | Deliverable | Done when |
|-------|-------------|-----------|
| **1a Spike** | Scheme + shell + open sample EPUB + next/prev + relocate → SwiftData | ✅ |
| **1b Parity** | TOC, themes/fonts, keyboard, reading-time, progress push, hardened open, PhaseZero | ✅ 2026-07-17 |
| **1c Cutover** | Delete `EbookReader` + Readium Navigator/GCDWebServer deps; Streamer kept for import only | ✅ 2026-07-17 |
| **1d Polish** | Stream large EPUB serve, open cancel, process-pool warm, turn coalesce, status text | ✅ 2026-07-17 |
| **1e Custom fonts** | Extra presets (Bitter, …) + optional user-imported faces | **1e.1 Bitter ✅**; 1e.2+ pending |

### Risks & mitigations

| Risk | Mitigation |
|------|------------|
| ES modules + custom scheme MIME/CORS | Explicit `Content-Type` + `Access-Control-Allow-Origin: *` on scheme responses |
| WebKit iframe sandbox / scripts in EPUB | foliate-js already avoids running book scripts securely; keep `allowScript` false |
| Large EPUB base64 in bridge | Never base64 whole book — always scheme fetch |
| CFI vs old Readium locators | Fraction-only resume for legacy; rewrite on first Foliate open |
| Bundle size of full foliate-js | Bundle whole tree for simplicity; later strip PDF/MOBI/pdfjs if needed |

### Files to add/change (1a)

- `specs/reader/ebook-reader-plan.md` (this file)
- `SupportingFiles/ReaderWeb/index.html`
- `SupportingFiles/ReaderWeb/bridge.js`
- `SupportingFiles/ReaderWeb/reader.css`
- `Vendor/foliate-js/` (upstream)
- `Sources/Ebook/FoliateSchemeHandler.swift`
- `Sources/Ebook/FoliateWebReader.swift`
- `Sources/Ebook/ReaderView.swift` — host Foliate web view
- ~~`Sources/Ebook/EbookReader.swift`~~ — **deleted in 1c**
- `project.yml` — ReaderWeb + foliate-js resources; Streamer only (no Navigator)
- `Sources/Model/Models.swift` — `readingLocator` documents Foliate JSON

### Acceptance (1a)

- [x] Open `Fixtures/SampleLibrary/Books/Sample Book.epub` (code path + scheme)
- [x] Next/prev turns without log spam / 50ms polls
- [x] Progress bar on shelf moves after reading (`totalProgression`)
- [x] Cold reopen restores approx. position (fraction or CFI)
- [x] Settings change font size live

### Acceptance (1b)

- [x] Bundled Literata + Atkinson served as `rhapsode://reader/fonts/*` + `@font-face`
- [x] Theme light/dark/sepia CSS parity
- [x] TOC sheet + keyboard + reading-time + progress push (unchanged from 1a, still wired)
- [x] Empty/corrupt EPUB preflight via `EPUBFileValidator`
- [x] Shell ready timeout + bridge presence check + friendlier open errors
- [x] PhaseZero exercises Foliate progress + open path
- [ ] Device: confirm fonts render by ear/eye (manual)

### Acceptance (1c)

- [x] `EbookReader.swift` deleted (no Readium page-turn path in tree)
- [x] `project.yml` drops `ReadiumNavigator` + `ReadiumAdapterGCDWebServer`
- [x] `ReadiumShared` + `ReadiumStreamer` retained for `EbookImporter` only
- [x] `ReaderSettings` / `ReaderFontChoice` have no Readium imports
- [x] PhaseZero / ReaderView use Foliate only
- [x] App builds without Navigator products

---

## Path 2 — Stay on Readium (abandoned)

Superseded by Path 1c. The Readium navigator + custom `scrollLeft` turn path were **deleted**. Do not reintroduce JS scroll hacks. If Foliate regresses, fix the web bridge — do not restore multi-WKWebView navigation.

---

## Custom fonts (planned — Path 1e)

Goal: match Readest’s useful typeface set without shipping every Google Font in the IPA. Readest mounts Bitter, Merriweather, Literata, Roboto Slab, PT Serif, etc. via Google Fonts / CDN plus **user-imported** files (`customFontStore`). Rhapsode is offline-first, so we prefer **bundled OFL/SIL faces** and optional **user import**, not runtime Google Fonts network fetches.

### Product tiers

| Tier | Faces | Shipping model |
|------|--------|----------------|
| **A — Built-in (now)** | Publisher, Literata, Bitter, Vollkorn, PT Serif, Roboto Slab, Atkinson Hyperlegible, OpenDyslexic | App bundle → `rhapsode://reader/fonts/*` via `ReaderFontCatalog` |
| **B — deferred size** | Merriweather full VF (~4.5 MB/face) | Skip until static subset or on-demand pack (1e.4) |
| **C — User custom** | Any TTF/OTF/WOFF2 the user picks | Document picker → copy into container `ReaderFonts/Custom/` → register in prefs |

### Architecture (same scheme as 1b)

```
UserDefaults / SwiftData font catalog
  → FoliateWebReader settings.fontFamily (id)
  → bridge setStyles → @font-face { src: url(rhapsode://reader/fonts/…) }
  → FoliateSchemeHandler serves:
       • bundled: Bundle.main TTF
       • custom: ContainerPaths “ReaderFonts/Custom/<id>.ttf”
```

No change to foliate-js itself — only CSS injection + scheme serving.

### Bitter (first curated extra)

| Item | Detail |
|------|--------|
| Why | Excellent long-form serif; Readest’s default “interesting” alternative to Literata |
| License | OFL (Google Fonts Bitter) |
| Files | Prefer variable font **or** Regular + Italic + Bold + BoldItalic statics to match Literata packaging |
| Enum | `ReaderFontChoice.bitter` (or free-string `fontFamilyId` if we outgrow the enum) |
| CSS | `font-family: "Bitter", Literata, serif` |
| Size | Static 4-face set is small; document IPA delta before shipping all of Tier B |

### User custom fonts (Readest-like)

1. Settings → Reading → **Add font…** → `fileImporter` (`.font`, ttf/otf/woff2).
2. Store under Application Support (not Caches): `ReaderFonts/Custom/<uuid>.<ext>`.
3. Persist catalog: `{ id, displayName, familyName, relPath, createdAt }[]` in UserDefaults or a small JSON file.
4. On open / setStyles, bridge receives either a preset id or `custom:<id>` and emits matching `@font-face` URLs.
5. Delete font removes file + catalog entry; if selected, fall back to Literata.
6. **No network** for custom faces. Optional later: “download pack” from our CDN for Tier B without bloating the IPA.

### Implementation phases (1e)

| Step | Work |
|------|------|
| **1e.1** | Add **Bitter** TTFs + `ReaderFontChoice.bitter` + bridge `@font-face` + settings picker | ✅ |
| **1e.2** | Generalize font catalog (preset table: id → faces[]) + Vollkorn / PT Serif / Roboto Slab | ✅ |
| **1e.3** | User import/delete UI + scheme path for custom files | ✅ |
| **1e.4** | (Optional) On-demand download of extra packs with offline cache |

### Non-goals for 1e

- Google Fonts live links in the reader (breaks offline / privacy story).
- Full CJK web-font matrix (Readest’s CDN set) — separate localization decision.
- Syncing custom fonts via Dropbox/SMB (nice-to-have later; files are large).

### Acceptance (1d)

- [x] EPUB >2 MB streamed in chunks from scheme handler (not fully buffered)
- [x] Mapped I/O for shell/modules/fonts; long-cache for foliate-js + fonts
- [x] Shared `WKProcessPool` + warm on Books shelf
- [x] Open generation cancel on leave reader
- [x] Opening status: Opening… / Parsing book…
- [x] Rapid page-turn coalesce in bridge
- [x] Lazy spine unchanged (foliate loads sections on demand — “prefetch” is entry-metadata only)

### Acceptance (1e.1 Bitter)

- [x] Bitter appears in Reading typeface list
- [x] Variable roman + italic faces bundled; `@font-face` in bridge
- [x] Applies via settings sheet; offline
- [x] OFL: `SupportingFiles/ReaderFonts/OFL-Bitter.txt` + README

### Acceptance (1e.2 Catalog)

- [x] `ReaderFontCatalog` / `ReaderFontPreset` / `ReaderFontFaceSpec` — single table of presets
- [x] Bridge builds `@font-face` from `settings.faces[]` only (no per-family switch)
- [x] Native `settingsDictionary` sends `fontFamilyId` + `cssStack` + `faces`
- [x] New faces: **Vollkorn**, **PT Serif**, **Roboto Slab** (plus existing) without bridge edits
- [x] Preferences store catalog id; unknown id → literata
- [x] Licenses for new faces under `SupportingFiles/ReaderFonts/`
- [ ] Merriweather deferred (VF too large)

### Acceptance (1e.3 Custom import)

- [x] `CustomReaderFontStore` — JSON catalog in UserDefaults + files under `Media/ReaderFonts/Custom/`
- [x] Reading settings: **Add Font…** (`fileImporter`), list, swipe-to-delete
- [x] Import selects the new face; delete falls back to Literata if it was active
- [x] Scheme serves `rhapsode://reader/fonts/custom/<file>` from Application Support
- [x] Bridge `@font-face` format from extension (ttf/otf/woff/woff2)
- [x] CoreText family-name detection when possible

---



## Path 3 — KOReader Progress sync (after Path 1 positions)

Depends on **stable CFI + fraction** from Foliate (or XPointer conversion).

### Protocol (match Readest / KOReader)

1. **Document id:** KOReader `partialMD5` of the EPUB file bytes (1024-byte windows at geometric offsets — see Readest `utils/md5.ts`).
2. **Auth:** `X-Auth-User` + `X-Auth-Key` (md5 of password), or HTTP Basic on some servers.
3. **GET** `/syncs/progress/{documentHash}`
4. **PUT** `/syncs/progress` body:  
   `{ document, progress, percentage, device, device_id }`  
   where `progress` is **XPointer** string for reflowable books.
5. **Strategy:** prompt | silent | send | receive (start with silent LWW by server timestamp).

### Rhapsode integration

| Component | Notes |
|-----------|--------|
| `KOSyncClient.swift` | HTTP only; no UI framework |
| `partialMD5` | CryptoKit or pure Swift; hash once at import / first open; store on `Book` or side table |
| CFI → XPointer | Port Readest `xcfi` utils into JS bridge helper, or call into web view |
| Settings | Server URL, username, password (Keychain), device name |
| Triggers | Pull on reader open; push debounced on relocate + onDisappear |
| Conflict | Compare remote percentage/timestamp vs local `progressUpdatedAt` |

### Relation to existing progress

| Kind | Transport |
|------|-----------|
| Audiobook + SmartSpeech stats | `.rhapsode-sync` / Dropbox / SMB JSON (unchanged) |
| Ebook position (P1) | **KOSync only** once Path 3 ships (per `nas-smb-plan.md`) |
| Ebook position (interim) | Local SwiftData + optional existing JSON until KOSync ready |

### Phases

| Phase | Deliverable | Status |
|-------|-------------|--------|
| **3a** | `partialMD5` + PhaseZero shift/hash checks | ✅ |
| **3b** | `KOSyncClient` connect / get / put | ✅ |
| **3c** | Wire pull/push in `ReaderView` + conflict prompt + Settings UI | ✅ |
| **3d** | CrossInk X3 / second device manual test | Manual |

### Acceptance

- [x] `PartialMD5` matches JS `<<` sampling windows; stable hex digest
- [x] `KOSyncClient` X-Auth-User / X-Auth-Key (+ Basic fallback); JSON login guard
- [x] Settings → KOReader Sync (server, credentials, strategy, device)
- [x] Pull on reader open; push debounced + on leave/background
- [x] Strategies: silent LWW / send / receive / prompt
- [x] Progress wire: CFI or stored XPointer + percentage; apply via CFI or fraction
- [x] `Book.koreaderDocumentHash` cache (optional SwiftData field)
- [ ] Same EPUB on KOReader device and Rhapsode share position within one page (3d manual)
- [ ] Offline: local position wins until reconnect; then strategy applies (3d)
- [ ] Wrong password surfaces error; no silent “connected” HTML page (cover in Sign In)

---

## Recommended sequencing

```text
1a–1e.3 ✅ Foliate reader + font catalog + user import
1e.4 optional on-demand packs
3a–3c ✅ KOSync client + reader wiring
3d manual CrossInk / KOReader device check
```

## Out of scope (later)

- Readest-style curl page capture
- Annotations / highlights sync
- PDF via pdf.js
- Replacing Readium Streamer import with pure JS/OPF parse (optional size win)
---

## Decision log

| Date | Decision |
|------|----------|
| 2026-07-17 | Path 1 primary for performance |
| 2026-07-17 | Serve foliate via custom `rhapsode://` scheme, not base64 books |
| 2026-07-17 | Store Foliate progress in existing `readingLocator` with `engine: "foliate"` |
| 2026-07-17 | Path 3 = KOReader Progress API only for ebook position (matches NAS plan) |
| 2026-07-17 | **1c:** delete Readium navigator path; keep Streamer for import/cover only |
| 2026-07-17 | Custom fonts: offline bundled/user files only — no live Google Fonts; **Bitter** first curated extra |
| 2026-07-17 | **1d:** stream large EPUB; shared process pool; cancel in-flight open |
| 2026-07-17 | **1e.1:** ship Bitter variable roman+italic (OFL) |
| 2026-07-17 | **1e.2:** `ReaderFontCatalog` data table; bridge consumes face descriptors; add Vollkorn/PT Serif/Roboto Slab; skip Merriweather VF size |
| 2026-07-17 | **1e.3:** user font import/delete; custom scheme path; CoreText family names |
| 2026-07-17 | **Path 3:** KOReader Progress Sync (partialMD5, client, settings, pull/push, prompt) |
