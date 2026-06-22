# Cadence — Offline De-Risk Harness Spec

> **Purpose:** Prove the silence-trimming *sounds natural* and measure the savings, offline, before committing to the AVPlayer→AVAudioEngine migration. Standalone project — does **not** touch the main app.
> **Companion to:** `cadence-feature-spec.md` (the production spec). This harness builds the same pure core that will ship; only its UI is throwaway.

---

## 0. The one question this answers

Does proportional silence-trimming with conservative defaults sound like Overcast (you forget it's on) or like Pocket Casts (chopped breaths, audible edits)? Everything else in the production spec is known-feasible work; **this** is the genuine unknown. We settle it with zero realtime/engine code.

**Goals**
- Render an original section and a trimmed section to disk, listen back-to-back.
- Adjust the five trim parameters live and re-render.
- Report the savings (seconds + %, region count) per section — this is also production scope.
- Output a tuned `CadenceSettings` to carry into the main project.

**Non-goals (explicitly out)**
- No AVAudioEngine, no realtime trimming, no migration work.
- No SwiftData, no main-app models, no playback surface (now-playing/CarPlay/etc).
- Global 1.0–3.0× speed is out (it's a known-good `AVAudioUnitTimePitch` later). Optional stretch only — see §6.

---

## 1. Project — a Swift Package CLI tool

A single Swift Package. No `.xcodeproj`, no signing, no provisioning, no GUI. One library target (`CadenceKit` — the part that transfers), one executable target (`cadence` — the throwaway flag-parser over it), one test target.

```
CadenceLab/
├── Package.swift
├── Sources/
│   ├── CadenceKit/                   ← TRANSFERS VERBATIM. Deps: Accelerate + AVFoundation only.
│   │   ├── SilenceAnalyzer.swift     ← = production WP1
│   │   ├── CadenceSettings.swift     ← = production WP4 (settings)
│   │   ├── SilencePolicy.swift       ← = production WP4 (D → target, pure)
│   │   ├── OfflineTrimRenderer.swift ← reads PCM, writes trimmed file (= production WP13 core)
│   │   └── TrimReport.swift          ← savings stats
│   └── cadence/                      ← THROWAWAY CLI. Deps: CadenceKit + swift-argument-parser.
│       └── Cadence.swift             ← parse flags → analyze → render → print report
├── Tests/CadenceKitTests/            ← golden-PCM + policy tests (transfer too)
├── TestSections/                     ← drop your trimmed audiobook sections here
├── specs/                            ← both spec files
└── CLAUDE.md
```

Target `Package.swift` (macOS platform, three targets):

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CadenceLab",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
    ],
    targets: [
        .target(name: "CadenceKit"),   // Accelerate + AVFoundation are system frameworks — no package dep
        .executableTarget(
            name: "cadence",
            dependencies: [
                "CadenceKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]),
        .testTarget(name: "CadenceKitTests", dependencies: ["CadenceKit"]),
    ]
)
```

- **No signing / provisioning:** `swift build` / `swift run` produce a local unsigned binary — nothing to configure.
- **`CadenceKit` stays dependency-pure:** system frameworks `Accelerate` + `AVFoundation` only. `swift-argument-parser` belongs to the `cadence` target alone, so the lift into the main app is a clean copy.
- The default `swift package init --type executable` produced one `CadenceLab` executable target — **restructuring to the layout above is the first build step.**

---

## 2. Test file prep (what to provide)

Trim the audiobook to **2–4 short sections, ~3–5 min each**, chosen to stress different cases:

1. **Steady narration** — the common case; the naturalness baseline.
2. **Dialogue / fast exchanges** — short pauses that must be left alone (rule 3).
3. **Slow, deliberate, dramatic passage** — long pauses that *should* stay mostly intact; over-trimming here is the failure mode reviewers warned about.
4. *(optional)* **A bit with intro/outro music or a sound bed** — checks false-positive trimming of tonal-but-quiet audio.

Keep them short so the render→listen loop stays fast. Any common format (`.m4a` / `.mp3` / `.m4b`) is fine; the renderer decodes via `AVAudioFile` (fall back to `AVAssetReader` for anything it won't open).

---

## 3. `CadenceKit` core (the part that ships)

Implements the production algorithm exactly — see `cadence-feature-spec.md` §4 (analyzer) and §6 (policy). Restated here only as the knobs you'll tune:

```swift
struct CadenceSettings {
    var minSilenceDuration: TimeInterval = 0.28   // below this → untouched
    var minKeptSilence:     TimeInterval = 0.18   // residual gap floor (never trim to 0)
    var residualSlope:      Double       = 0.12   // fraction of excess silence kept (proportional)
    var thresholdMarginDb:  Double       = 8.0    // above adaptive noise floor = silence
    var edgeGuardMs:        Double       = 40      // shrink region edges (protect breaths/tails)
    var crossfadeMs:        Double       = 15      // equal-power splice crossfade
}
```

- **Analyzer:** decode mono float32 PCM → 20 ms/10 ms windowed RMS via `vDSP_rmsqv` → per-section adaptive noise floor (low-percentile of RMS histogram) → noise-gate region detection with attack/release + edge guard → discard regions < `minSilenceDuration`. Output `[SilenceRegion]` in source time.
- **Policy (pure):** `target = clamp(minKeptSilence + (D - minSilenceDuration)*residualSlope, minKeptSilence, D)` for `D ≥ minSilenceDuration`, else `D`.
- **`OfflineTrimRenderer`:** build the output by copying speech segments verbatim and copying only the first `target` seconds of each silence region; **snap each splice to a zero-crossing and apply an equal-power crossfade of `crossfadeMs`**. Write result via `AVAudioFile` (WAV or AAC). This faithful splice handling is the whole test — a naive hard cut invalidates the result.
- **`TrimReport`:** `originalDuration`, `trimmedDuration`, `savedSeconds`, `savedPercent`, `regionCount`, `meanRegionSaving`, and the `CadenceSettings` used.

**Tests that transfer:** golden synthetic PCM with known silences (assert detected regions within tolerance, incl. quiet-speaker and added-noise-floor variants); table-driven policy tests (monotonic, `target ≤ D`, `≥ minKeptSilence`, untouched below `minSilenceDuration`).

---

## 4. `cadence` CLI (throwaway harness)

A thin flag-parser over `CadenceKit`. No GUI — it renders files you audition in your own player (QuickTime / Music), and tuning is just re-running with different flags (reproducible, and the winning parameter set ends up in your shell history).

```
cadence trim <input> [options]
  --min-silence <s>        default 0.28   below this, untouched
  --min-kept <s>           default 0.18   residual gap floor
  --residual-slope <x>     default 0.12   fraction of excess silence kept
  --threshold-margin <dB>  default 8.0    above adaptive noise floor = silence
  --edge-guard-ms <ms>     default 40
  --crossfade-ms <ms>      default 15
  --out <path>             default <input>-trimmed.wav (next to source)
  --report <path>          optional: also write the TrimReport as JSON
```

Behaviour:
- Runs analyzer + renderer, writes the trimmed WAV.
- Prints the `TrimReport` to stdout: original duration, trimmed duration, saved (seconds + %), region count, and the exact `CadenceSettings` used — your "what's the speed-up" readout and the values to report back.

To A/B: play `<input>`, then `<input>-trimmed.wav`, in any player. Loop the trimmed file to scrutinise splices for clicks. Optional `--audition-silence` flag may emit a silence-regions-only file so any clicky splice is obvious in isolation.

---

## 5. How to judge it (acceptance for the de-risk)

Listening, per section:
- Trimmed version doesn't sound *edited* — no chopped breaths, no clipped word onsets, no clicks at joins.
- Dramatic/slow pauses survive recognisably; only dead air collapsed.
- Fast-dialogue micro-pauses untouched.
- Saved % lands in a sane band (expect noticeably less than podcasts' ~15% on clean narration — that's fine and expected).

Outcome → one of:
- **Sounds natural at sensible defaults** → algorithm de-risked; proceed to the migration with confidence and ship these constants.
- **Needs tuning** → adjust the five rules, re-render, converge. Cheap, no engine.
- **Can't get there** → reconsider scope before spending the migration effort. (Unlikely, but this is exactly why we test first.)

---

## 6. Optional stretch (only if defaults pass easily)

Add a `--speed` flag that renders the trimmed buffer through an offline `AVAudioEngine` render with an `AVAudioUnitTimePitch` at e.g. 1.25–1.75×. Out of scope for the core decision; skip unless you want it.

---

## 7. What transfers vs what's discarded

**Transfers to the main project verbatim:** the entire `CadenceKit` package — analyzer, settings, policy, renderer (becomes production WP13's harness), report, and tests. The tuned `CadenceSettings` values become the production defaults.

**Discarded:** the `cadence` executable target (the throwaway flag-parser).

Report back here with: the tuned `CadenceSettings`, the per-section savings, and a one-line verdict on naturalness. That folds straight into finalising the production spec and ordering the migration.
