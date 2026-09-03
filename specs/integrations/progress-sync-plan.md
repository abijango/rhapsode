# Cross-device progress + stats (off the NAS)

**Status:** Phase A implemented on main (2026-09-03). GCP still later — do not implement until asked.  
**Date:** 2026-09-03  
**Supersedes:** NAS plan rows that put audiobook progress / SmartSpeech / collections on `Storage/rhapsode-sync/`

The NAS is the library. It is not reachable when travelling (no VPN / Tailscale). Phone and Mac must meet on an always-on store for resume, Nerd Stats, and collections.

## Locked product decisions

| Topic | Decision |
|-------|----------|
| Library | **SMB / NAS**, selective download, unchanged |
| Always-on store **now** | **Dropbox** app folder `/.rhapsode-sync` |
| Always-on store **later** | **GCP Firestore** on a new dedicated project (not `doubleword`) |
| Ebook position | **KOReader** remains authority (not Dropbox, not Firestore) |
| CloudKit / iCloud | No — no paid Apple Developer team |
| Tailscale / VPN | No |
| AWS / Cloudflare | Rejected for now. Cloudflare Worker+D1 is the fallback if Firestore is dropped |
| NAS after cutover | **One-time import**, then never write progress / stats / collections to the share |
| Stats | **True sum** across devices (per-device contributions). Not last-writer-wins on a single lifetime total |
| Resume position | Last-writer-wins by `updatedAt` (one playhead) |
| Collections | Existing merge-by-id + member union; transport is Dropbox now, Firestore later |
| Offline | Local outbox; auto-flush when the network returns |
| Live | Playing device pushes ~every 25s. Other device, app in foreground, applies without a manual refresh |
| Settings | Sync status, last success, pending count, last error, **Push now** |
| Seam | `ProgressSync` is the only write path. Player / Nerd Stats never import Dropbox or Firestore types |

## Do not do

- Reuse GCP project `doubleword` (it already has the account’s free-tier Firestore Native DB in `nam5`).
- Dual-write NAS + Dropbox after import (two authorities).
- Put ebook locators on Dropbox/Firestore while KOSync is configured.
- Workers KV, raw R2/S3, or DynamoDB for this (wrong consistency, signing, or wiring).
- `NSPersistentCloudKitContainer` on the SwiftData store (downloads and SMB config are device-local).

---

## Phase A — Dropbox now (implement when asked)

Library source stays `SmbLibrarySource` when SMB is preferred. Progress transport becomes `DropboxProgressSync` **at the same time**.

Today `SyncManager` picks one backend for both. That coupling is the bug: SMB-on means Dropbox is not written, so travel breaks phone↔Mac.

### A1. Decouple

- Choose `LibrarySource` as today: SMB → server → Dropbox.
- Choose `ProgressSync` independently: if Dropbox is connected (write scope), use `DropboxProgressSync`; else `NoopProgressSync` + Settings “Connect Dropbox for progress”.
- Both devices must use the **same Dropbox account**.

### A2. Outbox

Failed pushes are not an error banner on every pause.

- Persist dirty keys: audiobook `sourcePath`, book `fileRelPath` (only if KOSync is off), lifetime stats, collections kind.
- Flush on launch, on `NWPathMonitor` becoming satisfied, and on **Push now**.
- Pull (LWW / merge) then flush anything still newer locally so a home device is not clobbered by a stale outbox.

### A3. True-sum stats

Replace the single shared `cadence-stats.json` LWW record.

**Wire (Dropbox files, same folder):**

```text
/.rhapsode-sync/
  <sha256(sourcePath)>.json     # resume + this-file extras (see below)
  collections-audiobooks.json
  collections-books.json
  devices/
    <deviceId>/stats.json       # this device's lifetime saved + played
```

- Stable `deviceId` in Keychain (new, not the KOSync device id unless we explicitly alias).
- Each device writes **only** `devices/<id>/stats.json` with its own cumulative totals.
- Displayed lifetime = **sum** of all `devices/*/stats.json`.
- Recalculate on one device rewrites **that device’s** file only.

**Per-book listened / saved:** same problem as lifetime LWW/`max`. Store per-device contributions (in the progress JSON or `devices/<id>/books/<hash>.json`). Displayed per-book = sum. Local SwiftData keeps a display total plus a “mine” contribution so Recalculate cannot swallow the other device.

Resume fields stay one LWW record per book (current `PlaybackProgress` key).

### A4. Settings

A Progress sync row (not buried in Dropbox-as-library):

- Connected account / “not connected”
- Last successful pull / push
- Pending outbox count
- Last error (NAS import failure, 401, no write scope)
- **Push now**
- No modal on transient airplane-mode failures

### A5. NAS import (once)

On first launch after A1, if SMB is configured and Dropbox progress is empty-or-older:

1. Read `SmbProgressSync` (`Storage/rhapsode-sync/` or profile `syncPath`).
2. Merge into local (existing LWW / max / union rules).
3. Push the result to Dropbox (including a `devices/<this>/stats.json` seeded from local lifetime).
4. Persist `progress.import.nas.v1 = done`.
5. Never construct `SmbProgressSync` for writes again.

If Dropbox already has newer records, keep them; still stamp the import done so we do not loop.

### A6. Live (Dropbox)

Keep the existing `/.rhapsode-sync` longpoll while foregrounded. Opening the Mac app (or returning to it) must pull without Scan Now. No moving playhead; 25s push / longpoll apply is the bar.

### A7. Verification

- Phone listens on cellular; Mac on home Wi‑Fi (NAS up) — Mac playhead/stats move without NAS being in the path.
- Airplane mode on phone, listen, restore network — outbox flushes; Settings shows success; Mac sees it.
- Recalculate on Mac does not zero phone hours.
- Ebook with KOSync on does not write a book JSON to Dropbox.
- After import, writing a position does not create/update files under the NAS `rhapsode-sync/` folder.

---

## Phase B — GCP Firestore later (do not implement now)

Same `ProgressSync` + outbox + true-sum model. New conformer only.

### Account (already checked 2026-09-03)

| Fact | Value |
|------|--------|
| `gcloud` | 583.0.0 at `~/google-cloud-sdk/bin/gcloud` |
| User | `naufal.mir@gmail.com` (Owner where it matters) |
| Billing | **BillingAccount1** `013382-DA21FC-2B7FCA` open, GBP |
| Do not use | Project `doubleword` — Firestore Native `(default)` in `nam5`, `freeTier: true`, created 2025-10-09 |
| Also billed, no Firestore | `tabletop-scribe-488012`, `router-personal` |
| No billing | `gen-lang-client-0602798592` |

ADC was missing/expired; not required for the iOS client.

### B1. New project (ops)

Do not enable APIs on existing apps.

```text
Project:     rhapsode          (or rhapsode-sync if id taken)
Billing:     BillingAccount1
Firestore:   Native, Standard, one database
Location:    eur3 (Europe multi-region) — user is UK; nam5 only if we must match doubleword
Edition:     Standard, free-tier database on this project
```

Free quota (Spark / Firestore free DB): 1 GiB, 50k reads/day, 20k writes/day. Enough for this. **Billing is already on**, so exceeding quota **charges**. Dedicated project + tight rules keep usage tiny.

Firebase iOS app on that project. Google Sign-In with `naufal.mir@gmail.com` on phone and Mac (same account). Rules:

```
match /databases/{database}/documents {
  match /{document=**} {
    allow read, write: if request.auth != null
      && request.auth.token.email == "naufal.mir@gmail.com";
  }
}
```

Tighten to collection prefixes once the shape is stable. No world-readable API key as the only gate.

### B2. Document shape

Mirror Dropbox so import is mechanical:

```text
progress/{sha256(key)}           # PlaybackProgress (resume LWW)
devices/{deviceId}/stats         # lifetime contribution
devices/{deviceId}/books/{hash}  # per-book listened/saved contribution
collections/audiobooks
collections/books
```

`FirestoreProgressSync` implements `ProgressSync`. Snapshot listeners while foregrounded replace Dropbox longpoll (this is why Firestore is nicer later). Offline cache can back the outbox; keep the explicit outbox so Settings pending-count stays honest if we also support Dropbox.

### B3. Client

- Firebase iOS SDK (Auth + Firestore) **or** Firestore REST + Google Sign-In token. SDK is less work for listeners + offline.
- Settings: “Progress store: Dropbox | Firestore”, project/app ids from a small config, not hardcoded secrets beyond the normal `GoogleService-Info.plist`.
- One-time **Dropbox → Firestore** import (same as A5, other direction). Then Dropbox is unused for progress. Dropbox OAuth can stay for anyone still using Dropbox as a **library**.

### B4. Why not AWS / KV / R2

Recorded so this is not re-litigated:

- AWS DynamoDB always-free is real (25 GB provisioned) but iOS needs SigV4+IAM or API Gateway+Lambda+Cognito — more pieces than Firestore.
- S3 / GCS / R2 need object signing; no listeners.
- Workers KV: eventual consistency + 1k writes/day free + 1 write/sec/key. Wrong for a playhead.

Cloudflare Worker+D1 remains the portable HTTP alternative if we refuse Google on the client (Android-friendly, no Firebase SDK).

---

## Launch / agent notes

- **Do not start Phase B** until Phase A is shipping and the user asks.
- Phase A is the travel fix. Phase B is “leave Dropbox” with the same behaviour.
- `ProgressSync` will need richer stats APIs than today’s single `SmartSpeechStatsRecord` (per-device list + sum). Do that in A3 so B2 is a conformer, not a second stats model.
- `xcodegen generate` after any new files; do not hand-edit `Rhapsode.xcodeproj`.
- Self-test: outbox flush, LWW resume, sum-of-devices stats, NAS import idempotency, KOSync skip.

## Open when implementing A

- Dropbox write scope must be connected on **both** devices (craft backlog: confirm in Dropbox app settings).
- Whether Settings exposes “Disconnect Dropbox library” separately from “Disconnect Dropbox progress” (library is SMB; progress still needs Dropbox).
