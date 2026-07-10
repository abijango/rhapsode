# DO NOT IMPLEMENT

These specs are **deferred research** kept for reference only.

**Active path:** [`../rhapsode-server/`](../rhapsode-server/) — self-hosted Rust + SQLite Rhapsode Server.

| File | Was | Why deferred |
|------|-----|----------------|
| `audiobookshelf-secondary-source.md` | ABS as library + NAS WebDAV stats | Replaced by owning our own backend |
| `hardcover-progress-scrobble.md` | Client-side Hardcover scrobble | Hardcover will run **on rhapsode-server** (SPEC phase 2), not in iOS |
| `agent-orchestration-playbook.md` | Multi-agent guide for ABS/Hardcover | Superseded by `../rhapsode-server/PR-PLAN.md` + operator README |

## Rules for agents

- **Do not** implement Dropbox alternatives from these files.  
- **Do not** add Audiobookshelf or client Hardcover SDKs based on these docs.  
- **Do not** create WebDAV stats clients for ABS.  
- If a task conflicts with `rhapsode-server/SPEC.md`, **follow rhapsode-server**.

Historical context is useful; shipping path is **Rhapsode Server only** until the product owner reactivates something here.
