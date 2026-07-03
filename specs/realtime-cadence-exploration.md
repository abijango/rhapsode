# Real-Time (Live) Cadence — Exploration Research Report

> **Status:** Exploration / spike. NOT a committed architecture. The shipped Cadence feature
> (`cadence-feature-spec.md`) — offline pre-render + AVPlayer — remains the production path and is
> untouched by this work.
> **Question this answers:** can we trim silences **live during playback** (stream the original
> downloaded file, detect + shorten gaps on the fly with look-ahead) instead of pre-rendering a trimmed
> `.m4a`? How well would it work, and is there a path to a platform-agnostic engine for future
> Android/Windows clients?
> **Companion plan:** `~/.claude/plans/the-app-currently-uses-streamed-corbato.md` (the spike build plan).

---

## 0. Executive summary

- **The DSP is the easy part; the playback engine is the hard part.** Rhapsode's existing
  `SilenceAnalyzer` / `SilencePolicy` / `OfflineTrimRenderer` (windowed-RMS detection, proportional
  compression, zero-crossing splice + equal-power crossfade) transfer to a live context nearly
  unchanged. What's genuinely new is replacing AVPlayer with a custom PCM pipeline that can splice and
  crossfade sample-accurately in real time.
- **AVPlayer cannot do this.** An `MTAudioProcessingTap` can observe/modify samples flowing through
  AVPlayer but cannot *delete frames* (output frame count must equal input). Variable-ratio silence
  removal therefore requires **`AVAudioEngine`** with self-scheduled `AVAudioPCMBuffer`s. This matches
  the one hard public data point: Marco Arment states Overcast's Smart Speed **could not be built on
  AVPlayer** — he wrote a custom Core Audio / vDSP engine.
- **Shipping apps shorten silence, they don't delete it.** Overcast and Pocket Casts both describe
  *tightening cadence*, not hard-cutting — identical in spirit to Rhapsode's proportional-compression
  policy. None publishes thresholds/window sizes. Real-world gains are proportional to how much dead air
  the *production* left in (heavy-pause content ~1.15–1.4× from Smart Speed alone; tightly-edited content
  ~1.0–1.06×).
- **For downloaded files, "on the fly" does not require causal detection.** Because the whole file is
  local, the recommended design is a **hybrid**: run CadenceKit's cheap analysis pass once at load
  (~thousands× realtime) to get the full region list + a static source↔output map + an exact time-saved
  number, then **splice live** during playback with no rendered file on disk. This preserves instant
  seeking, sidesteps the hard causal adaptive-threshold problem, and reuses the largest possible fraction
  of already-validated code.
- **Cross-platform: not Rust, not a portable decoder.** The right shared surface is a **C++ DSP core**
  (silence detect + splice/crossfade + time-stretch) fed by **native per-OS decoders** and driving
  **native per-OS output**. Native AAC decode is ~5–10× more power-efficient and handles HE-AAC that the
  pure-Rust Symphonia does not. Use **Signalsmith Stretch (MIT)** for time-stretch; avoid Rubber Band
  (App-Store-forbidden without a paid license) and GPL-mode FFmpeg.
- **Cost/benefit caveat.** Live processing means continuous decode + silence-DSP (+ time-stretch) for the
  whole session, vs. today's near-idle cached-file playback. The wins are: no render/cache lifecycle,
  instant tier/speed changes, exact instantaneous time-saved, and a portability precondition. The spike
  exists to measure whether naturalness, responsiveness, and battery justify that trade.

---

## 1. How live "skip silence" works in shipping apps

**Overcast (Smart Speed).** Marco Arment's own writeup frames it as *shortening* silences ("another
speed increment for free... without sounding weird"), built on a **custom Core Audio engine** with
"liberal use of low-level Accelerate vDSP operations" — explicitly **not** AVPlayer, which he says could
not implement it. Ran at full speed with low CPU on 2014-era iPhones (a useful feasibility signal — this
is not an exotic cost). No thresholds/window sizes ever published.
[marco.org/2014/07/16/overcast](https://marco.org/2014/07/16/overcast)

**Pocket Casts (Trim Silence).** "Remove silence... without altering the cadence of the podcast host."
Three discrete sensitivity levels (Mild / Medium / "Mad Max"), no numeric disclosure. Documented to
combine with variable speed. Independent review notes real failure modes on noise-gated shows and on
Japanese phonemic pauses (mis-trimming geminate consonants) — i.e. false positives from generic
RMS-threshold detection are a real, observed risk in a shipping product.
[blog.pocketcasts.com/2019/10/28/playback-effects](https://blog.pocketcasts.com/2019/10/28/playback-effects/),
[miyagawa.co/blog/pocket-casts-5-and-remove-silence](https://miyagawa.co/blog/pocket-casts-5-and-remove-silence)

**Snipd.** "Smart Speed" shortens pauses (~10–20% saved), no separate trim toggle, Flutter-based, no DSP
detail published. **Audible.** No equivalent marketed feature found.

**Takeaway:** every vendor converges on "shorten proportionally to gain time without sounding faster,"
none discloses parameters, and the one architectural fact available is that doing it live and well
required abandoning AVPlayer.

---

## 2. The real-time algorithm (look-ahead over a streaming PCM buffer)

**Why look-ahead.** You must confirm quiet *stays* quiet before acting (Rhapsode's `attackMs`/
`releaseMs`/`bridgeMs` hysteresis). Live, that means the engine must decode/analyze ahead of the audible
playhead. Zero look-ahead is the naive "compress every quiet frame instantly" approach that pumps/warbles.

**Look-ahead is cheap for a local file.** Two distinct numbers usually conflated:
1. **Decode look-ahead** — how far the decoder runs ahead of output. For a local file this is a buffering
   choice (seconds, essentially free), not a hard limit.
2. **Decision look-ahead** — how much decoded audio the detector needs before committing to a region.
   Bounded below by the confirm window (tens of ms), above by acceptable start/seek latency.

**Two buffers, not one.** Analysis runs on a **mono downmix** (cheap, small); the splice cuts the
**original-channel** PCM — a non-negotiable Cadence rule that does not change live. So the engine holds
original-domain PCM for as long as a candidate region is "pending" (until release/bridge confirms it).

**Click avoidance is the same DSP, harder plumbing.** Zero-crossing alignment + equal-power crossfade
(Rhapsode uses `crossfadeMs` 15–18, `edgeGuardMs` 32–40). The new constraint: **live must not let a
candidate region's provisional treatment reach the speaker before the region is confirmed** — offline can
be wrong and simply discard; live has already played it. This is what the decision-look-ahead buffer buys
time for.

**Pipeline shape:**
```
[File on disk] → [Decoder, ahead] → [PCM ring buffer]
     → mono downmix → windowed-RMS detector (reuse SilenceAnalyzer window/hop/hysteresis/bridge)
     → region state machine (open/extend/close on release+bridge confirm)
     → splice engine (zero-crossing snap on ORIGINAL channels + equal-power crossfade)
     → [output ring buffer] → render callback
```

---

## 3. Silence detection in real time

**Transfers almost unchanged from `SilenceAnalyzer.swift`:** 20 ms window / 10 ms hop windowed RMS
(`vDSP_rmsqv`, `20·log10`); **adaptive** threshold = `min(noiseFloor + thresholdMarginDb,
speechLevel − 3 dB)` from 10th/90th percentiles; hysteresis (20 ms attack/release), 40 ms bridge,
edge-guard inset then `minSilenceDuration` gate. The `detectRegions()` state machine is already an
incremental left-to-right scan — feed it one hop at a time. Independently corroborated by WebRTC VAD
(10/20/30 ms frames), Silero VAD (hysteresis by design), and rhasspy-silence state machines.

**What's different live (and why the hybrid wins):**
- **Global statistics are unavailable causally.** The adaptive floor needs the whole section's dB
  distribution (a full percentile sort — non-causal). Live options: delay activation to accumulate
  history; use a conservative fixed threshold for the first N seconds; or **reuse a precomputed profile**
  (the hybrid).
- **A seek invalidates local statistics** → re-warm-up window unless a cached profile exists.
- **Errors are cheap offline, audible live.** A false positive live compresses real content in front of
  the listener (the documented Pocket Casts failure mode). Argues for either more conservative live
  thresholds or precomputing detection — which CadenceKit already does cheaply.

---

## 4. Interaction with time-stretching (variable speed)

- **Order: trim first (source domain), then stretch.** Detection is more accurate on unstretched audio,
  it mirrors the shipped pipeline (render trimmed source, then AVPlayer applies `rate`), and it keeps the
  detector's tuned constants valid at any rate. Graph: PCM ring buffer → silence splicer → time-stretch →
  output.
- **Mechanism:** WSOLA (SoundTouch family, ~100 ms latency) or phase-vocoder. On Apple,
  `AVAudioUnitTimePitch` (pitch-preserving) has ~90 ms render latency; `AVAudioUnitVarispeed` changes
  pitch too (not wanted). These latencies stack with detector look-ahead but a few-hundred-ms total delay
  is imperceptible for passive listening.

---

## 5. Seek / position mapping (the biggest new problem)

Offline, the source↔trimmed map is static (built once at render). Live, it's constructed continuously.
Consequences and mitigations:

- **Anchor position/scrubbing in SOURCE time** (already Cadence's rule). Then seek is an instant
  source-time seek; the engine resumes detection/splice from there. Displayed numbers stay in known,
  exact source duration.
- **Hybrid (recommended): precompute the analysis pass, skip the render.** Keep `SilenceAnalyzer` at
  load to get the FULL region list + FULL trimmed-duration + a static source↔output map, then splice live
  from the original. Yields: exact time-saved immediately; seeking identical to today (map lookup); no
  extra disk/cache; and removes the "adaptive threshold needs history" problem entirely. The only cost
  moved live is the splice/crossfade execution (already solved & tuned).
- **Pure causal detection** is only worth it for a future *not-yet-fully-downloaded / streamed* playback
  mode — out of scope for this spike (files download whole first).

---

## 6. iOS engine: concrete API map (AVAudioEngine)

| Concern | Answer |
|---|---|
| Node that accepts your own PCM | `AVAudioPlayerNode.scheduleBuffer(_:at:options:completionHandler:)` with a self-built `AVAudioPCMBuffer` |
| Production seam choice | Producer thread + `scheduleBuffer` (forgiving), **not** `AVAudioSourceNode` (hard real-time render thread — wrong for RMS/crossfade work) |
| Decode | `AVAudioFile.read(into:)` (simple, fine for `.m4a/.m4b`) or `AVAssetReader` + `AVAssetReaderTrackOutput` w/ `AVFormatIDKey: kAudioFormatLinearPCM` (more control, MP3-robust) |
| Two derived streams | `AVAudioConverter` for mono downmix (analysis) + sample-rate match to hardware; decode once, derive both — never decode twice |
| Silence-trim seam | In the producer loop, before `scheduleBuffer` — not a graph node; reuse CadenceKit detect/snap/crossfade per-chunk with a look-ahead window |
| Speed | `AVAudioUnitTimePitch` (NOT Varispeed), downstream of the player node, upstream of the mixer |
| Position | `playerNode.playerTime(forNodeTime: playerNode.lastRenderTime).sampleTime` → output frames → map through your (sourceStart,sourceEnd,outputDur) segment table → source seconds. **No divide-by-rate** (TimePitch pulls `rate×` frames upstream) |
| Now Playing / remote | Fully manual: `MPNowPlayingInfoCenter` / `MPRemoteCommandCenter`, update on a timer, `changePlaybackPositionCommand` feeds seek (source-domain) |
| Seek | `playerNode.stop()` (clears entire schedule) → reposition decoder → reset producer/lookahead → refill → `play()`; expect a small gap; debounce during active scrub |
| Lost vs AVPlayer | Auto-pause on interruption/route-change, did-finish notification, cheap frame-accurate seek, Now-Playing auto-sync — all become your responsibility |
| Background/session | `AVAudioSession(.playback, .spokenAudio)` + `UIBackgroundModes: audio` (same as today) |
| Config-change | Observe `AVAudioEngineConfigurationChangeNotification` (route/sample-rate change) → reconnect/reformat before `engine.start()` |

**CPU/battery reality.** TimePitch (continuous phase-vocoder-class DSP), continuous decode, and
continuous silence-DSP are real sustained costs vs. today's cached-file idle. None approaches thermal
throttling (sustained speech DSP is a low-power class), but multi-hour battery is the risk to profile.
Recommendation from the iOS research: consider scoping live processing to "instant preview / tier-switch
without re-render" layered on the pre-render pipeline, rather than a wholesale replacement — decide after
the spike measures it.

---

## 7. Platform-agnostic core (future, if the spike proves out)

**Decode portability is the trap; DSP portability is the prize.**

- **Symphonia (pure Rust):** MP3 + AAC-LC good, MP4/M4A demux good — but **HE-AAC/HE-AACv2 (SBR/PS) not
  implemented** (common in low-bitrate audiobooks), no chapter-atom parser, no DRM. The workaround
  (`symphonia-adapter-fdk-aac`) leaves pure-Rust territory and wraps Fraunhofer C.
- **miniaudio / dr_libs (C):** WAV/FLAC/MP3 only — **no AAC decoder anywhere**.
- **Time-stretch has no mature Rust-native option:** rubato is a *resampler* (re-pitches, unusable
  alone); credible stretchers are all C/C++ — **Signalsmith Stretch (MIT, header-only, sweet spot
  0.75–1.5×, validate to 3×)**, SoundTouch (LGPL/commercial, WSOLA), Rubber Band (GPL/commercial).
- **All three OSes ship hardware AAC decoders** (AudioToolbox / MediaCodec / Media Foundation), ~5–10×
  more power-efficient, with years of malformed-file hardening. Using native decode does **not** break
  media-session integration (ExoPlayer's FFmpeg renderer, Windows SMTC manual mode, and
  `MPNowPlayingInfoCenter`'s plain dictionary all confirm this).

**Recommended architecture (Option B — native decode, portable DSP):**
```
per-OS native decode (AudioToolbox / MediaCodec / Media Foundation) → PCM
   → shared C++ DSP core: silence detect (look-ahead) + zero-crossing splice + equal-power crossfade
                          + pitch-preserving time-stretch (Signalsmith Stretch; SoundTouch fallback)
                          + scheduling / ring-buffer hand-off      [narrow surface: push(pcm)->pcm + config]
   → per-OS native output (AVAudioEngine / AAudio·Oboe / WASAPI) + native media-session
```
**Language: C++, not Rust.** Once decode + output are native, Rust's draws (Symphonia, cpal) are gone,
and every time-stretch library is C/C++ (linking directly from C++, needing FFI glue from Rust). Real-time
discipline (no alloc/locks/syscalls on the audio thread) applies in any language.

**Licensing flags:** Signalsmith Stretch MIT (safe), Symphonia MPL-2.0 (app-safe), cpal Apache-2.0
(safe), miniaudio/dr_libs public-domain (safe); **SoundTouch LGPL** (iOS static-linking ambiguity —
buy commercial to remove doubt), **Rubber Band GPL/commercial** (App Store forbidden without a paid
license — VLC precedent), **FFmpeg** LGPL default / GPL if `--enable-gpl` (avoid GPL builds). Since the
recommendation keeps decode native, the only place LGPL resurfaces is if SoundTouch is chosen for
time-stretch — default to Signalsmith to sidestep it.

---

## 8. Where this binds to the existing app

- **Downloaded original is a plain local file** at `ContainerPaths.url(forRelativePath: track.fileRelPath)`
  under Application Support/Media, guaranteed fully-downloaded before import completes
  (`BackgroundDownloader` → `AudiobookImporter`). The live engine consumes exactly this.
- **Interposition seam** in the shipped code is `AudiobookPlayer.loadCurrentItem` / `trimmedSource`
  (chooses trimmed-vs-original) — but the spike does **not** touch it; it stands up its own isolated
  engine + DEBUG screen.
- **Reusable DSP** lives in `CadenceKit` (`SilenceAnalyzer`, `SilencePolicy`, `OfflineTrimRenderer`,
  `AudioIO`, `CadenceSettings`) — Accelerate + AVFoundation only, already standalone.
- **Correctness oracle:** the `cadence` CLI in CadenceLab and `OfflineTrimRenderer` produce the reference
  output; the live engine's spliced PCM for the same input+tier must match within encoder tolerance
  (CLAUDE.md's reference-oracle discipline).

---

## Sources

**Shipping apps / technique:** marco.org/2014/07/16/overcast · marco.org/2020/01/31/voiceboost2 ·
medium.com/@eped/overcasts-smart-speed-vs-real-time · blog.pocketcasts.com/2019/10/28/playback-effects ·
support.pocketcasts.com/knowledge-base/playback-effects · miyagawa.co/blog/pocket-casts-5-and-remove-silence ·
snipd.com/all-features

**DSP / VAD / splicing:** pavi2410.com/blog/detect-silence-using-web-audio · github.com/wiseman/py-webrtcvad ·
github.com/rhasspy/rhasspy-silence · arunbaby.com/speech-tech/0004-voice-activity-detection ·
avsforum zero-crossing thread · kvraudio equal-power crossfade thread · audiodrome.net/glossary/crossfade ·
practicesession.app/blog/wsola-deep-dive · surina.net/soundtouch/README.html

**iOS engine (Apple):** developer.apple.com/documentation/avfaudio/{avaudioengine, avaudioplayernode,
avaudiounittimepitch, avaudiosourcenode} · .../avfoundation/avassetreadertrackoutput ·
developer.apple.com/forums/thread/708168 (TimePitch latency) · asciiwwdc.com/2014/sessions/502 ·
developer.apple.com/videos/play/wwdc2019/510 · Audio Session Programming Guide (interruptions)

**Portability / decode / licensing:** github.com/pdeljanov/Symphonia (README, issues #189/#473/#512/#513) ·
github.com/aschey/symphonia-adapters · github.com/HEnquist/rubato · github.com/Signalsmith-Audio/signalsmith-stretch ·
signalsmith-audio.co.uk/writing/2023/stretch-design · surina.net/soundtouch · breakfastquay.com/rubberband/license.html ·
github.com/mackron/miniaudio · github.com/irmen/pyminiaudio/issues/53 · github.com/mackron/dr_libs ·
ffmpeg.org/legal.html · wiki.hydrogenaudio.org (Libavcodec AAC) · developer.apple.com/documentation/audiotoolbox/encoding-and-decoding-audio ·
developer.android.com/reference/android/media/MediaCodec · learn.microsoft.com/.../medfound/aac-decoder ·
learn.microsoft.com/.../system-media-transport-controls · github.com/google/ExoPlayer .../ffmpeg ·
arxiv.org/pdf/2110.06529 · arxiv.org/html/2402.09001v1 · github.com/tanersener/mobile-ffmpeg (wiki, issue #346) ·
lwn.net/Articles/525718 · lwn.net/Articles/526355 · github.com/RustAudio/cpal · github.com/mgeier/rtrb

**Internal (ground truth):** `CadenceKit/Sources/CadenceKit/{SilenceAnalyzer,OfflineTrimRenderer,AudioIO,SilencePolicy,CadenceSettings}.swift` ·
`Sources/Cadence/{CadenceRenderer,CadenceRenderCoordinator,TrimmedRendition,CadenceTimelineMap}.swift` ·
`Sources/Audiobook/AudiobookPlayer.swift` · `Sources/Support/ContainerPaths.swift` ·
`specs/cadence-feature-spec.md` · `specs/cadence-derisk-harness-spec.md`
