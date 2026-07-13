# NAS SMB library + sync (locked decisions)

**Status:** MVP A in progress  
**Date:** 2026-07-13

## Product decisions

| Topic | Decision |
|-------|----------|
| Primary remote library | **SMB** (Synology), LAN or Tailscale |
| Dropbox | Keep until SMB is solid, then remove |
| rhapsode-server | **Parked** (optional; lower priority than SMB) |
| Share layout | One share: `Audiobooks/`, `Books/`, `.rhapsode-sync/` |
| Library RO / sync RW | Single share with RW is fine |
| Play model | **Download first**, then play/read (no stream-for-SmartSpeech) |
| Selective download | Yes; grey remote tiles when online; **hide remote-only when offline** |
| New files | Foreground refresh + optional listing-diff badge (no push without infra) |
| Progress (audiobooks) | `.rhapsode-sync/` JSON (Dropbox-shaped) — **MVP B** |
| Progress (ebooks) | **P1: KOReader cloud only** from the app (not NAS JSON once KOReader client exists) |
| CrossInk X3 position | Same KOReader account as Rhapsode |
| CrossInk-style reading stats | Separate track: NAS stats exchange / CrossInk format (not KOReader Progress API) |
| Platforms | iPhone, iPad, Mac Catalyst |
| Later Android/Windows | SMB-friendly |

## Launch priority

1. `SmbConfig.shouldUseSmb`  
2. else `RhapsodeServerConfig.shouldUseServer` (parked)  
3. else Dropbox  

## MVP phases

- **A (done scaffolding):** SMB connect, list, selective catalogue, download  
- **B:** `SmbProgressSync` → `.rhapsode-sync` (audio + SmartSpeech + collections; **no ebook position** under P1)  
- **C:** polish grey tiles / offline hide (mostly already via selective catalog)  
- **D:** multi-SMB profiles  
- **E:** KOReader progress client in Rhapsode (ebook position)  
- **F:** CrossInk-compatible stats exchange  

## Synology setup (recommended)

```text
Share: Rhapsode  (or path on Storage)
  Audiobooks/
  Books/
  .rhapsode-sync/   # create empty; app may create later
```

User with read+write on the share. SMB enabled. Same host as Files/VidHub.
