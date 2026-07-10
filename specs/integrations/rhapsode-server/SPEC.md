# Rhapsode Server — technical specification

**Status:** IMPLEMENT (active path)  
**Audience:** Implementers (orchestrator Grok 4.5; workers Composer 2.5)  
**Repo layout (target):** top-level crate/workspace `rhapsode-server/` alongside the iOS app (or monorepo sibling). Do not put server code under `Sources/` (Swift).

---

## 1. Goals

1. Self-hosted **Rust** HTTP API for personal Rhapsode use on **Docker** (Synology first).  
2. **SQLite** as the only database for v1.  
3. Index audiobooks + EPUBs from bind-mounted library folders.  
4. **Selective** media download (catalog ≠ download).  
5. Store **resume progress** and **SmartSpeech / Nerd Stats** in SQLite (first-class).  
6. **Device bearer-token auth**; suitable behind reverse proxy / Tailscale.  
7. Clients are offline-capable players/readers; server is source of truth for sync.  
8. **Hardcover scrobble on the server** (phase after core API).  
9. Same image runnable later on a VPS without redesign.

### Non-goals (v1)

- Multi-tenant SaaS, billing, public signup  
- Streaming into SmartSpeech (clients download full files)  
- Transcoding / HLS  
- Podcasts  
- Full metadata editor UI (minimal scan + API is enough)  
- Dropbox / ABS client integrations (see `../DONOTIMPLEMENT/`)  
- Changing iOS SmartSpeech DSP  

---

## 2. Default stack

| Layer | Choice | Notes |
|-------|--------|--------|
| Language | **Rust** (edition 2021+) | |
| HTTP | **axum** | Tokio runtime |
| DB | **SQLite** via **sqlx** (runtime) or **rusqlite** + migrations | Single file under `DATA_DIR` |
| Migrations | **sqlx migrate** or **refinery** | Applied on startup |
| Auth | Bearer **device API tokens** (SHA-256 hash stored) | |
| Files | `tokio` / `tower-http` file response | Authenticated |
| Config | env vars (+ optional `config.toml`) | 12-factor |
| Container | Distroless or `debian-slim` multi-stage build | |
| Compose | `docker-compose.yml` | data volume + library bind mounts |
| Logging | `tracing` + `tracing-subscriber` | JSON optional |
| API style | **REST + JSON** | Version prefix `/v1` |

### Why SQLite

- Perfect for single-user Synology  
- Zero extra containers  
- Easy backup (copy `rhapsode.db`)  
- Upgrade path: later Postgres via sqlx if multi-instance cloud needs it (not v1)

### Recommended crates (defaults)

- `axum`, `tokio`, `tower`, `tower-http` (trace, cors if needed, limit)  
- `sqlx` with `sqlite`, `runtime-tokio`, `migrate`  
- `serde` / `serde_json`  
- `uuid`, `chrono` or `time`  
- `sha2`, `rand` / `uuid` for tokens  
- `thiserror`, `anyhow` (or `eyre`) at edges  
- `tracing`  
- Optional later: `aes-gcm` for encrypting Hardcover token at rest  

---

## 3. High-level architecture

```text
Client                         rhapsode-server
  │                                 │
  │  Authorization: Bearer <token>  │
  ├──── GET  /v1/library ──────────►│  SQLite index
  ├──── POST /v1/library/scan ─────►│  walk mounts
  ├──── GET  /v1/items/:id/files/.. ►│  stream file bytes
  ├──── PUT  /v1/items/:id/progress ►│  resume
  ├──── PUT  /v1/items/:id/stats ──►│  SmartSpeech extras (max-merge)
  └──── GET  /v1/stats/lifetime ───►│
                                    │
                         optional worker ──► Hardcover GraphQL
```

**Merge rules**

| Data | Rule |
|------|------|
| Resume position / locator | Last-write-wins by `updated_at` (client sends timestamp; server rejects older) |
| `saved_seconds`, `listened_seconds`, `reading_seconds`, lifetime totals | **`max(server, client)`** (monotonic) |
| Finished flag | LWW by `updated_at`; finishing sets `finished_at` |

**Positions**

- Audio: **source-domain seconds** (original file timeline — never SmartSpeech output time)  
- Ebook: `ebook_progression` 0…1 + optional `ebook_locator_json` (Readium Locator string)

---

## 4. Configuration (environment)

| Variable | Required | Description |
|----------|----------|-------------|
| `RHAPSODE_DATA_DIR` | yes | Directory for `rhapsode.db` and secrets |
| `RHAPSODE_LIBRARY_AUDIO` | yes | Root path for audiobook files |
| `RHAPSODE_LIBRARY_EBOOK` | yes | Root path for EPUBs |
| `RHAPSODE_BIND` | no | Default `0.0.0.0:8080` |
| `RHAPSODE_BOOTSTRAP_TOKEN` | bootstrap only | One-time create first device |
| `RHAPSODE_LOG` | no | `info` / `debug` |
| `RHAPSODE_CORS_ORIGINS` | no | Empty = no browser CORS needed for native apps |

---

## 5. Authentication

### Model

- **Device** belongs to single **user** (v1: one user row is fine).  
- Plaintext token shown **once** at creation: `rhp_<random 32+ bytes url-safe>`.  
- Store only **SHA-256 hex** (or keyed hash) of token in `devices.token_hash`.  
- Request header: `Authorization: Bearer <token>`.  
- Middleware loads device → user; 401 if missing/revoked.

### Endpoints

| Method | Path | Auth | Purpose |
|--------|------|------|---------|
| POST | `/v1/auth/bootstrap` | `X-Bootstrap-Token` | Create first user+device if none exist; or gated by env |
| POST | `/v1/auth/devices` | Bearer | Create additional device |
| GET | `/v1/auth/devices` | Bearer | List devices (id, name, platform, created, last_seen) |
| DELETE | `/v1/auth/devices/{id}` | Bearer | Revoke device |
| GET | `/v1/me` | Bearer | User + current device info |

Bootstrap rules:

- If `RHAPSODE_BOOTSTRAP_TOKEN` unset and no users → 503 with message to set token.  
- If users already exist → bootstrap disabled (404/403) unless you add explicit “allow bootstrap” later.  
- Always clear bootstrap env after first use in production (operator README).

### Security defaults

- Constant-time compare for bootstrap token  
- Rate-limit auth routes in-process (simple token bucket)  
- No token in logs  
- HTTPS terminated at reverse proxy  

---

## 6. Library scanning

### Roots

- Audio root: `RHAPSODE_LIBRARY_AUDIO`  
- Ebook root: `RHAPSODE_LIBRARY_EBOOK`  

### v1 discovery heuristics (document in code; adjustable later)

**Audio item**

- File with ext `m4b`, `m4a`, `mp3`, `flac`, `aac`, `ogg` **alone in a book folder** or single file under author → one item  
- Multiple audio files in one directory → one multi-file item (ordered by filename)  
- Skip hidden (`.`) and `@eaDir` (Synology)

**Ebook item**

- Ext `epub` only in v1  

**Identity**

- Stable `id` = UUID stored in DB  
- `content_key` = hash of relative path(s) + sizes (or path string) for upsert on rescan  
- Do not delete DB progress when file temporarily missing — mark `missing=true`

### Scan API

- `POST /v1/library/scan` → runs scan (async job or sync for v1 personal sizes)  
- `GET /v1/library/scan/status` if async  

### Catalog API

- `GET /v1/library?kind=audio|ebook|all`  
- `GET /v1/items/{id}`  
- Response includes: id, kind, title, author, duration_s (audio), size_bytes, has_audio, has_ebook, cover_path available, updated_at, missing  

Covers: `GET /v1/items/{id}/cover` if file found (`cover.jpg`/`cover.png` or embedded later).

---

## 7. Media download

- `GET /v1/items/{id}/files` → list file ids, names, sizes, roles (`audio`/`ebook`)  
- `GET /v1/items/{id}/files/{file_id}/download` → stream bytes with `Content-Type`, `Content-Length`, support **Range** requests if practical (nice for resume downloads)  

Auth required. Path traversal impossible (resolve via DB file id only).

**Clients** download selected items only into local storage; server never pushes multi-GB unsolicited.

---

## 8. Progress API

### Audio / ebook resume

`PUT /v1/items/{id}/progress`

```json
{
  "updated_at": "2026-07-10T12:00:00Z",
  "audio_position_seconds": 3600.5,
  "audio_duration_seconds": 36000,
  "ebook_progression": 0.42,
  "ebook_locator_json": "{...optional Readium locator...}",
  "is_finished": false
}
```

- Partial updates allowed (null = leave unchanged).  
- Reject if body `updated_at` < server `updated_at` (optional strict mode) **or** apply field-wise: position LWW, finished LWW.  
- Prefer documented behavior: **LWW on the progress row by `updated_at`**, but never decrease monotonic stats (stats are separate endpoint).

`GET /v1/items/{id}/progress`

`GET /v1/progress?updated_since=` — bulk pull for client sync.

---

## 9. Stats API (SmartSpeech / Nerd Stats)

`PUT /v1/items/{id}/stats`

```json
{
  "saved_seconds": 1820,
  "listened_seconds": 12040,
  "reading_seconds": 0
}
```

Server: for each field, `new = max(existing, incoming)` (treat missing as 0).

`GET /v1/items/{id}/stats`

`PUT /v1/stats/lifetime`

```json
{
  "saved_seconds": 90000,
  "played_seconds": 400000
}
```

Also max-merge.

`GET /v1/stats/lifetime`

These replace Dropbox `SmartSpeechStatsRecord` / per-book `savedSeconds` for server-origin libraries.

---

## 10. Health

- `GET /health` → 200 `{"ok":true}` (no auth; for Docker healthcheck)  
- `GET /v1/health` → same + db ping (auth optional)

---

## 11. SQLite schema (v1)

```sql
-- users: single-user ok
CREATE TABLE users (
  id TEXT PRIMARY KEY,
  created_at TEXT NOT NULL
);

CREATE TABLE devices (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES users(id),
  name TEXT NOT NULL,
  platform TEXT,
  token_hash TEXT NOT NULL UNIQUE,
  created_at TEXT NOT NULL,
  last_seen_at TEXT,
  revoked_at TEXT
);

CREATE TABLE library_items (
  id TEXT PRIMARY KEY,
  content_key TEXT NOT NULL UNIQUE,
  kind TEXT NOT NULL,              -- 'audio' | 'ebook' | 'both'
  title TEXT NOT NULL,
  author TEXT,
  duration_seconds REAL,
  rel_path TEXT,                   -- primary path hint
  missing INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE media_files (
  id TEXT PRIMARY KEY,
  item_id TEXT NOT NULL REFERENCES library_items(id),
  role TEXT NOT NULL,              -- 'audio' | 'ebook' | 'cover'
  rel_path TEXT NOT NULL,
  size_bytes INTEGER,
  duration_seconds REAL,
  sort_order INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE progress (
  item_id TEXT PRIMARY KEY REFERENCES library_items(id),
  audio_position_seconds REAL,
  audio_duration_seconds REAL,
  ebook_progression REAL,
  ebook_locator_json TEXT,
  is_finished INTEGER NOT NULL DEFAULT 0,
  finished_at TEXT,
  updated_at TEXT NOT NULL
);

CREATE TABLE item_stats (
  item_id TEXT PRIMARY KEY REFERENCES library_items(id),
  saved_seconds REAL NOT NULL DEFAULT 0,
  listened_seconds REAL NOT NULL DEFAULT 0,
  reading_seconds REAL NOT NULL DEFAULT 0,
  updated_at TEXT NOT NULL
);

CREATE TABLE lifetime_stats (
  user_id TEXT PRIMARY KEY REFERENCES users(id),
  saved_seconds REAL NOT NULL DEFAULT 0,
  played_seconds REAL NOT NULL DEFAULT 0,
  updated_at TEXT NOT NULL
);

-- phase: hardcover
CREATE TABLE hardcover_credentials (
  user_id TEXT PRIMARY KEY REFERENCES users(id),
  token_ciphertext TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE hardcover_links (
  item_id TEXT PRIMARY KEY REFERENCES library_items(id),
  hardcover_book_id INTEGER,
  hardcover_edition_id INTEGER,
  hardcover_user_book_id INTEGER,
  updated_at TEXT NOT NULL
);
```

Use TEXT ISO-8601 timestamps for simplicity.

---

## 12. Hardcover (phase 2)

- `PUT /v1/integrations/hardcover` `{ "api_token": "..." }` — store encrypted if key available (`RHAPSODE_SECRETS_KEY`), else restricted file perms + document risk.  
- `PUT /v1/items/{id}/hardcover` link ids.  
- Background: on progress push past throttle, scrobble `progress_seconds` / status via GraphQL.  
- Clients never see Hardcover token after initial save.

---

## 13. Error format

```json
{ "error": "not_found", "message": "item not found" }
```

HTTP: 400 validation, 401 auth, 403 revoked, 404, 409 conflict, 429 rate limit, 500.

---

## 14. Repository layout (target)

```text
rhapsode-server/
  Cargo.toml
  migrations/
  src/
    main.rs
    config.rs
    auth/
    db/
    library/
    routes/
    hardcover/          # later
  docker-compose.yml
  Dockerfile
  .env.example
  fixtures/             # tiny synthetic media for tests
  README.md             # dev-focused; operator guide is specs/.../README.md
```

iOS client integration is a **later PR series** against this API (out of server P0 unless scheduled).

---

## 15. Testing

| Level | What |
|-------|------|
| Unit | max-merge stats; path safety; token hash |
| Integration | axum test client + temp SQLite + fixture files |
| Manual | Docker on Mac/Synology per operator README |

CI: `cargo test`, `cargo clippy -D warnings`, `cargo fmt --check`.

---

## 16. Acceptance criteria (server)

1. `docker compose up` serves `/health`.  
2. Bootstrap creates device token; subsequent API calls work with Bearer.  
3. Scan indexes fixtures / mounted sample libraries.  
4. Authenticated download returns correct bytes for one audio + one epub.  
5. Progress LWW and stats max-merge verified by tests.  
6. Revoked device gets 401.  
7. No dependency on Dropbox/ABS.  

---

## 17. Relationship to other specs

| Path | Status |
|------|--------|
| `specs/integrations/rhapsode-server/**` | **IMPLEMENT** |
| `specs/integrations/DONOTIMPLEMENT/**` | **Do not implement** (ABS, Hardcover client, old playbook) |

---

## 18. References

- Axum: https://docs.rs/axum  
- SQLx: https://docs.rs/sqlx  
- Operator guide: [README.md](./README.md)  
- PR plan: [PR-PLAN.md](./PR-PLAN.md)  
- Client SmartSpeech rules: repo `CLAUDE.md` (source-domain positions)  
