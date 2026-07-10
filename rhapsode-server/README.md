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

curl -s -X POST http://127.0.0.1:8080/v1/library/scan \
  -H "Authorization: Bearer $TOKEN"

curl -s http://127.0.0.1:8080/v1/library -H "Authorization: Bearer $TOKEN"
```

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
