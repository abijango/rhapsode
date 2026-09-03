# Rhapsode craft backlog
Last updated: 2026-09-03

## Done
- [x] Unify player presentation (fullScreenCover from shelf + mini player)
- [x] Restyle mini player to Reclaimed (BrandFont, mint tint, progress strip, 8pt cover)
- [x] iOS 26 glass on floating chrome (mini player; player dock)
- [x] Cache shelf progress (`cachedFractionComplete` on persist/sync)
- [x] Stop observing all DownloadItems on shelves (SyncManager active-download set)
- [x] Parallel cover decode (4 concurrent; 96MB NSCache cost limit)
- [x] Thumbnail Now Playing artwork (CoverImageLoader + path cache)
- [x] Push on `.inactive` as well as `.background`
- [x] Save playback every 30s / on pause, not every 5s (AudiobookPlayer persist)
- [x] Defer launch scan until after first paint (ensureWatching)
- [x] Dictionary lookup on progress pull (SyncManager N+1 fetch-all per remote record)
- [x] Prescan only the active SmartSpeech tier
- [x] Align iPad/Mac CoverGrid headers with centered columns; cap iPad shelf bars at ~8pt
- [x] Replace scan ProgressView overlay with a material banner
- [x] Fix Nerd Stats ebookAccent on row bars/values
- [x] Collections merge-by-id instead of whole-manifest LWW
- [x] SMB: shorten/remove 5-min progress debounce (force pull on watch; 30s interval)
- [x] rhapsode-server: foreground progress poll + fix pullStats Date()
- [x] Reader font picker preview (sample paragraph uses selected face)
- [x] Mac menu play/pause via @FocusedValue; hover on transport/chips
- [x] Foliate WebView teardown (removeScriptMessageHandler + WKWebView release)
- [x] KOSync vs Dropbox: one ebook authority (skip ProgressSync when KOSync configured)
- [x] Sleep timer (session-only; dock moon + More menu)
- [x] Delete dead BookStatsReceipt / TrackListView (use `-previewplayer` page 2 for stats shots)
- [x] Reclaimed adaptive docs (AppAppearance + PlayerView comments match trait-adaptive palette)

## In progress / remaining

### Week 1
- [ ] Confirm Dropbox write scope (manual — user action in Dropbox app settings)

### This month
_(all items shipped — see Done)_

### Later
- [x] Progress off the NAS: Dropbox now (decouple + outbox + true-sum + import). GCP Firestore later. See `specs/integrations/progress-sync-plan.md`.

## Notes

**Shipped Week 1:** Single Music-style player entry via `fullScreenCover`; mini player Reclaimed + glass; cached shelf progress; narrow download-ID observation; parallel cover decode; lock-screen artwork cache; `.inactive` position save.

**Shipped This month:** 30s position persist (stats flush only when needed); deferred launch sync (watcher immediate, scan/progress after 1.5s idle); progress-pull dictionary maps; active-tier prescan only; centered iPad headers + 8pt shelf bars; material scan banner; Nerd Stats ebook amber accent; collections merge-by-id with member union; SMB/server progress watch at 30s with force pull; server `pullStats` uses remote `updated_at`.

**Shipped Later:** Reader font preview registers bundled/custom faces; Catalyst Playback menu + `.hoverEffect` on transport/mini player/chips; Foliate `destroy()` tears down WKWebView; KOSync owns ebook ProgressSync when configured; session sleep timer in player dock; removed unused BookStatsReceipt/TrackListView; Reclaim palette documented as trait-adaptive.

**Follow-ups:** Manual Dropbox write-scope check. On device, confirm deferred launch feels snappy, SMB/server handoff picks up remote progress within ~30s, and KOSync + Dropbox don't fight when toggling KOSync on/off mid-session.
