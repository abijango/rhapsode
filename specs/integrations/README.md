# Rhapsode external integrations

## Active — implement this

| Path | Goal |
|------|------|
| **[rhapsode-server/](./rhapsode-server/)** | Self-hosted **Rust** API + **SQLite** + Docker: catalog, selective download, resume, SmartSpeech stats, later server-side Hardcover. Operator README + SPEC + PR plan. |

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

Dropbox remains the **current shipping** iOS library path until the client is wired to Rhapsode Server. New work should not expand ABS/Dropbox/Hardcover client integrations while the server path is active.
