HTTP-API-not-SDK for Dropbox, **App-folder access (paths relative to app folder, never Full Dropbox)**, Application-Support-not-Caches for files, relative-paths-in-SwiftData, no paid entitlements in the MVP.
- Agents B and C develop against Agent A's mock so they don't block on real OAuth.
- **Dropbox scopes:** read (`files.metadata.read` + `files.content.read`) for library list/longpoll/download, plus **app-folder write** (`files.content.write`) added in Phase 5 — used ONLY to write small progress JSON files under `/.rhapsode-sync` for cross-device progress sync. Still App-folder-scoped (never Full Dropbox); chosen over CloudKit so the sync layer ports to the planned Android client unchanged.

## SmartSpeech (live silence-trimming feature)

Specs: specs/realtime-cadence-exploration.md (the CURRENT live design) and
specs/cadence-feature-spec.md (the original pre-render design — HISTORICAL; that batch path
was removed once live trimming became the default player). "SmartSpeech" is the user-facing
name and the internal code name; the external reference oracle is still "Cadence" (CadenceLab,
below). Filenames like specs/cadence-feature-spec.md keep their original names.

Architecture (CURRENT): trim silence LIVE during playback via AVAudioEngine. `AudiobookPlayer`
drives `LiveAudioBackend` / `LiveTrimProducer` (AVAudioPlayerNode → AVAudioUnitTimePitch →
mixer), fed by the SmartSpeechKit DSP. There is NO pre-render and NO on-disk trimmed copy —
the original download is the only audio on device. (The earlier Path-B pre-render + AVPlayer
design, and the producer/consumer render-share, have been removed.)

### Integration (this repo, not greenfield)
- Bind to existing code; don't invent parallel systems. Reuse the download pipeline, SwiftData
  models, and the `AudiobookPlayer` / `LiveAudioBackend` playback path.
- XcodeGen project. Declare packages/targets in project.yml and run `xcodegen generate`;
  never hand-edit Rhapsode.xcodeproj (regeneration wipes GUI edits).

### SmartSpeechKit (formerly CadenceKit)
- SmartSpeechKit is a local Swift package (the silence-analysis + splice DSP). It imports ONLY
  Accelerate + AVFoundation — no SwiftUI, no app types. It must stay liftable/standalone.
- Keep tier preset VALUES identical to the `cadence` CLI presets in CadenceLab (the external
  reference oracle — still named Cadence). If a preset changes, change it in both.

### Correctness rules (non-negotiable)
- Analysis uses a MONO downmix for silence detection only. The producer cuts the
  ORIGINAL-channel audio at those timestamps — never from the downmix.
- Splices are zero-crossing-aligned + equal-power crossfaded. A hard cut is a bug (it
  produces the chopped/clicky artifact the feature exists to avoid).
- The original download is the source of truth and is never modified. Trimming is in-memory
  and live — there is no evictable trimmed-.m4a cache anymore.
- All persisted positions, bookmarks, and chapter marks are SOURCE-domain. Map to output time
  only at playback, via the live source↔output map. Never persist output-domain positions.
- Detection stability: a whole-file adaptive floor (`LiveSilencePrescan`) plus an absolute
  ceiling so continuous music beds are not cut.
- Multi-file books: one live producer session per original file (preserve file boundaries so
  the existing queue/gapless logic is untouched).

### Verification
- The `cadence` CLI in CadenceLab is the reference oracle: for the same input + tier, the
  splice output must match. Preset VALUES must stay identical to it.
- Analyzer (golden synthetic PCM) and policy (table-driven) tests live in SmartSpeechKit and
  must stay green before any by-ear tuning. Live-engine harness: `-livesmartspeechselftest`.