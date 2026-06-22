# Cadence — Silence-Trimming Feature Spec (Production)

> **Architecture:** Path B — **pre-render**. Analyse the downloaded audio, render a trimmed copy to a cache, play it with the existing AVPlayer. **No AVAudioEngine migration.**
> **Platforms:** iOS / iPadOS / macOS (SwiftUI + SwiftData).
> **Validated:** algorithm proven in the offline de-risk (real narration, ~14% saved, sounds natural). `CadenceKit` lifts in verbatim.
> **For:** Claude Code handoff.

---

## 0. Naming

User-facing feature must **not** be "Smart Speed" (Overcast trademark). Default name **Cadence**; alternatives **Flow**, **Tighten**, **Trim**. Single source of truth:

```swift
enum CadenceBranding { static let featureName = "Cadence" }   // change here only
```

---

## 1. What it does (and must NOT do)

Shorten silences/gaps in narrated audio so the book plays faster **without sounding edited**. Not hard silence-skipping (the seek-past-gaps approach that clicks and destroys comprehension pauses). It is **proportional silence compression**: long dead gaps collapse hard, natural sentence/paragraph pauses stay nearly intact, and a residual gap is always preserved.

**Five rules that make it natural** (all five, or you get the chopped-breath/click failure mode):

1. **Adaptive threshold** relative to the per-section noise floor — never an absolute dB.
2. **Residual minimum gap** — never compress to zero.
3. **Minimum silence length** — leave short inter-word pauses completely alone (they are the rhythm).
4. **Edge guard + smoothed splice** — trim region edges inward; snap splices to zero-crossings; equal-power crossfade. No clicks.
5. **Proportional aggressiveness** — longer silences compressed harder than shorter ones.

---

## 2. Architecture overview (Path B)

```
Download complete (feature ON)
        │
        ▼
┌────────────────┐  PCM (mono   ┌──────────────────┐  regions  ┌─────────────────┐
│ BookAudioSource│  downmix for │ SilenceAnalyzer  │ ────────► │ SilenceMap +    │
│   (§3)         │  detection)  │  (§4, vDSP RMS)  │           │ timeline (§4/§7)│
└────────────────┘              └──────────────────┘           └─────────────────┘
        │                              ▲                                │
        │ original-channel PCM         │ CadenceTier preset (§5)        │
        ▼                              │                                ▼
┌──────────────────────────────────────────────────┐        ┌──────────────────────┐
│ OfflineTrimRenderer (§6) → trimmed .m4a (AAC)      │ ─────► │ TrimmedRendition     │
│ cuts ORIGINAL channels at region times, crossfades │        │ cache (§7, SwiftData)│
└──────────────────────────────────────────────────┘        └──────────────────────┘
        │
        ▼
┌──────────────────────────────────────────────────────────────────────────────┐
│ EXISTING AVPlayer (§8): plays trimmed file when feature ON + rendition ready;  │
│ else the original. Existing variable speed, lock screen, CarPlay, AirPlay,     │
│ scrubbing, chapters all keep working — it is just an audio file.               │
└──────────────────────────────────────────────────────────────────────────────┘
```

**Why this is low risk:** the trimmed file is an ordinary audio file. Everything that works for the original (seeking, chapters, now-playing, remote commands, AirPlay, your existing 1.0–3.0× speed) works for it with no changes. The de-risk already proved the *bytes* sound right; the app ships those same bytes.

**Source of truth vs cache:** the original download is canonical and never modified. The trimmed `.m4a` is a **regenerable, evictable cache** (render is ~thousands× realtime). Under storage pressure, evict trimmed files and re-render on demand.

---

## 3. `BookAudioSource` abstraction (single AND multi-file)

```swift
struct AudioFileRef: Hashable {
    let url: URL
    let contentHash: String         // sha256 or (size+mtime) — cache invalidation
}
struct ChapterMark { let title: String; let sourceStart: TimeInterval }   // source domain

protocol BookAudioSource {
    var bookID: UUID { get }
    var orderedFiles: [AudioFileRef] { get }   // 1 for single-file (.m4b), N for per-chapter
    var chapters: [ChapterMark] { get }
    var isFullyDownloaded: Bool { get }
    var isDRMProtected: Bool { get }           // true → feature unavailable (§12)
}
```

**Multi-file handling:** render **one trimmed `.m4a` per original file** (not one concatenated blob), preserving file boundaries so your existing multi-file queue/gapless logic is untouched — the player simply swaps each queue entry for its trimmed counterpart. Per-file timeline maps. Single-file `.m4b` → one trimmed file; chapters are metadata offsets.

The **source (concatenated) timeline** is the canonical coordinate system; all persisted positions, bookmarks, and chapter marks live in source time and are stable across tier changes and cache eviction.

---

## 4. `SilenceAnalyzer` — the heart (validated)

**Input:** a `BookAudioSource` + the active tier's analyzer params. **Output:** `[SilenceRegion]` in source time.

### 4.1 Decode
- Read float32 PCM via `AVAudioFile` (fallback `AVAssetReader`). **Downmix to mono for *detection only*.** Stream in chunks. Record actual sample rate. Normalise differing rates across multi-file books.
- **Critical:** analysis uses the mono downmix to *locate* silence; the renderer (§6) cuts the **original-channel** audio at those timestamps. Never render from the mono downmix.

### 4.2 Windowed energy (vDSP)
- Window 20 ms, hop 10 ms. RMS per window via `vDSP_rmsqv` (or `vDSP_measqv`). Convert to dB.

### 4.3 Adaptive noise floor & threshold (per chapter/section)
- Histogram of windowed RMS-dB; noise floor ≈ 5th–10th percentile (quiet cluster).
- `silenceThresholdDb = noiseFloorDb + thresholdMarginDb` (tier-dependent, §5). Clamp relative to section speech level so loud/quiet books behave alike.
- Per-section (not whole-book) is what "adapts to quieter voices."

### 4.4 Region detection (noise-gate style)
- Silent window if `rms < threshold`; group consecutive. Hysteresis (attack/release) so single blips don't split/open regions. Bridge sub-window flutter.
- **Edge guard:** shrink each region inward by `edgeGuardMs` (tier-dependent) — protects word tails, breaths, plosive onsets.
- **Discard** regions shorter than `minSilenceDuration` (tier-dependent) — natural pauses, never touched.

### 4.5 Output
`SilenceRegion { sourceStart, sourceEnd }`. The analyzer does **not** decide compressed durations — that's the policy (§5), so the map is a function of the tier's *analyzer* params only.

> Validated reference: HP narration, noise floor ≈ −47.6 dB @ 44.1 kHz, analysis ~9600× realtime.

---

## 5. `CadenceSettings`, tiers, and compression policy (pure)

### 5.1 Parameter bag

```swift
struct CadenceSettings {
    var minSilenceDuration: TimeInterval   // below this, untouched (analyzer)
    var minKeptSilence:     TimeInterval   // residual gap floor (policy)
    var residualSlope:      Double         // fraction of excess silence kept (policy) — main lever
    var thresholdMarginDb:  Double         // dB above adaptive noise floor (analyzer)
    var edgeGuardMs:        Double         // region edge inset (analyzer)
    var crossfadeMs:        Double         // splice crossfade (renderer)
}
```

### 5.2 Tiers (the new per-book feature)

Three user-selectable presets. **These values match the `cadence` CLI presets** so the CLI stays a faithful reference oracle (§14). Use rawValue `"default"` so CLI `--preset default` and the app agree.

```swift
enum CadenceTier: String, Codable, CaseIterable {
    case `default`            // backticks: Swift keyword
    case more
    case aggressive

    var displayName: String {
        switch self { case .default: "Default"; case .more: "More"; case .aggressive: "Aggressive" }
    }

    var settings: CadenceSettings {
        switch self {
        case .default:    .init(minSilenceDuration: 0.28, minKeptSilence: 0.18, residualSlope: 0.12,
                                 thresholdMarginDb: 8.0,  edgeGuardMs: 40, crossfadeMs: 15)
        case .more:       .init(minSilenceDuration: 0.24, minKeptSilence: 0.15, residualSlope: 0.08,
                                 thresholdMarginDb: 9.0,  edgeGuardMs: 38, crossfadeMs: 15)
        case .aggressive: .init(minSilenceDuration: 0.20, minKeptSilence: 0.12, residualSlope: 0.05,
                                 thresholdMarginDb: 10.0, edgeGuardMs: 32, crossfadeMs: 18)
        }
    }
}
```

| Setting | default | more | aggressive | direction |
|---|---|---|---|---|
| minSilenceDuration | 0.28 | 0.24 | 0.20 | ↓ touch slightly shorter gaps |
| minKeptSilence | 0.18 | 0.15 | 0.12 | ↓ tighter residual floor |
| residualSlope | 0.12 | 0.08 | 0.05 | ↓ **main lever** — long gaps collapse harder |
| thresholdMarginDb | 8.0 | 9.0 | 10.0 | ↑ slightly more sensitive (kept modest — high values eat speech) |
| edgeGuardMs | 40 | 38 | 32 | ↓ but never below ~30 (protects breaths/onsets) |
| crossfadeMs | 15 | 15 | 18 | ↑ on aggressive — more/tighter cuts → keep joins clean |

The progression moves the **safe levers** (collapse long dead gaps harder, touch slightly shorter gaps) and only gently nudges the **risky** ones (detection sensitivity, edge guard), so even `aggressive` stays clear of the chopped-breath/click failure modes.

> **Ship gate:** the de-risk ear-validated one combination (minKept 0.10 / margin 12 / edgeGuard 20). The presets above differ — `default` is more conservative than that validated point. Audition each preset once via the `cadence` CLI on a slow and a fast narrator before release; tune the table if needed. The CLI is the validator.

### 5.3 Compression policy (pure function)

```
if D < minSilenceDuration: target = D
else: target = clamp(minKeptSilence + (D - minSilenceDuration) * residualSlope,
                     lower: minKeptSilence, upper: D)
```

Unit-test exhaustively (monotonic, `minKeptSilence ≤ target ≤ D`, untouched below `minSilenceDuration`).

### 5.4 UX rationale (surface as helper text)

Fast natural narrators usually sound best on **Default**; slow/deliberate narrators tolerate **More**/**Aggressive** without feeling rushed. This is why the tier is **per-book**, not global.

---

## 6. `OfflineTrimRenderer` — now a shipping component

Produces the trimmed audio that AVPlayer plays. (In the de-risk this rendered WAV for auditioning; in production it renders the cached `.m4a`.)

- Input: original file PCM (**original channel layout**, not the mono downmix) + the tier's `SilenceRegion`s + policy targets + `crossfadeMs`.
- For each region: keep only the first `target` seconds of the actual (silent) audio — preserves room tone, no dead hole; skip the rest.
- **Splice:** snap to zero-crossing where possible; equal-power crossfade of `crossfadeMs` across each join. A hard cut is a bug.
- Encode to **AAC `.m4a`** via `AVAssetWriter`/`AVAudioFile`. Bitrate ≥ source (match or slightly exceed) so spoken-word generation loss is inaudible. Preserve sample rate and channel layout.
- Emit a `TrimReport` (original/trimmed duration, savedSeconds, regionCount) and the **timeline map** (source↔trimmed) used by §7–§11.

---

## 7. `TrimmedRendition` cache + lifecycle

### 7.1 Model (SwiftData)

```swift
@Model final class TrimmedRendition {
    var bookID: UUID
    var fileRefHash: String           // per-file (multi-file → one rendition row per file)
    var tier: String                  // CadenceTier.rawValue
    var contentFingerprint: String
    var analyzerVersion: Int
    var rendererVersion: Int
    var trimmedFileURL: URL           // in Caches/ — evictable
    var originalDuration: TimeInterval
    var trimmedDuration: TimeInterval
    var savedSeconds: TimeInterval
    var timelineMapBlob: Data         // source↔trimmed mapping (packed)
    var chapterMapBlob: Data          // chapter marks remapped to trimmed time
    var createdAt: Date
    var lastUsedAt: Date              // for LRU eviction
}
```

- **Key / invalidation:** a rendition is valid only if `contentFingerprint`, `analyzerVersion`, `rendererVersion`, **and `tier`** all match the current request. Any mismatch → re-render.
- The trimmed file lives in a **Caches** directory (OS-purgeable); we also LRU-evict. The lightweight metadata (maps, durations) can be kept after the audio is evicted so re-render only redoes the audio.

### 7.2 Orchestration (background)

- **On download complete, feature ON:** enqueue render for the book's current tier.
- **On feature toggle ON** for an already-downloaded book: render current tier now.
- **On tier change for a book:** enqueue re-render for the new tier; keep playing the current rendition until the new one is ready, then swap (remap position, §8).
- **On toggle OFF:** play the original; keep the rendition (fast re-toggle) but mark evictable.
- Background actor; one book at a time; cancellable/resumable; thermal throttle (rarely needed given speed). Until a rendition exists, playback uses the original (graceful, no glitch) — optionally show a subtle "Preparing…" state.

---

## 8. Playback integration (keep AVPlayer)

- **Source selection:** feature ON **and** a valid rendition ready → point AVPlayer at the trimmed file(s); otherwise the original. Multi-file: swap each queue entry for its trimmed counterpart.
- **Canonical position:** store playback position, bookmarks, and resume in **source domain**. When playing a trimmed file, map source→trimmed (via the rendition's timeline map) to set `currentTime`; when persisting, map trimmed→source. This keeps position stable across tier changes, toggles, and cache eviction.
- **Variable speed:** your existing 1.0–3.0× (`rate` + `audioTimePitchAlgorithm`) works on the trimmed file unchanged — it composes (trim shortens the timeline, speed scales it).
- **Chapters:** feed the rendition's remapped chapter marks to your now-playing/chapter UI.
- **Everything else** (scrubbing, lock screen, `MPRemoteCommandCenter`, CarPlay, AirPlay) is unchanged because the trimmed file is an ordinary audio file.

---

## 9. Per-book tier selection (UI + persistence)

- Persist `selectedTier: CadenceTier` per book (SwiftData), plus a user-set **global default tier** applied to new books. Default global = `.default`.
- **UI:** in the per-book settings / now-playing surface, a segmented control **Default · More · Aggressive**, plus the global feature on/off. Helper text per §5.4.
- Changing the tier triggers §7.2 re-render; show "Preparing…" until ready, then swap seamlessly.

---

## 10. Time-saved stat

- `savedSeconds` is known per rendition up front. Accumulate the lifetime stat in proportion to trimmed playback progress (honest — counts only what's actually listened through). Persist a single cumulative record; optionally per-book. Display "X h Y min saved." Optionally show the per-book estimate before play.

---

## 11. Smart resume

- On resume, nudge the (source-domain) position back to just before a pause: look back up to ~3 s for the nearest preceding `SilenceRegion` boundary and resume at its onset (start of the word/phrase, never mid-word); fallback ~1.5 s fixed backstep if none. Map to trimmed time for playback. Only ever nudge backward.

---

## 12. Edge cases

- **DRM-protected:** can't decode PCM → mark unavailable, disable gracefully.
- **Still downloading:** never render partial files.
- **Music/ambient beds:** adaptive threshold + `minSilenceDuration` avoid most false positives; document as a known limitation rather than building tonal detection now.
- **Mid-playback tier change / rendition swap:** prepare the new file, then switch at a mapped position with no audible jump.
- **Cache eviction during playback:** never evict the rendition currently playing; evict LRU among the rest.
- **Mixed sample rate / channel layout across multi-file books:** normalise detection; renderer preserves each file's original layout.
- **Toggle off mid-playback:** swap to original at the mapped source position.

---

## 13. Work packages (re-scoped for Path B — no engine migration)

| WP | Scope | Depends on | Parallel |
|----|-------|-----------|----------|
| WP0 | Lift `CadenceKit` into the app (analyzer, settings+policy, renderer, report). Keep dependency-pure (Accelerate + AVFoundation only). | — | — |
| WP1 | `CadenceTier` presets + per-book `selectedTier` + global default (SwiftData) | — | ✅ |
| WP2 | `TrimmedRendition` model + keying/invalidation (fingerprint, analyzerVersion, rendererVersion, tier) | WP0 | ✅ |
| WP3 | Render pipeline: analyse (mono) → render (original channels) → AAC `.m4a` → write rendition + timeline map + remapped chapters. Per-file for multi-file books. | WP0, WP2 | — |
| WP4 | Background orchestration: render on download-complete / toggle-on / tier-change; cancel/resume; one-at-a-time | WP3 | — |
| WP5 | Playback integration: trimmed-vs-original selection; source-domain canonical position + mapping; compose with existing variable speed; chapter feed | WP3 | — |
| WP6 | Cache/storage: Caches dir, LRU eviction, regenerate-on-demand, retain metadata | WP2 | ✅ |
| WP7 | Time-saved stat (from rendition, by progress) + display | WP3 | ✅ |
| WP8 | Smart resume (map-based) | WP5 | ✅ |
| WP9 | Per-book tier UI (segmented control + on/off + helper text) + re-render trigger + "Preparing…" state | WP1, WP4, WP5 | — |
| WP10 | Edge cases + graceful degradation | WP5 | ✅ |
| WP11 | QA: reference-oracle tests (§14), transferred analyzer/policy tests, cache-invalidation tests, chapter-remap tests, per-tier listening | WP3 | ✅ |

**Critical path:** WP0 → WP3 → WP5 → WP9. **Notably absent:** the AVAudioEngine migration and the entire now-playing/CarPlay/AirPlay re-implementation. That is the saving Path B buys.

---

## 14. Testing strategy

- **Reference oracle (key advantage):** the `cadence` CLI is the validated renderer. For the same input + tier, the app's WP3 render must match the CLI output (byte-identical, or within a tiny tolerance if encoder settings differ). Keep the CLI around purely as the oracle. This pins production correctness to the artifact you already trust.
- **Transferred:** golden synthetic-PCM analyzer tests (known silences, quiet-speaker & added-noise variants); table-driven policy tests.
- **Cache:** invalidation on each key field; eviction never touches the playing rendition; metadata survives audio eviction.
- **Mapping:** timeline bijection `source→trimmed→source ≈ identity`; chapter marks land correctly; resume position stable across tier change.
- **Manual:** audition `default`/`more`/`aggressive` on a fast and a slow narrator — no chopped breaths, no clicks at joins, dramatic pauses survive.

---

## 15. CLAUDE.md guardrails

- `CadenceKit` imports only Accelerate + AVFoundation; transfers verbatim; no app-specific or SwiftUI code.
- The original download is the source of truth and is never modified; the trimmed `.m4a` is a regenerable, evictable cache.
- Analysis uses a mono downmix for detection only; the renderer cuts the **original-channel** audio.
- Splices are zero-crossing-aligned + equal-power crossfaded — a hard cut is a bug.
- All persisted positions/bookmarks/chapters are **source-domain**; map to trimmed time only at playback.
- Tier preset values must stay identical to the `cadence` CLI presets (reference oracle). Bump `analyzerVersion`/`rendererVersion` when detection or render logic changes (forces re-render).
- Do **not** introduce AVAudioEngine or touch the existing playback surface destructively — Path B keeps AVPlayer.
