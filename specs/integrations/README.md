# Rhapsode external integrations

## Active — implement this

| Path | Goal |
|------|------|
| **[rhapsode-server/](./rhapsode-server/)** | Self-hosted **Rust** API + **SQLite** + Docker: catalog, selective download, resume, SmartSpeech stats, later server-side Hardcover. Operator README + SPEC + PR plan. |
| **[progress-sync-plan.md](./progress-sync-plan.md)** | Library stays on NAS. Resume / Nerd Stats / collections: **Dropbox now**, **GCP Firestore later**. Do not implement Firestore until asked. |

**Model split for agents:** orchestrator **grok-4.5**; workers **grok-composer-2.5-fast** (`[subagents.models]` in `~/.grok/config.toml`).

## Do not implement

| Path | Contents |
|------|----------|
| **[DONOTIMPLEMENT/](./DONOTIMPLEMENT/)** | ABS secondary source, client Hardcover scrobble, old orchestration playbook — **reference only** |

## Product direction (summary)

```text
Rhapsode apps (iOS / later Android / Windows)
    = SmartSpeech player + Readium reader + offline cache
         │
         ▼  HTTPS + device token
Rhapsode Server (Docker on Synology)
    = library index + file gateway + progress + stats (+ Hardcover worker)
         │
         ▼
SQLite + bind-mounted media folders on NAS
```

Library path: SMB first; Dropbox remains the fallback library until/unless rhapsode-server ships. **Progress / stats / collections** are Dropbox now (not the NAS) — see [progress-sync-plan.md](./progress-sync-plan.md). Do not expand ABS or client Hardcover. Do not implement Firestore until asked.
