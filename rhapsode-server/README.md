# rhapsode-server

Rust + SQLite personal library API for Rhapsode clients.

Full product contract: [`../specs/integrations/rhapsode-server/`](../specs/integrations/rhapsode-server/)  
Synology operator compose: `/volume1/docker/rhapsode-server/compose.yaml`

## Quick local run

```bash
cd rhapsode-server
export RHAPSODE_DATA_DIR=./data
export RHAPSODE_LIBRARY_AUDIO=./fixtures/audio
export RHAPSODE_LIBRARY_EBOOK=./fixtures/ebook
export RHAPSODE_BOOTSTRAP_TOKEN=dev-bootstrap-secret
cargo run
```

```bash
curl -s http://127.0.0.1:8080/health

curl -s -X POST http://127.0.0.1:8080/v1/auth/bootstrap \
  -H 'Content-Type: application/json' \
  -H 'X-Bootstrap-Token: dev-bootstrap-secret' \
  -d '{"device_name":"dev","platform":"cli"}'

# save api_token from response as TOKEN
export TOKEN=rhp_...

# Incremental reindex (default) — only new/changed/deleted files
curl -s -X POST 'http://127.0.0.1:8080/v1/library/scan?mode=incremental' \
  -H "Authorization: Bearer $TOKEN"

# Full rebuild
curl -s -X POST 'http://127.0.0.1:8080/v1/library/scan?mode=full' \
  -H "Authorization: Bearer $TOKEN"

# Catalogue from SQLite (includes primary_file — no N+1)
curl -s http://127.0.0.1:8080/v1/library -H "Authorization: Bearer $TOKEN"
```

## Indexing model

1. **Catalogue lives in SQLite** — `GET /v1/library` never walks disk.
2. **Startup** runs one incremental scan in the background.
3. **Periodic** incremental scan (default every **15 minutes**).
4. **Manual** `POST /v1/library/scan?mode=incremental|full`.
5. **Download** resolves `media_files.rel_path` from the DB and streams the file.

Incremental compares each file’s **size + mtime** to the last index; unchanged books are skipped.

## Docker

```bash
docker build -t rhapsode-server:local .
docker compose up -d
```

For Synology, load/tag the same image and use the host compose under `/volume1/docker/rhapsode-server/`.

## Env

| Variable | Default |
|----------|---------|
| `RHAPSODE_DATA_DIR` | `./data` |
| `RHAPSODE_LIBRARY_AUDIO` | `./fixtures/audio` |
| `RHAPSODE_LIBRARY_EBOOK` | `./fixtures/ebook` |
| `RHAPSODE_BIND` | `0.0.0.0:8080` |
| `RHAPSODE_BOOTSTRAP_TOKEN` | unset (bootstrap disabled) |
| `RHAPSODE_LOG` | `info` |
| `RHAPSODE_SCAN_INTERVAL_SECS` | `900` (15m; `0` disables background scan) |
