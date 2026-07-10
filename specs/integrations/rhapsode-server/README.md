# Rhapsode Server — operator & implementer guide

Personal self-hosted backend for Rhapsode: **library catalog, selective media download, resume progress, SmartSpeech/Nerd Stats, optional Hardcover scrobble**. Clients (iOS now; Android/Windows later) are listeners/readers only.

| Doc | Purpose |
|-----|---------|
| **This README** | Manual ops: Synology, Docker, reverse proxy, auth bootstrap, library layout |
| [SPEC.md](./SPEC.md) | Full product/API/schema contract for agents |
| [PR-PLAN.md](./PR-PLAN.md) | Implementation DAG for multi-agent build |

**Status:** ready to implement on branch `feat/rhapsode-server` after you give the go-ahead.  
**Stack defaults:** **Rust** API · **SQLite** · **Docker Compose** · device bearer tokens · HTTPS reverse proxy.

---

## 1. What you are building

```text
Your Synology (or any Docker host)
├── reverse proxy (HTTPS)  →  rhapsode-server:8080
├── rhapsode-server (Rust)
│     └── SQLite volume (progress, stats, devices, index)
└── bind-mount: existing audiobook + ebook folders (read-only OK)
```

Apps never need Dropbox/ABS/Hardcover for core sync. Optional Hardcover runs **on the server**.

---

## 2. Manual steps (you do these; agents do not invent your NAS paths)

### 2.1 Library paths on **this** NAS (already chosen)

Matches `/volume1/docker/rhapsode-server/compose.yaml` (Mac: `/Volumes/docker/rhapsode-server/`).

| Host path | Role |
|-----------|------|
| `/volume1/Storage/Audiobooks` | Audiobooks (m4b etc.) — ~Speakarr / manual library |
| `/volume1/Storage/Books` | Calibre-style EPUBs (Readarr `/books`) |
| `/volume1/docker/rhapsode-server/data` | SQLite + server state (RW) |

House style from `/volume1/docker/compose/compose.yaml`: `user 1026:100`, `TZ=Europe/London`, watchtower labels, ABS-style **bridge port** (not host network).

**Port:** host **13379** → container 8080 (ABS uses 13378).

**Note:** Main compose still mounts **Books** into ABS as `/audiobooks`. Real **m4b** files live under **Audiobooks**. Rhapsode Server mounts them correctly; you may want to realign ABS later.

Scanner conventions (v1) stay flexible: single-file m4b, multi-file folders, Calibre `Author/Title (id)/` epubs.

### 2.2 Data directory

Already created:

```text
/volume1/docker/rhapsode-server/
  compose.yaml
  .env.example
  data/          # SQLite
  config/        # reserved
  README.md
```

Do **not** put the DB under `Storage/Books` or `Storage/Audiobooks`.

### 2.3 Docker Compose

**On the NAS (canonical for deploy):**

```bash
cd /volume1/docker/rhapsode-server   # or /Volumes/docker/rhapsode-server from Mac
cp .env.example .env                 # set RHAPSODE_BOOTSTRAP_TOKEN
# after image exists:
docker compose -f compose.yaml up -d
```

Image tag: `rhapsode-server:local` (build from the Rust crate when implemented; until then compose will not start).

In-repo reference copy can mirror this later under `rhapsode-server/docker-compose.yml`.

### 2.4 Reverse proxy (HTTPS)

Expose only via HTTPS. Options on Synology:

1. **DSM Reverse Proxy** → `https://rhapsode.yourdomain.com` → `http://localhost:8080`  
2. **Nginx Proxy Manager / Caddy / SWAG** in Docker (common if you already use them for ABS)

Checklist:

- [ ] Valid certificate (Let’s Encrypt)
- [ ] HTTP → HTTPS redirect
- [ ] Do **not** leave port 8080 open on the WAN
- [ ] Prefer **Tailscale/VPN** so the hostname is not public at all (strongest for personal use)

### 2.5 Network access for apps

| Mode | App “Server URL” |
|------|------------------|
| Home LAN only | `https://rhapsode.lan` or `https://nas-ip` (needs cert trust) |
| Tailscale | `https://rhapsode.<tailnet-name>.ts.net` (or MagicDNS name) |
| Public reverse proxy | `https://rhapsode.yourdomain.com` + strong tokens |

iOS ATS requires valid HTTPS for production-like use; plan certs early.

### 2.6 Firewall

- LAN/Tailscale: allow app → proxy only  
- If public: rate-limit at proxy; no anonymous catalog  

---

## 3. Auth bootstrap (first-time)

v1 uses **device API tokens** (see SPEC.md).

### First run

1. Start container with a one-time bootstrap secret, e.g.  
   `RHAPSODE_BOOTSTRAP_TOKEN=<long-random-string>`  
2. From a trusted machine (or early debug UI / `curl`):

```bash
curl -sS -X POST "https://rhapsode.example/v1/auth/bootstrap" \
  -H "Content-Type: application/json" \
  -H "X-Bootstrap-Token: $RHAPSODE_BOOTSTRAP_TOKEN" \
  -d '{"device_name":"iPhone","platform":"ios"}'
```

3. Response includes `api_token` **once**. Store in Rhapsode app Settings → Keychain.  
4. **Remove or rotate** `RHAPSODE_BOOTSTRAP_TOKEN` after first device is created (env empty + restart).  
5. Later devices: either re-enable bootstrap briefly, or use  
   `POST /v1/auth/devices` with an existing admin token (SPEC).

### Lost phone

- Call `DELETE /v1/auth/devices/{id}` with another device token, or stop server and clear `devices` table / revoke in SQLite.

### Token hygiene

- Never commit tokens  
- One token per device  
- HTTPS only  

---

## 4. Day-to-day operations

### Library changes

1. Copy new books into the mounted audio/ebook folders.  
2. Trigger scan: `POST /v1/library/scan` (authenticated) or rely on periodic scan if enabled.  
3. Clients pull catalog; **download only titles you choose** in the app.

### Backups

| What | How |
|------|-----|
| SQLite | Snapshot `/volume1/docker/rhapsode-server/data` (include `rhapsode.db*`) |
| Media | Your existing NAS backup of library folders |
| Frequency | After big listening sessions / weekly minimum |

Stop container or use SQLite safe backup (`sqlite3 .backup`) before copying DB if you want consistency.

### Upgrades

```bash
# rebuild image, recreate container, keep /data volume
docker compose pull   # if registry
docker compose up -d --build
```

Migrations: server applies SQLite migrations on startup (SPEC).

### Logs

```bash
docker compose logs -f rhapsode-server
```

---

## 5. Client (Rhapsode iOS) — after server exists

Not part of server P0, but the end state:

1. Settings → **Rhapsode Server** URL + paste device token (or bootstrap flow in-app later).  
2. Catalog sync → shelf shows library (not all downloaded).  
3. Download selected titles → Application Support.  
4. Play with SmartSpeech / read with Readium.  
5. Progress + SmartSpeech stats push to server automatically.

Dropbox/ABS integrations are under **`specs/integrations/DONOTIMPLEMENT/`** — do not build those while this path is active.

---

## 6. Hardcover (server-side, later phase)

1. Create Hardcover API token in account settings.  
2. Store on server via authenticated API (`PUT /v1/integrations/hardcover`) — encrypted at rest if possible.  
3. Link library items to Hardcover book/edition ids.  
4. Server job scrobbles on progress thresholds — **clients do not hold the Hardcover token**.

---

## 7. Security checklist (personal deploy)

- [ ] HTTPS (or Tailscale-only + HTTPS)  
- [ ] Bootstrap token removed after setup  
- [ ] Device tokens in Keychain only  
- [ ] Media mounts **read-only** into container if possible  
- [ ] DB volume not world-readable on NAS shares  
- [ ] No port 8080 on router WAN  
- [ ] Optional: proxy rate limit / auth rate limit on `/v1/auth/*`  

---

## 8. Local dev (implementers / you on Mac)

```bash
cd rhapsode-server   # once the crate exists in-repo
cp .env.example .env
# point LIBRARY paths at a small fixture tree
cargo run
# or: docker compose -f docker-compose.dev.yml up --build
```

Use fixture audio/EPUB under `rhapsode-server/fixtures/` for tests (no copyrighted dumps in git).

---

## 9. Success criteria (manual)

1. Container healthy; `GET /health` → 200.  
2. Bootstrap creates a device token.  
3. Scan indexes at least one audio + one EPUB from mounted folders.  
4. Authenticated download returns file bytes.  
5. Progress PUT/GET round-trip for audio position + ebook progression.  
6. Stats PUT/GET preserves `saved_seconds` with max-merge across two sequential updates.  
7. iOS (later) can point at server and play a downloaded book with SmartSpeech.

---

## 10. Out of scope for you right now

- Publishing to App Store multi-tenant cloud (same image later + managed Postgres optional)  
- Replacing SmartSpeech with server-side audio processing  
- Building ABS/Dropbox/Hardcover **client** integrations (see DONOTIMPLEMENT)

---

## 11. Next step

1. Read [SPEC.md](./SPEC.md) and [PR-PLAN.md](./PR-PLAN.md).  
2. Confirm NAS paths + hostname/TLS approach (fill in your real values).  
3. Give the go-ahead on branch `feat/rhapsode-server` to implement the Rust server per the PR plan.
