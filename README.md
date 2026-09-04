# Rhapsode

Offline-first audiobook and EPUB player for iPhone, iPad, and Mac Catalyst. Native SwiftUI, iOS 26.0 and up. Rhapsode downloads every file in full and plays it from local storage. Nothing streams.

The reason it exists is SmartSpeech. Rhapsode cuts the dead air out of narration while the audio plays, so a book finishes sooner without sounding chopped up.

<p align="center">
  <img src="docs/architecture.svg" alt="Rhapsode's four layers: SwiftUI presentation, domain and playback, library and sync behind a LibrarySource protocol, and SwiftData persistence." width="900">
</p>

## What it does

Four destinations: **Audiobooks**, **E-books**, **Nerd Stats**, and **Settings**. On iPhone you get tabs and a mini player, and the player covers the screen. On iPad and Mac you get a sidebar, and the player overlays the audiobooks column.

Audiobooks are single-file M4B or MP3 folders, both behind one `(trackIndex, offset)` model. You get play and pause, scrubbing, skip back 15 seconds and forward 30 seconds, and speed from 0.8x to 3.0x. There is a chapter list, a sleep timer, AirPlay, and lock-screen and Control Center controls. Books resume where you left them.

E-books render through foliate-js. You get light, dark, and sepia themes, font controls, a table of contents, and resume from a stored locator. Readium Streamer handles only import and metadata. It renders nothing.

Both shelves have collections and a **Continue** row. Search matches title and author.

## Library and progress

These are two separate systems, and confusing them is the usual mistake.

Rhapsode picks the library source once at launch. SMB NAS wins if you prefer it and configured it. Then rhapsode-server, if you prefer it and configured it. That path is parked. Dropbox is the fallback. Change the source under **Settings**, then quit and reopen the app.

SMB is the intended primary library. Remote books show as grey tiles you tap to download. Dropbox pulls new files on its own when it is the active library.

Downloads land in Application Support. SwiftData stores paths relative to that container.

Progress runs through Dropbox `/.rhapsode-sync` whenever a Dropbox token exists, even when your library lives on SMB. It covers resume positions, Nerd Stats, and collections. Open **Settings → Progress Sync** for the connection state, the pending count, and **Push now**. Offline writes stay pending until the next flush. The same Dropbox files are the planned Android sync path. No CloudKit.

Two merge rules, and they differ on purpose. Resume position is last-writer-wins, because only one device can be right about where you are. Listened time and saved time are summed across every device, so lifetime and per-book totals are true sums.

Configure **Settings → KOReader Sync** and KOReader owns ebook positions. Dropbox then stops writing them.

Rhapsode imports an existing NAS `rhapsode-sync` folder once, when SMB is configured and the share is reachable. After that it never writes the share for progress.

Rhapsode talks to Dropbox over the plain HTTP API, not the Swift SDK, using OAuth PKCE with the token in the Keychain. Access is app-folder only. The write scope exists for the progress JSON and nothing else.

## SmartSpeech

SmartSpeech trims silence live during playback. `AudiobookPlayer` drives an AVAudioEngine graph (`AVAudioPlayerNode → AVAudioUnitTimePitch → mixer`) fed by `LiveTrimProducer`, which decodes the original file and splices silence out on the fly. `LiveSilencePrescan` sets a whole-file adaptive floor so detection stays stable, and an absolute ceiling keeps continuous music beds intact.

SmartSpeech is off by default. Turn it on globally, pick **Default**, **More**, or **Aggressive**, and override the tier per book from the player's **SmartSpeech** sheet. **Nerd Stats** shows the time you reclaimed.

Three rules that must not regress:

- There is no trimmed copy on disk. The original download is the source of truth and is never modified.
- Persisted positions, bookmarks, and chapter marks are source-domain. They map to output time only at playback, through the live map.
- The analyzer detects silence on a mono downmix. The producer cuts the original channels, zero-crossing-aligned with equal-power crossfades. A hard cut is a bug.

`SmartSpeechKit` is a standalone Swift package that imports only Accelerate and AVFoundation. Its preset values must stay identical to the `cadence` CLI in CadenceLab.

## Build and test

Rhapsode is an XcodeGen project. `Rhapsode.xcodeproj` is generated and git-ignored, so edit `project.yml` and regenerate. Never hand-edit the `.xcodeproj`.

```bash
xcodegen generate

xcodebuild -project Rhapsode.xcodeproj -scheme Rhapsode \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

Run the DSP unit tests:

```bash
cd SmartSpeechKit && swift test
```

Two DEBUG harnesses check the non-UI invariants end to end. Each prints PASS or FAIL per check.

```bash
# container paths, sync pipeline, progress merge
xcrun simctl launch --console-pty <booted-device> com.naufalmir.rhapsode -phase0selftest 1

# live trim engine: resume, seek, music-bed sparing, multi-file
xcrun simctl launch --console-pty <booted-device> com.naufalmir.rhapsode -livesmartspeechselftest
```

## Constraints

Do not regress these:

- Dropbox over the HTTP API, not the SDK. App-folder access only, with every path relative to the app folder.
- Media in Application Support, not Caches. Relative paths in SwiftData, resolved through `ContainerPaths`.
- No paid entitlements. Local notifications, `BGTaskScheduler`, and background `URLSession` instead of APNs or iCloud.
- Framework callbacks hop to the main actor with `Task { @MainActor }`. Remote commands, the `URLSession` delegate, and audio engine callbacks all count. Several playback crashes came from skipping this.

## Docs

- [`docs/design.html`](docs/design.html) is an interactive design and architecture overview.
- [`specs/integrations/progress-sync-plan.md`](specs/integrations/progress-sync-plan.md) and [`specs/integrations/README.md`](specs/integrations/README.md) hold the current integration plans.
- [`docs/SPEC.md`](docs/SPEC.md) and [`docs/ROADMAP.md`](docs/ROADMAP.md) are older in places. Both still describe a Dropbox-first library and a two-tab shell.
