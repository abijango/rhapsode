# How to build these integrations with Grok Build

> **DO NOT IMPLEMENT ABS/Hardcover from this playbook.** Deferred. Use [`../rhapsode-server/PR-PLAN.md`](../rhapsode-server/PR-PLAN.md) instead. See [`README.md`](./README.md).

Playbook for a **fresh session** (historical — ABS and client Hardcover). Kept for multi-agent process notes only.

---

## 0. Model split (important)

| Role | Model ID | How it is selected |
|------|----------|--------------------|
| **Orchestrator** (parent session) | `grok-4.5` | Session default / `/model grok-4.5` / `grok -m grok-4.5` |
| **Worker subagents** (implement, review, explore, plan) | `grok-composer-2.5-fast` | `[subagents.models]` in `~/.grok/config.toml` |

**Why config is required:** `spawn_subagent` does **not** take a per-call `model` parameter. Without an override, every subagent **inherits the parent session model**. If the parent is Grok 4.5 and you never pin workers, implementers also run as Grok 4.5.

Confirm IDs on your machine:

```bash
grok models
# Expect something like:
#   * grok-4.5 (default)
#   - grok-composer-2.5-fast
```

If Composer appears under a different id, use that string everywhere below.

### Pin workers to Composer (user config)

Edit `~/.grok/config.toml` (project `.grok/config.toml` does **not** load `[subagents]` — only user config does):

```toml
[models]
default = "grok-4.5"

[subagents]
enabled = true

[subagents.models]
# Built-in agent types used as workers
general-purpose = "grok-composer-2.5-fast"
explore = "grok-composer-2.5-fast"
plan = "grok-composer-2.5-fast"
```

Restart the Grok TUI (or start a new session) after saving so the pin applies.

**Scope note:** this pin is **global for your user** — every Grok session will spawn those agent types on Composer until you change or remove the block. For a temporary run:

1. Add the `[subagents.models]` block.  
2. Run the integration session(s).  
3. Comment out or delete the block (or point them back at `grok-4.5`) when finished.

### Optional: personas with model override

If you prefer not to retarget all `general-purpose` spawns, define personas that set `model = "grok-composer-2.5-fast"` and route work through roles that use those personas (see Grok user-guide § Subagents → Personas / Roles). The simple `[subagents.models]` map above is enough for this playbook.

### Resolution order (Grok)

Effective subagent model, highest priority first:

1. Explicit spawn-time override (if your Grok version exposes one)  
2. Role default  
3. Persona default  
4. `[subagents.models.<type>]`  
5. Parent session model  

### Verify the split mid-run

In the TUI subagent list/rows, each child should show model **`grok-composer-2.5-fast`** while the parent title bar shows **`grok-4.5`**. If children show `grok-4.5`, the pin did not load — re-check config path and restart.

---

## 1. Mental model

```text
You (orchestrator session = grok-4.5)
├── Worktree A: feature/audiobookshelf-secondary-source
│   ├── Subagent [Composer 2.5]: implement PR1
│   ├── Subagent [Composer 2.5]: review PR1
│   ├── Subagent [Composer 2.5]: implement PR2 …
│   └── …
└── Worktree B: feature/hardcover-scrobble
    ├── Subagent [Composer 2.5]: implement PR1
    └── …
```

| Rule | Why |
|------|-----|
| **Orchestrator = Grok 4.5** | Planning, DAG, spawn/review loop, merge decisions |
| **Workers = Composer 2.5** | Implementation + code review volume |
| **One integration per worktree / branch stack** | Avoids merge fights on `Models.swift`, `SettingsView.swift`, `AudiobookPlayer.swift` |
| **Orchestrator does not hand-edit production code** | Subagents own commits inside worktrees |
| **Specs are the contract** | Agents re-read `specs/integrations/*.md` + `CLAUDE.md` |
| **ABS first if serial; parallel only with file ownership** | Shared files need a short “integration seams” PR first if you parallelize |

---

## 2. Pre-flight (once, on `master`)

```bash
cd /Users/naufalmir/work/personal/rhapsode
git status                    # clean
git pull origin master        # or your main branch name
```

Confirm docs exist:

```bash
ls specs/integrations/
# README.md
# audiobookshelf-secondary-source.md
# hardcover-progress-scrobble.md
# agent-orchestration-playbook.md
```

Confirm model pin (section 0) is in `~/.grok/config.toml`.

Optional but smart if you will run **both** integrations in parallel: land a tiny **seams** commit on master first (human or single agent):

- Optional `sourceBackend` on `Audiobook`
- Optional Hardcover id fields (nil)
- Empty `Sources/Integrations/` group in `project.yml` if you use XcodeGen

That reduces collision on `Models.swift`. If you only build **one** integration at a time, skip seams.

---

## 3. Choose a session strategy

### Strategy A — Full auto DAG (`/execute-plan`) — preferred when design has a PR Plan

1. Open a **new** Grok Build session in the repo with **orchestrator model Grok 4.5**:
   ```bash
   grok -m grok-4.5
   ```
   Or in TUI: `/model grok-4.5`
2. Ensure Composer pin is active for subagent types (section 0).
3. If the spec’s PR Plan is enough, either:
   - Run `/design` first to polish a design doc that embeds the same PR Plan, **or**
   - Point `/execute-plan` at a design doc you generate that **includes** `## PR Plan` with `### PR N:` sections (execute-plan requires that heading shape).

**Minimum design wrapper** you can ask the session to create once:

```text
Read specs/integrations/audiobookshelf-secondary-source.md.
Write docs/designs/audiobookshelf-secondary-source.md that:
- Summarizes goals/non-goals
- Lists architecture decisions
- Copies the PR Plan section into a proper ## PR Plan with ### PR 1: … headings
  (Description / Files / Dependencies bullets as required by execute-plan)
Do not implement yet.
```

Then:

```text
/execute-plan docs/designs/audiobookshelf-secondary-source.md --concurrency 2 --no-graphite
```

(Use Graphite if you have `gt` and want stacked PRs; omit `--no-graphite`.)

`/execute-plan` will:

- Parse the PR DAG (**Grok 4.5** orchestrator)  
- Spawn **implementer** subagents with `isolation: "worktree"` (**Composer** via pin)  
- Run **reviewer** subagents against those worktrees (**Composer**)  
- Assemble a branch stack (**Grok 4.5**)  

Repeat in a **second session** for Hardcover with its own design path.

### Strategy B — Manual multi-agent prompts (more control)

#### B1. Start orchestrator session (Grok 4.5)

```bash
cd /Users/naufalmir/work/personal/rhapsode
grok -m grok-4.5
```

Paste the orchestrator brief (section 4 below).

#### B2. Tell it how to use worktrees + subagents

Grok’s `spawn_subagent` supports:

| Param | Use |
|-------|-----|
| `subagent_type` | `general-purpose` (code), `explore` (read-only research), `plan` (plan only) |
| `isolation: "worktree"` | Implementers: isolated git worktree, no dirtying master |
| `cwd` | Reviewers: attach to implementer’s worktree path |
| `background: true` | Parallel agents |
| `resume_from` | Fix rounds with same agent transcript |

Model for those children comes from **`[subagents.models]`**, not from the prompt — still tell the orchestrator the intended split so it does not “switch the whole session to Composer.”

Ask the orchestrator explicitly:

```text
You are the orchestrator only (this session is grok-4.5). Do not edit Sources/ yourself.
Worker subagents are pinned to grok-composer-2.5-fast via config — do not /model switch the parent to Composer.
For each PR in the plan:
1. spawn_subagent general-purpose with isolation=worktree to implement
2. After it finishes, spawn a reviewer general-purpose with cwd=<worktree_path>
3. If issues, resume_from the implementer, then re-review
4. Keep a running checklist of PRs
Hard constraints from CLAUDE.md apply. Spec is authoritative.
```

#### B3. Two parallel sessions (one per integration)

Terminal 1:

```bash
grok -m grok-4.5
# paste ABS orchestrator brief
```

Terminal 2:

```bash
grok -m grok-4.5
# paste Hardcover orchestrator brief
```

Both rely on the same user-level Composer pin for workers.

---

## 4. Copy-paste orchestrator prompts

### 4.1 Audiobookshelf (secondary source, full download only)

```text
# Orchestrator: Audiobookshelf secondary source

Model: grok-4.5 (this parent session).
Worker subagents: grok-composer-2.5-fast (via [subagents.models] — do not change parent /model to Composer).
Repo: Rhapsode (SwiftUI / SwiftData / XcodeGen).

## Spec (authoritative)
Read and follow:
- specs/integrations/audiobookshelf-secondary-source.md
- CLAUDE.md
- docs/SPEC.md (offline-first, relative paths)

## Product decisions (fixed)
- ABS is SECONDARY to Dropbox (dual-source), not a forced hard cutover — but must support BOTH audiobooks and EPUBs.
- CATALOG sync is metadata-only. MEDIA download is SELECTIVE (user/rules). NEVER auto-download the whole library.
- Full file download of selected items only into Application Support. No streaming into SmartSpeech or online-only Readium.
- Do NOT modify Sources/SmartSpeechLive/** or SmartSpeechKit/**.
- Resume: source-domain audio → ABS currentTime; ebook → ABS ebookProgress + ebookLocation.
- SmartSpeech savedSeconds / lifetime Nerd Stats / per-item extras: NAS rhapsode-sync folder via WebDAV/HTTPS (same Synology as ABS is fine). NOT on ABS schema. Max-merge for cumulative fields.
- Dual-format ABS items may create both a local Audiobook and Book sharing absLibraryItemId.
- Portable HTTP clients (future Android). Reuse importers / player / reader / ProgressSync shapes.

## How to work
1. You are orchestrator-only: no direct production edits. Use subagents.
2. Implement PR Plan from the spec (PR1→PR7; catalog before download; NAS stats = PR6) in dependency order.
3. Each implementer: spawn_subagent subagent_type=general-purpose, isolation=worktree, background=true.
4. Prefix description with [implementer] or [reviewer].
5. Reviewer uses cwd=<implementer worktree>, no worktree isolation.
6. After each PR: xcodegen generate if project.yml changed; attempt build if feasible.
7. Commit inside the worktree with clear messages.
8. When all PRs done, report branches, worktree paths, and merge order onto master.

## Start now
Confirm you read the spec, restate non-goals in 5 bullets, confirm worker model pin expectation (Composer), then launch PR1 implementer.
```

### 4.2 Hardcover scrobble

```text
# Orchestrator: Hardcover progress scrobble

Model: grok-4.5 (this parent session).
Worker subagents: grok-composer-2.5-fast (via [subagents.models] — do not /model the parent to Composer).
Repo: Rhapsode.

## Spec (authoritative)
- specs/integrations/hardcover-progress-scrobble.md
- CLAUDE.md

## Product decisions (fixed)
- Optional outbound scrobble only (personal API token, not OAuth).
- Manual search + user confirms book/edition link.
- Throttled progress_seconds + status_id updates.
- Source-domain times only (never SmartSpeech output time).
- Do NOT modify SmartSpeechLive or SmartSpeechKit.
- Do NOT implement ABS or change Dropbox hosting in this stack.

## How to work
Same multi-agent worktree protocol as ABS:
orchestrator-only; [implementer] worktrees; [reviewer] cwd=worktree; PR1→PR4 from spec.
Workers run Composer; you stay on Grok 4.5.

## Start now
Confirm spec + non-goals + model split, then launch PR1 implementer (client + Keychain + Settings token).
```

### 4.3 Single-session serial (both integrations, safer merges)

```text
Build BOTH integrations serially in one orchestrator session on grok-4.5.
Worker subagents use grok-composer-2.5-fast (config pin). Do not switch parent /model to Composer.

Phase A — ABS: follow specs/integrations/audiobookshelf-secondary-source.md
  to completion (worktree stack), merge or leave branch ready.

Phase B — Hardcover: follow specs/integrations/hardcover-progress-scrobble.md
  on a NEW worktree branched from the ABS result branch (or master if ABS not merged).

Never edit SmartSpeech. Full download only for ABS. Hardcover is scrobble-only.

Use spawn_subagent with isolation=worktree for all implementation.
```

---

## 5. File ownership (parallel safety)

If two sessions run in parallel **without** a seams PR, assign ownership:

| File | ABS session | Hardcover session |
|------|-------------|-------------------|
| `Models.swift` | `sourceBackend`, `abs*` fields only | `hardcover*` fields only |
| `SettingsView.swift` | ABS section only | Hardcover section only |
| `AudiobookPlayer.swift` | Route progress by backend | Call scrobbler hooks only |
| `KeychainTokenStore.swift` | `abs.*` keys | `hardcover.*` keys |
| New client files | `Audiobookshelf*` | `Hardcover*` |
| SmartSpeech* | **neither** | **neither** |

Instruct each orchestrator:

```text
If you must touch a shared file, change ONLY your integration’s section/fields.
Do not reformat whole files. Do not rename unrelated symbols.
```

Merge ABS first, then Hardcover, then fix any residual conflicts (usually Settings).

---

## 6. Suggested subagent roles per PR

| Role | `subagent_type` | isolation | Model (via pin) | Task |
|------|-----------------|-----------|-----------------|------|
| Explorer | `explore` | none / read-only | Composer | “Where does progress get saved today?” |
| Planner | `plan` | none | Composer | Optional: tighten PR boundaries |
| Implementer | `general-purpose` | **worktree** | Composer | Code + commit |
| Reviewer | `general-purpose` | **cwd=worktree** | Composer | Spec compliance + CLAUDE.md |
| Test runner | `general-purpose` | cwd=worktree | Composer | `xcodegen` + `xcodebuild` smoke |
| Orchestrator | parent session | n/a | **Grok 4.5** | Spawn, merge, acceptance |

Example implementer seed (orchestrator expands with PR details):

```text
[implementer] PR1 ABS HTTP client

Implement ONLY PR1 from specs/integrations/audiobookshelf-secondary-source.md §11.
Checkout your branch if provided. Follow CLAUDE.md.
Do not touch SmartSpeech. Do not start PR2.
Commit when done. Summarize files changed.
```

Example reviewer seed:

```text
[reviewer] PR1 ABS HTTP client

Review the worktree diff against the ABS integration spec §11 PR1 and CLAUDE.md.
Flag: streaming assumptions, absolute paths in SwiftData, token logging, SmartSpeech edits.
Write findings as severity-ordered list. No code changes unless asked.
```

---

## 7. Verification checklist (orchestrator gates)

Before calling an integration “done”:

### Model split

- [ ] Parent session is `grok-4.5`  
- [ ] Implementer/reviewer rows show `grok-composer-2.5-fast` (or your Composer id)  

### ABS

- [ ] Catalog sync does **not** enqueue whole-library downloads  
- [ ] Selective download of one M4B + one EPUB only  
- [ ] Play with SmartSpeech **enabled**; engine files untouched in `git diff`  
- [ ] ABS resume: source-domain `currentTime` + ebook progress/location  
- [ ] NAS WebDAV (or HTTPS) stats: `savedSeconds` / lifetime totals round-trip + max-merge  
- [ ] Dual-format item: audio + ebook resume fields do not clobber each other  
- [ ] Dropbox path still compiles / basic flow not deleted  

### Hardcover

- [ ] Token saved; `me` query works  
- [ ] Search + link edition  
- [ ] Scrobble appears on hardcover.app  
- [ ] Throttle respected under seek spam  
- [ ] Unlinked books silent  

### Always

```bash
git diff --name-only | rg 'SmartSpeech|SmartSpeechKit'   # must be empty for these features
```

---

## 8. Merge order

```text
master
  └── feature/abs-secondary-source     # merge first if both ready
        └── feature/hardcover-scrobble  # rebase onto abs branch or master post-merge
```

Or two independent PRs to `master` if seams PR already landed.

---

## 9. Anti-patterns

| Don’t | Do instead |
|-------|------------|
| `/model grok-composer-2.5-fast` on the parent for “faster coding” | Keep parent on Grok 4.5; pin workers in config |
| Assume spawn_subagent accepts `model:` | Use `[subagents.models]` |
| One mega-agent edits both integrations on master | Two worktree stacks |
| Stream ABS audio into `LiveTrimProducer` | Full download only (spec) |
| Push SmartSpeech output time to ABS/Hardcover | Source-domain only |
| Put API tokens in SwiftData / UserDefaults plaintext | Keychain |
| Hand-edit `Rhapsode.xcodeproj` | `project.yml` + `xcodegen generate` |
| Skip review subagents | Reviewer per PR |

---

## 10. Minimal “just do ABS” one-liner

Pre-req: Composer pin in `~/.grok/config.toml` (section 0).

```text
/model grok-4.5

Implement specs/integrations/audiobookshelf-secondary-source.md as an orchestrator on grok-4.5:
worktree-isolated subagents per PR (workers are Composer via config).
Selective download only (never whole library); ABS for resume; NAS WebDAV
rhapsode-sync for SmartSpeech/Nerd Stats; dual-source with Dropbox OK;
zero SmartSpeech engine changes. Follow PR Plan PR1–PR7. Start with PR1.
```

Hardcover:

```text
/model grok-4.5

Implement specs/integrations/hardcover-progress-scrobble.md as an orchestrator on grok-4.5:
worktree-isolated subagents per PR (workers are Composer via config),
personal token scrobble only, source-domain progress_seconds, zero SmartSpeech changes.
Start with PR1.
```

---

## 11. Doc index

| Path | Role |
|------|------|
| `specs/integrations/README.md` | Index |
| `specs/integrations/audiobookshelf-secondary-source.md` | ABS build contract |
| `specs/integrations/hardcover-progress-scrobble.md` | Hardcover build contract |
| `specs/integrations/agent-orchestration-playbook.md` | This file |
