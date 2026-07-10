# Rhapsode Server — PR Plan

For orchestrators (`/execute-plan` or manual worktree agents).  
**Model split:** parent Grok 4.5; workers `grok-composer-2.5-fast` via `[subagents.models]`.

All work under `rhapsode-server/` unless noted. Do **not** implement files under `specs/integrations/DONOTIMPLEMENT/`.

---

## PR Plan

### PR 1: Scaffold crate + Docker + health

- **Description:** Create `rhapsode-server` Rust binary crate; `Dockerfile` multi-stage; `docker-compose.yml`; `.env.example`; `GET /health`; config from env; `tracing` logging; README for dev.
- **Files/components affected:** `rhapsode-server/**` (new)
- **Dependencies:** None

### PR 2: SQLite + migrations + device auth

- **Description:** sqlx (or chosen) migrations for users/devices; bootstrap endpoint; Bearer middleware; create/list/revoke devices; token hashing; rate-limit auth lightly.
- **Files/components affected:** `rhapsode-server/src/auth/**`, `db/**`, `migrations/**`, routes
- **Dependencies:** PR 1

### PR 3: Library scan + catalog API

- **Description:** Walk audio/ebook roots; upsert `library_items` + `media_files`; `POST /v1/library/scan`; `GET /v1/library`; `GET /v1/items/{id}`; cover endpoint if file present; skip `@eaDir`/hidden; fixture tree + tests.
- **Files/components affected:** `library/**`, routes, fixtures
- **Dependencies:** PR 2

### PR 4: Authenticated file download

- **Description:** `GET /v1/items/{id}/files`; `GET .../download` streams by file id only (no path traversal); Content-Type/Length; optional HTTP Range; tests with fixtures.
- **Files/components affected:** routes, library file resolution
- **Dependencies:** PR 3

### PR 5: Progress + stats APIs

- **Description:** PUT/GET item progress (LWW); bulk pull; PUT/GET item stats + lifetime (max-merge); unit tests for merge rules.
- **Files/components affected:** routes, db progress/stats
- **Dependencies:** PR 2 (can start after PR 2; needs items from PR 3 for E2E — treat deps as PR 3)

### PR 6: Operator polish + compose defaults

- **Description:** Healthcheck in compose; graceful errors; scan status; document Synology bind mounts; ensure `cargo clippy` clean; optional `GET /v1/me`.
- **Files/components affected:** compose, README, small route fixes
- **Dependencies:** PR 4, PR 5

### PR 7 (later): Hardcover server worker

- **Description:** Store token; link items; throttled scrobble on progress. **Not required for first go-live of personal sync.**
- **Files/components affected:** `hardcover/**`, migrations links/credentials
- **Dependencies:** PR 5

### PR 8 (later, separate track): iOS client → Rhapsode Server

- **Description:** `RhapsodeServerSource` + sync in the Swift app; Settings UI; selective download. Out of pure server scaffold unless explicitly scheduled.
- **Files/components affected:** `Sources/**` (iOS)
- **Dependencies:** PR 6

---

## Suggested first milestone (your go-ahead)

**PR 1–6** = usable personal backend on Synology.  
PR 7–8 after server is stable.

---

## Orchestrator one-liner

```text
/model grok-4.5

Implement specs/integrations/rhapsode-server/ per SPEC.md and PR-PLAN.md.
Rust + SQLite + Docker. Worktree-isolated subagents (Composer workers via config).
Do NOT implement anything under specs/integrations/DONOTIMPLEMENT/.
Do NOT modify SmartSpeechKit or live engine.
Start with PR 1 scaffold.
```
