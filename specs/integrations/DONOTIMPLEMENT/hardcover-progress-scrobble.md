# Hardcover progress scrobble

> **DO NOT IMPLEMENT** as a client integration. Deferred. Hardcover scrobble belongs on **rhapsode-server** (server-side). Active path: [`../rhapsode-server/`](../rhapsode-server/).

**Status:** DONOTIMPLEMENT (historical research)  
**Audience:** Reference only  
**Scope:** ~~Client-side Hardcover~~ superseded by server worker in Rhapsode Server SPEC phase 2.

---

## 1. Goal

Let users who track books on Hardcover push Rhapsode listening activity:

1. Link a Rhapsode `Audiobook` to a Hardcover book/edition (manual search + confirm).
2. On listen milestones, update Hardcover status + **progress_seconds** (audiobook-aware).
3. Optionally open the book on Hardcover via stable ID URL.

Hardcover is **not** a file backend. Dropbox and/or Audiobookshelf remain the library sources.

---

## 2. Explicit non-goals

| Non-goal | Why |
|----------|-----|
| Importing the Hardcover library into Rhapsode shelf | Different product; optional later |
| Using Hardcover as media host | No audio files |
| SmartSpeech / engine changes | Scrobble is progress I/O only |
| Browser-side GraphQL with embedded token | Docs forbid insecure token use |
| Pagebound | No public API |
| OAuth “Sign in with Hardcover” | Not available yet (docs: planned). v1 = personal API token |

---

## 3. Why Hardcover (context for agents)

- Documented GraphQL API used by website + official apps: https://docs.hardcover.app/api/getting-started/
- Endpoint: `https://api.hardcover.app/v1/graphql`
- Auth: personal API token header `authorization: <token>` (from https://hardcover.app/account/api)
- Audiobook-aware: editions with `edition_format`, `audio_seconds`, `asin`; progress supports `progress_seconds`
- Community precedent: Audiobookshelf→Hardcover sync, KOReader plugins, Softcover iOS client
- Beta caveats: schema may change; 60 req/min; tokens expire ~yearly; max query depth 3

---

## 4. Product behavior (v1)

### 4.1 Settings

- Section **Hardcover**
- Field: API token (secure entry → Keychain)
- Help text: how to get token; warning that token is full account power; link to docs
- Toggle: **Scrobble listening progress to Hardcover**
- Optional: minimum interval between progress writes (default 120s) and minimum delta (default 60 source-seconds)

### 4.2 Link book UI

From player sheet or book detail:

1. **Link to Hardcover…**
2. Search query (prefill title + author)
3. Show results (title, authors, rating count, has_audiobook)
4. User picks work → optionally pick **audiobook edition** (prefer `edition_format == "audiobook"`)
5. Persist link on local `Audiobook`

Unlink control clears stored IDs (does not delete remote user_book).

### 4.3 Scrobble rules

Only when: toggle ON + valid token + book linked.

| Trigger | Action |
|---------|--------|
| First play of a linked book | Ensure `user_book` exists; set status **Currently Reading** (`status_id: 2`) if Want/empty |
| Progress while playing | Throttled update `progress_seconds` (and/or pages if edition is print — prefer seconds for audio editions) |
| Pause / background / app resign active | Flush pending progress |
| Finish last track / mark finished | status **Read** (`status_id: 3`), set finished date, progress complete |
| Manual “Mark finished” if exists | Same |

**Always use source-domain seconds** (original file timeline), never SmartSpeech output-domain time.

### 4.4 Matching quality

- Prefer editions with `edition_format` audiobook and matching duration when metadata allows.
- If only print edition linked, still scrobble status; progress_seconds may be less meaningful — prefer forcing audiobook edition selection in UI when available.
- Never invent ISBN matches without user confirm in v1 (manual link only).

### 4.5 Errors

- 401 → prompt re-enter token; disable scrobble until fixed
- 429 → exponential backoff
- Network offline → queue last desired state in memory/disk; flush later (last state wins OK for v1)

---

## 5. API surface (implementer reference)

### 5.1 Auth & limits

```http
POST https://api.hardcover.app/v1/graphql
authorization: <token>
Content-Type: application/json
User-Agent: Rhapsode/iOS (hardcover-scrobble)
```

- Rate limit: **60 requests/minute**
- Query timeout: 30s
- Max depth: 3
- Token: personal; store Keychain only
- Docs say: not for browser; offline/scripts — mobile personal-token clients exist in the wild (Softcover). Still treat token as secret.

### 5.2 Useful operations (names from public schema / docs)

**Who am I**

```graphql
query { me { id username } }
```

**Search books**

```graphql
query SearchBooks($q: String!) {
  search(query: $q, query_type: "Book", per_page: 10, page: 1) {
    results
  }
}
```

Search result fields of interest: title, author_names, isbns, has_audiobook, audio_seconds, slug, id (as returned by Typesense payload — verify shape against live API).

**Editions for a book**

```graphql
query Editions($bookId: Int!) {
  editions(where: { book_id: { _eq: $bookId } }) {
    id
    title
    edition_format
    audio_seconds
    asin
    isbn_13
    pages
  }
}
```

**Create user book**

```graphql
mutation InsertUserBook($object: UserBookCreateInput!) {
  insert_user_book(object: $object) {
    id
    # verify return shape against schema
  }
}
```

`UserBookCreateInput` includes: `book_id`, `edition_id`, `status_id`, dates, rating, etc.

**Status IDs**

| id | Status |
|----|--------|
| 1 | Want to Read |
| 2 | Currently Reading |
| 3 | Read |
| 4 | Paused |
| 5 | Did Not Finish |
| 6 | Ignored |

**Progress (reads)**

Schema mutations (public `schema.graphql` in hardcover-docs):

- `insert_user_book_read(user_book_id:, user_book_read: DatesReadInput!)`
- `update_user_book_read(id:, object: DatesReadInput!)`
- `upsert_user_book_reads(...)`
- `update_user_book(id:, object: UserBookUpdateInput!)`

`DatesReadInput` includes:

- `progress_pages`
- `progress_seconds`
- `edition_id`
- `started_at` / `finished_at`
- `action`

**Guides:**

- Progress read: https://docs.hardcover.app/api/guides/gettingbooksprogress/
- Updating progress guide exists but may be draft — trust schema + community clients if docs incomplete.

### 5.3 Stable deep links

```
https://hardcover.app/id/book/{id}
https://hardcover.app/id/edition/{id}
```

Use for “Open in Hardcover”.

---

## 6. Data model (SwiftData)

Additive optional fields on `Audiobook` (no `@Attribute(.unique)`):

| Field | Type | Purpose |
|-------|------|---------|
| `hardcoverBookId` | `Int?` | Work id |
| `hardcoverEditionId` | `Int?` | Preferred edition |
| `hardcoverUserBookId` | `Int?` | Cached user_books row |
| `hardcoverUserBookReadId` | `Int?` | Cached active read row if needed |
| `hardcoverLinkedAt` | `Date?` | Diagnostics |
| `hardcoverLastScrobbleAt` | `Date?` | Throttle |
| `hardcoverLastProgressSeconds` | `Double?` | Throttle / avoid no-op writes |

Settings (UserDefaults or small prefs type, not necessarily SwiftData):

- `hardcoverScrobbleEnabled: Bool`
- `hardcoverToken` → Keychain only
- throttle constants

---

## 7. Architecture

```
AudiobookPlayer (source progress events)
        │
        ▼
HardcoverScrobbler (actor) ── throttle / queue
        │
        ▼
HardcoverClient (GraphQL HTTP)
        │
        ▼
api.hardcover.app
```

- **Do not** put GraphQL in SwiftUI views.
- Scrobbler observes the same moments Dropbox `ProgressSync` already cares about (pause, finish, periodic). Prefer a single “progress sink” fan-out if refactoring is cheap; otherwise call scrobbler from existing player save points.
- Independent of `LibrarySource` (Dropbox/ABS). Works for any local `Audiobook`.

### Suggested types

```
Sources/Integrations/Hardcover/HardcoverClient.swift
Sources/Integrations/Hardcover/HardcoverScrobbler.swift
Sources/Integrations/Hardcover/HardcoverModels.swift
Sources/Integrations/Hardcover/HardcoverKeychain.swift  // or extend KeychainTokenStore
```

Or under `Sources/Source/` / `Sources/Sync/` if project prefers existing folders — keep a clear `Hardcover*` prefix.

---

## 8. Files likely touched

```
Sources/Integrations/Hardcover/*          # NEW (or Sources/Sync/Hardcover*)
Sources/Source/KeychainTokenStore.swift   # token key
Sources/Model/Models.swift                # optional link fields
Sources/Audiobook/AudiobookPlayer.swift   # emit scrobble hooks
Sources/Audiobook/PlayerView.swift        # Link UI entry
Sources/App/SettingsView.swift            # token + toggle
project.yml                               # if needed for new files
```

**Do not modify:**

```
Sources/SmartSpeechLive/**
SmartSpeechKit/**
```

---

## 9. Privacy & safety

- Token never logged, never written to Dropbox sync JSON.
- User-Agent identifies Rhapsode.
- Scrobble is opt-in.
- Respect Hardcover ToS / ownership: only the authenticated user’s data.
- If user unlinks, stop writes; leave remote history intact.

---

## 10. Testing

| Layer | What |
|-------|------|
| Unit | Throttle logic; status transitions; source-seconds mapping for multi-file books |
| Fixture | GraphQL JSON samples for search / me / insert (record once with a test account) |
| Manual | Token connect → search → link → play 2 minutes → verify Currently Reading + progress on hardcover.app |
| Rate limit | Burst protection does not exceed 60/min under rapid seeks |
| Regression | Player + SmartSpeech unchanged; books without link behave as today |

---

## 11. Acceptance criteria

1. User can store a Hardcover API token securely and enable scrobble.
2. User can search and link a book to an audiobook edition.
3. Listening updates Hardcover to Currently Reading with increasing `progress_seconds` (throttled).
4. Finishing a book sets Read + finished date.
5. Source-domain times only (verify against SmartSpeech-on session: position matches original timeline).
6. Unlinked books never call the API.
7. Invalid token surfaces a clear Settings error.
8. No SmartSpeechLive/SmartSpeechKit changes.

---

## 12. PR Plan (suggested DAG)

### PR 1: HardcoverClient + Keychain + Settings token field

- **Description:** GraphQL transport, `me` probe, token storage, Settings connect/test.
- **Files:** Client, Keychain, Settings
- **Dependencies:** None

### PR 2: Search + link UI + model fields

- **Description:** Search books/editions; persist ids on `Audiobook`; open-in-Hardcover link.
- **Files:** Models, Player/detail UI, client search
- **Dependencies:** PR 1

### PR 3: Scrobbler

- **Description:** Status + progress_seconds on play/pause/finish; throttle; basic offline last-state queue.
- **Files:** Scrobbler, player hooks
- **Dependencies:** PR 2

### PR 4: Polish

- **Description:** Error UX, rate-limit backoff, edition preference heuristics, DEBUG logging behind flag.
- **Files:** Scrobbler, Settings
- **Dependencies:** PR 3

---

## 13. Defaults for open questions

| Decision | Default |
|----------|---------|
| Auto-match without UI | Off |
| Import Hardcover shelf into Rhapsode | Out of scope |
| Two-way sync (pull Hardcover position into player) | Out of v1 (push only) |
| Scrobble ebooks | Out of v1 |
| OAuth | Wait for Hardcover; keep token path |

---

## 14. References

- Getting started: https://docs.hardcover.app/api/getting-started/
- Searching: https://docs.hardcover.app/api/guides/searching/
- Getting progress: https://docs.hardcover.app/api/guides/gettingbooksprogress/
- Schema dump: https://github.com/hardcoverapp/hardcover-docs/blob/main/schema.graphql
- Showcase (prior art): https://docs.hardcover.app/showcase/ (Audiobookshelf sync, KOReader, Softcover)
- Community writeup: https://www.emgoto.com/hardcover-book-api/
