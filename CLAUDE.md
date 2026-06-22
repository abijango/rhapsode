HTTP-API-not-SDK for Dropbox, **App-folder access (paths relative to app folder, never Full Dropbox)**, Application-Support-not-Caches for files, relative-paths-in-SwiftData, no paid entitlements in the MVP.
- Agents B and C develop against Agent A's mock so they don't block on real OAuth.
- **Dropbox scopes:** read (`files.metadata.read` + `files.content.read`) for library list/longpoll/download, plus **app-folder write** (`files.content.write`) added in Phase 5 — used ONLY to write small progress JSON files under `/.rhapsode-sync` for cross-device progress sync. Still App-folder-scoped (never Full Dropbox); chosen over CloudKit so the sync layer ports to the planned Android client unchanged.


## Cadence (silence-trimming feature)

Spec: specs/cadence-feature-spec.md — read before working on this feature. Architecture
is Path B (pre-render): analyse the downloaded audio, render a trimmed .m4a copy, play it
with the EXISTING AVPlayer. Do NOT introduce AVAudioEngine or rewrite the playback layer.

### Integration (this repo, not greenfield)
- Bind to the existing code, don't invent parallel systems. Before writing WP3/WP5, survey
  and reuse Rhapsode's current download pipeline, SwiftData models, and AVPlayer playback —
  propose the integration points and confirm them before building.
- This is an XcodeGen project. Declare packages/targets in project.yml and run
  `xcodegen generate`; never hand-edit Rhapsode.xcodeproj (regeneration wipes GUI edits).

### CadenceKit
- CadenceKit is a local Swift package. It imports ONLY Accelerate + AVFoundation — no
  SwiftUI, no app types, no swift-argument-parser. It must stay liftable/standalone.
- Keep tier preset values identical to the cadence CLI presets in CadenceLab (reference
  oracle, §14). If a preset changes, change it in both.

### Correctness rules (non-negotiable)
- Analysis uses a MONO downmix for silence detection only. The renderer cuts the
  ORIGINAL-channel audio at those timestamps — never render from the downmix.
- Splices are zero-crossing-aligned + equal-power crossfaded. A hard cut is a bug (it
  produces the chopped/clicky artifact the feature exists to avoid).
- The original download is the source of truth and is never modified. The trimmed .m4a is
  a regenerable, evictable cache (Caches/), keyed to
  contentFingerprint + analyzerVersion + rendererVersion + tier.
- All persisted positions, bookmarks, and chapter marks are SOURCE-domain. Map to trimmed
  time only at playback. Never persist trimmed-domain positions.
- Bump analyzerVersion / rendererVersion when detection or render logic changes (forces
  re-render and cache invalidation).
- Multi-file books: one trimmed file per original file (preserve file boundaries so the
  existing queue/gapless logic is untouched).

### Verification
- The cadence CLI in CadenceLab is the reference oracle: for the same input + tier, the
  app's renderer output must match it. Use it to validate WP3.
- Analyzer (golden synthetic PCM) and policy (table-driven) tests transfer with CadenceKit
  and must stay green before any by-ear tuning.