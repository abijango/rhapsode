# SmartSpeech v2 — implementation handoff

Status: plan only, 2026-09-23. No implementation is authorized by this document.

## Objective and non-negotiables

Deliver natural pause compression, conservative skipping of *music-only* passages,
optional natural-sounding smart speed, and fast replay of previously analysed
books. Never cut intelligible speech, singing, speech over music, uncertain audio,
or an unclosed music region. Preserve source-domain seek/progress, accurate
actually-listened reclaimed stats, and uninterrupted lock-screen playback. If
analysis or DSP fails, play the original audio or use the existing silence-only
path; never stall, skip unverified content, or silently overstate savings.

The v2 foundation is **already in the working tree**, not necessarily in `HEAD`:
`SmartSpeechKit/Sources/SmartSpeechKit/SemanticEditMap.swift` has a semantic
planner and exact source-time edits; `LiveTrimProducer` renders them and falls
back to rolling RMS; `LiveSilencePrescan` runs a foreground full-file scan and
is cancelled in background. The current detector is RMS-only: a `musicOnly`
enum case does **not** imply music detection is shipped. `LiveAudioBackend`
currently uses `AVAudioUnitTimePitch`, not Rubber Band. Recent route/Now Playing,
stats sync, versioning, and icon changes are also uncommitted. Preserve them;
do not reset, stash, overwrite, or assume a fresh worktree contains them.

## Gate 0 — establish a reproducible baseline

Owner: root/orchestrator; no builder until the user confirms a successful
1–2-hour mostly locked *Goblet of Fire* run on the same preset, with before/after
per-book saved/listened values, audible notes, battery/heat observation, and
exported diagnostics. Also verify AirPods removal/reinsertion and lock-screen
play-state on a build containing the route fix; the earlier archive identified
itself as build 0.1.0 (3), not the new candidate. CoreDevice connection failures
are an environment gate, not a SmartSpeech regression. Document actual installed
app version/build and device OS for every run.

The orchestrator inventories the exact dirty tree and captures a reproducible,
owner-approved integration baseline **without discarding or committing user work**.
Separate root threads/worktrees must receive that same baseline, including
untracked files, or wait until the owner has made a safe snapshot. Do not let an
agent silently start from `HEAD` and re-create the v2 foundation differently.

## Sol execution contract — repeat for each bounded issue

For each issue below, create a fresh root thread and keep it bounded. Terra/root
owns requirements and integration. Spawn exactly one Sol `architect` to produce
the design, then Luna `test_writer` and wait. Once the tests and interfaces are
fixed, spawn parallel Luna `implementer` builders for independent slices with
explicit, disjoint write scopes; otherwise use one builder. Wait for **all**
builders, integrate shared entrypoints serially, run `validator` on the combined
tree, then exactly one Sol `reviewer`. If review finds a material defect, allow
one owning-builder repair, integrated validation, and at most one re-review.
Pass concise reports and log paths, not entire build logs. Builders preserve
other agents' edits and never edit each other's files, generated project files,
or shared build configuration. Parallel research can prepare the next issue.
Do not broaden an issue mid-flight: open a new root for the next deliverable.

For every user-visible device-build handoff, bump once via `scripts/build.sh`
or `scripts/next-build.sh` (patch fixes/tuning, minor feature, major only for an
explicit breaking/major release). No version bump for planning, exploratory
builds, or test iterations. Do not edit generated Xcode files or Info.plist.

## Issue A — diagnostics and pause quality (first builder)

Scope: `Sources/SmartSpeechLive/LiveTrimProducer.swift`,
`LiveSilencePrescan.swift`, diagnostic emission, focused SmartSpeechKit planner/
renderer tests, and audio fixtures only. Add bounded, privacy-safe diagnostics
for analysis coverage/fallback, candidate vs realized removed seconds by edit
kind, seam extensions, render underruns/late refills, and foreground/background
transitions; do not log audio or transcript content. Capture a small consented
sample corpus: quiet consonants, breaths, music beds, variable noise, long pauses,
and chapter/decode seams. Compare source excerpts with rendered output at 1×
and existing speed settings. Freeze current thresholds first; change one policy
variable at a time only if observations show a problem. Repeated prescan
start/cancel cycles should not introduce gaps or heavy work while locked.

Acceptance: package planner/renderer tests cover seam-crossing edits, short
pauses, uncertain/speech protection, splice peak and boundary continuity; app
tests cover foreground-to-lock fallback and stats counted on actual playback,
not analysis. Human A/B listening records any clipped syllable or audible join
with source time. No regression against Gate 0 in savings, CPU, startup, or
lock-screen stability. If baseline is clean and metrics insufficient, deliver
diagnostics and fixtures without speculative DSP tuning.

## Issue B — music-only classification and safe edit map

Depends on A's test corpus/diagnostics. Keep Apple's `SoundAnalysis` adapter in
`Sources/SmartSpeechLive/` (not in the framework-independent planner); keep
semantic policy and edit-map invariants in `SmartSpeechKit/`. Use timed,
overlapping classification windows and inspect the installed classifier's
`knownClassifications` rather than assuming label names or supported window
durations. Make inference cancellable and budgeted. A single high music score
does not prove speech is absent: require positive sustained music evidence and
independent speech/voice protection over the entire candidate interval. Any
speech, singing, uncertain classification, short cue, missing context, or music
region with unknown end is *kept*. Protect joins with calibrated handles and a
content-appropriate crossfade. Combine silence and music edits into one ordered,
non-overlapping source-time map; do not pass music to `SilenceRegion` compression.

Decide the analysis horizon and background budget in the Sol architecture. Keep
the existing rolling RMS playback fallback while classification is incomplete;
never promise music removal beyond analysed coverage. Test a long music intro,
short stinger, speech over music, quiet voice, singing, music ending at speech,
chapter seam, long unclosed music, classifier failure, and immediate lock.
Release gate: *zero known speech cuts* in the curated corpus and a manual
blind-listening review. Flag music skipping separately from silence trimming so
it can be turned off without disabling safe pause compression.

## Issue C — persistent source-time decision cache

Can run after B stabilizes its map schema/policy. Cache codec/validation tests
and a standalone storage adapter can be built in parallel in disjoint files;
its integration into
`AudiobookPlayer.swift` and `LiveTrimProducer.swift` is serialized after B.
Store compact finalized source-time regions/edits and analysis metadata, **not**
PCM, session-relative rendered timing, or a mutable playback clock. Use an
atomic, versioned cache record in app-managed storage, keyed by a stable media
identity plus size/modification/content fingerprint, duration, cut points,
selected tier, analyzer/classifier version, policy revision, and format. Limit
disk use; clean up on deletion and evict old entries. Load asynchronously before
full prescan; on a miss, stale/corrupt record, changed media/tier/policy, or
partial analysis, retain rolling fallback and rebuild without blocking play.

Tests: cold/warm start, different tiers sharing a file, mutation with same path,
truncated/corrupt cache, concurrent write/read, cancellation, eviction/delete,
and source seek across cached edits. Measure warm startup and decoded work, not
just cache-hit count. Cache must never create a new silence/music cut from a
partial analysis result.

## Issue D — optional Rubber Band R3 smart speed

Research/design can proceed read-only while B/C build. **Do not vendor, link, or
ship Rubber Band until a compatible distribution licence is secured.** The
vendor documents GPL/commercial licensing and real-time R3 padding/start-delay
requirements. If unavailable, leave `AVAudioUnitTimePitch` in place and make
this issue a measured comparison/prototype only. The Sol architecture must
choose the native C++ bridge and integration point after the existing splice,
with R3 as an optional selected backend and the old path as a runtime fallback.

Define a bounded speech-rate controller separately from pause removal: no
speed-up near speech onset/ends, music, singing, or uncertain regions; user speed
remains authoritative. Smooth transitions and compensate R3 start padding,
latency, and output availability. Maintain separate source time, trimmed content
time, stretched audible time, and wall time; changing rate must not inflate
reclaimed time or break seeks, chapters, Now Playing, sync, or smart resume.
Tests cover 1× parity, rate ramps, 1×↔3×, stereo, short buffers, seek/route/
interruption, R3 errors, and long playback. Compare blind-listening quality,
latency, CPU/battery, and thermal behavior to `AVAudioUnitTimePitch` before
choosing a default. Integrate on the shared producer/backend files only after
B/C have landed and validated.

## Issue E — integrated device/endurance release gate

Not a parallel feature builder: validator plus user/on-device testing after
integration. Run M4B and multi-file MP3, foreground and 1–2+ hours locked,
AirPods removal/reconnection/remote pause, calls/interruption, app/background
transitions, chapter seek, rapid play/pause, rate and preset changes, cache
hit/miss/invalidation, music-only and speech-over-music samples. Capture version,
device/OS, preset, exact saved/listened deltas, CPU/thermal/battery, late buffers,
start latency, and any crash/MetricKit report. Compare against A and Gate 0.
Confirm lock-screen icon matches audible state and saved time never includes
skipped seeks or purely accelerated speech. Ship only if no known speech loss,
unexplained autoplay, timeline/stat drift, or severe resource regression; else
disable the new classifier/R3 independently and retain the stable fallback.

## Dependency/parallelism map

Gate 0 → A → B → C → D integration → E. Parallel read-only tracks while A/B
implement: Apple classifier capability/label evaluation; R3 licence/native
latency feasibility; cache fingerprint/eviction design; sample corpus annotation.
Within B, separate Luna builders can own the new SoundAnalysis adapter and
SmartSpeechKit semantic policy/tests after the test writer finishes; the root
integrates the resulting map into playback afterward. Within C, independent
builders can own cache codec and storage adapter. Within D (only after a licence
decision), native R3 bridge and isolated rate-policy code can be built in
parallel, then joined at the producer/backend seam. Assign each a non-overlapping
path list before spawning; if an interface is still unsettled, serialize instead.
`LiveTrimProducer.swift`, `LiveAudioBackend.swift`, `AudiobookPlayer.swift`,
`SemanticEditMap.swift`, and `project.yml` are shared integration points: one
owner per file at any instant. Regenerate XcodeGen and run validation only after
integration, not while builders write. Each issue produces a short handoff with
changed files, known risks, test commands/results, logs by path, device-only
checks, and whether the feature remains behind a fallback.
