# arrow-server

A small, self-hostable backend for **Arrow**. It is Arrow's own equivalent of
the services Arc relied on (Firebase Auth + Firestore, LaunchDarkly,
content.arc.net, dia-blocklists, the Arc Max AI proxy, the Sparkle feed,
arc.net sharing and the bug-report endpoint). See
[`docs/ARC_SERVICES.md`](../docs/ARC_SERVICES.md) for the full inventory and
the domain model.

This README is the **API contract** the Swift client follows.

- Go standard library only, plus the official
  [Anthropic Go SDK](https://github.com/anthropics/anthropic-sdk-go) for AI.
- Storage: JSON files under a data directory, written atomically.
- No analytics, no telemetry. Sync payloads are end-to-end encrypted by the
  client; the server only stores opaque blobs.

## Running

```sh
cd server
go run ./cmd/arrow-server                        # listens on :8787, data in ./data
ANTHROPIC_API_KEY=sk-ant-... go run ./cmd/arrow-server -public-url https://arrow.example.com
```

With Docker:

```sh
docker build -t arrow-server --build-arg VERSION=0.1.0 .
docker run -p 8787:8787 -v arrow-data:/data \
  -e ARROW_PUBLIC_URL=https://arrow.example.com -e ANTHROPIC_API_KEY=sk-ant-... arrow-server
```

The server speaks plain HTTP. In production put it behind a TLS-terminating
reverse proxy (Caddy, nginx, ...) and set `ARROW_PUBLIC_URL` to the public
HTTPS origin. Disable proxy buffering for `/v1/sync/events` and
`/v1/ai/messages` (the server already sends `X-Accel-Buffering: no`).

Tests: `go vet ./... && go test ./...` (no network or API key needed).

## Configuration

Flags take precedence over environment variables.

| Flag | Environment | Default | Description |
|---|---|---|---|
| `-addr` | `ARROW_ADDR` | `:8787` | Listen address. |
| `-data-dir` | `ARROW_DATA_DIR` | `./data` | Data directory (created if missing). |
| `-public-url` | `ARROW_PUBLIC_URL` | `http://localhost:8787` | Public base URL used to build share links and block list URLs. Must be an absolute `http(s)` URL. |
| — | `ANTHROPIC_API_KEY` | *(unset)* | Anthropic API key. When unset, `POST /v1/ai/messages` answers `503 ai_disabled` and the default `aiFeatures` flag is `false`. Environment only, so it never appears in `ps`. |
| `-ai-model` | `ARROW_AI_MODEL` | `claude-opus-5-5` | Claude model used for every AI task. |
| `-blocklist-refresh` | `ARROW_BLOCKLIST_REFRESH` | `0` (off) | Download EasyList and EasyPrivacy at this interval (Go duration, e.g. `24h`, minimum `1m`). |

Logs are structured JSON (`log/slog`) on stderr. `SIGINT`/`SIGTERM` trigger a
graceful shutdown (open event streams are closed, in-flight requests get 15 s).

### Local models (Ollama)

The Anthropic SDK honors `ANTHROPIC_BASE_URL`, and recent versions of
[Ollama](https://ollama.com) serve an Anthropic-compatible `/v1/messages`
endpoint. To run the AI features on a local model, without an Anthropic key:

```sh
ANTHROPIC_API_KEY=ollama ANTHROPIC_BASE_URL=http://127.0.0.1:11434 \
  go run ./cmd/arrow-server -ai-model llama3.1
```

Answers are only as good as the local model.

### Data directory

```
data/
├── auth.json                 accounts and session-token digests
├── shares.json               published shares
├── sync/<userId>.json        one file per user: encrypted documents + revision
├── config/                   optional overrides for GET /v1/config
│   ├── flags.json
│   ├── command_bar_behavior.json
│   ├── memory_behavior.json
│   └── web_content_behavior.json
├── blocklists/<id>.txt       filter lists served by /v1/blocklists
├── releases/releases.json    input for the Sparkle appcast
└── feedback/<id>.json        one file per feedback report
```

Files are written to a temporary file, fsynced, then renamed over the
original, so a crash never leaves a partial file. Files are `0600`, folders
`0700`.

## Conventions

- Base path `/v1`. JSON in, JSON out (`Content-Type: application/json`).
- Authenticated endpoints require `Authorization: Bearer <token>`. A missing,
  unknown, revoked or expired token yields `401` with a `WWW-Authenticate`
  header; the client should sign in again.
- Timestamps are RFC 3339 in UTC, e.g. `"2026-10-27T21:42:00Z"`.
- Errors always use this envelope:

  ```json
  {"error": {"code": "invalid_request", "message": "password must be between 8 and 1024 characters"}}
  ```

  `code` is stable and meant for programmatic handling; `message` is for
  humans and may change.
- Unknown paths and wrong methods return `404 not_found`.
- Every response carries `X-Content-Type-Options: nosniff`,
  `X-Frame-Options: DENY`, `Referrer-Policy: no-referrer`,
  `Cross-Origin-Resource-Policy: same-origin` and a restrictive
  `Content-Security-Policy`.
- When a request is rate limited the response is `429 rate_limited` with a
  `Retry-After` header (seconds).

### Error codes

| Status | `code` | When |
|---|---|---|
| 400 | `invalid_request` | Malformed JSON or a field failed validation. |
| 401 | `unauthorized` | Missing/invalid/expired bearer token. |
| 401 | `invalid_credentials` | Wrong email or password on login. |
| 403 | `forbidden` | Deleting someone else's share. |
| 404 | `not_found` | Unknown resource or endpoint. |
| 409 | `email_taken` | Registering an email that already has an account. |
| 413 | `payload_too_large` | Body or sync payload over its limit. |
| 429 | `rate_limited` | Too many requests; see `Retry-After`. |
| 500 | `internal` | Server bug or storage failure (details are only logged). |
| 502 | `ai_upstream_error` | The model provider returned an error. |
| 503 | `ai_disabled` | No `ANTHROPIC_API_KEY` configured. |
| 503 | `ai_unavailable` | The model provider is overloaded or rate limiting us. |

### Limits

| Endpoint | Body limit | Rate limit |
|---|---|---|
| `POST /v1/auth/register`, `POST /v1/auth/login` | 64 KiB | 20/min per client IP |
| `POST /v1/sync/push` | 32 MiB, ≤ 1000 changes, ≤ 1 MiB decoded per payload | — |
| `POST /v1/shares` | 1 MiB | — |
| `POST /v1/ai/messages` | 2 MiB, ≤ 100 messages | 30/min per user |
| `POST /v1/feedback` | 2 MiB | 10/hour per user (or per IP when anonymous) |

---

## Health

### `GET /healthz`

```json
{"status": "ok", "version": "0.1.0"}
```

---

## Accounts (replaces Firebase Auth)

Passwords are hashed with PBKDF2-HMAC-SHA256 (600,000 iterations, random
16-byte salt). Session tokens are 32 random bytes encoded as base64url
(43 chars); the server stores only their SHA-256 digest. Tokens expire 90
days after issue. Each register/login creates a new, independent session.

### `POST /v1/auth/register`

```json
{"email": "ada@example.com", "password": "correct horse battery", "displayName": "Ada"}
```

- `email`: a plain address (no display-name form), ≤ 254 chars. Stored
  lower-cased; matching is case-insensitive.
- `password`: 8–1024 characters.
- `displayName`: optional, ≤ 100 printable characters. Defaults to the part
  of the email before `@`.

`201 Created`

```json
{
  "token": "Vb7rQ0n2y6m3T1x9k8Zq4dP5sLw0eHc2uJfGaYtRiNo",
  "user": {
    "id": "9f1c2a7b4e8d4f6a0b3c5d7e9f1a2b3c",
    "email": "ada@example.com",
    "displayName": "Ada",
    "createdAt": "2026-10-27T21:42:00Z"
  }
}
```

Errors: `400 invalid_request`, `409 email_taken`, `429 rate_limited`.

### `POST /v1/auth/login`

```json
{"email": "ada@example.com", "password": "correct horse battery"}
```

`200 OK` — same body as register (`{"token", "user"}`).

Errors: `401 invalid_credentials` for both unknown emails and wrong
passwords (identical response and comparable timing, so accounts cannot be
enumerated), `429 rate_limited`.

### `POST /v1/auth/logout` (auth)

Revokes the token used for this request. No body. `204 No Content`.

### `GET /v1/me` (auth)

```json
{"user": {"id": "9f1c2a7b4e8d4f6a0b3c5d7e9f1a2b3c", "email": "ada@example.com", "displayName": "Ada", "createdAt": "2026-10-27T21:42:00Z"}}
```

---

## Sync (replaces Firestore)

The server stores **opaque documents** per user. The client encrypts every
payload end to end before upload and the server never sees plaintext.

- `id`: client-chosen, 1–128 chars of `[A-Za-z0-9._:-]` (e.g. a UUID). Unique
  per user.
- `kind`: free-form, `^[A-Za-z][A-Za-z0-9._-]{0,63}$`. Arrow uses `space`,
  `item`, `favorites`, `settings`, `keyEnvelope`.
- `payload`: standard base64 (with padding) of the ciphertext, ≤ 1 MiB once
  decoded. Ignored and stored empty when `deleted` is `true`.
- `revision`: every user has a monotonically increasing counter. Each
  accepted change increments it by one and stamps the document with the new
  value. Deletions are kept as tombstones so other devices learn about them.

### `GET /v1/sync/changes?since=<revision>` (auth)

Returns every document of the user whose `revision` is greater than `since`
(default `0`), ordered by revision, and the current revision. Store the
returned `revision` and pass it as `since` next time.

```json
{
  "revision": 42,
  "changes": [
    {
      "id": "2C1F6A0E-7B1D-4C55-9E0F-3B6A1D2E4F50",
      "kind": "space",
      "payload": "AAECAwQFBgcICQoLDA0ODw==",
      "deleted": false,
      "revision": 41,
      "updatedAt": "2026-10-27T21:42:00Z",
      "deviceId": "C0FFEE00-1111-2222-3333-444455556666"
    },
    {
      "id": "item-7",
      "kind": "item",
      "payload": "",
      "deleted": true,
      "revision": 42,
      "updatedAt": "2026-10-27T21:43:10Z",
      "deviceId": "C0FFEE00-1111-2222-3333-444455556666"
    }
  ]
}
```

`changes` is always an array (never `null`). `400 invalid_request` if
`since` is not a non-negative integer.

### `POST /v1/sync/push` (auth)

```json
{
  "deviceId": "C0FFEE00-1111-2222-3333-444455556666",
  "changes": [
    {"id": "2C1F6A0E-7B1D-4C55-9E0F-3B6A1D2E4F50", "kind": "space", "payload": "AAECAwQFBgcICQoLDA0ODw==", "deleted": false, "baseRevision": 41},
    {"id": "item-8", "kind": "item", "payload": "EBESExQVFhcYGRobHB0eHw==", "deleted": false, "baseRevision": 0},
    {"id": "item-7", "kind": "item", "deleted": true, "baseRevision": 40}
  ]
}
```

- `deviceId`: required, ≤ 128 chars; recorded on each accepted document.
- `baseRevision`: the document revision the device last saw (`0` for a new
  document). **Optimistic concurrency per document**: if the stored
  document's revision is greater than `baseRevision`, the change is a
  conflict and is *not* applied. A document the server has never seen is
  always accepted.
- Changes are applied in order; if the same `id` appears twice, the second
  is checked against the revision the first one produced.

`200 OK`

```json
{
  "revision": 44,
  "accepted": ["2C1F6A0E-7B1D-4C55-9E0F-3B6A1D2E4F50", "item-8"],
  "conflicts": [{"id": "item-7", "serverRevision": 42}]
}
```

`revision` is the user's revision after the push. On a conflict, fetch
`/v1/sync/changes`, merge locally, and push again with the new
`baseRevision`. Validation errors reject the whole push (`400`, or `413` for
an oversized payload) and nothing is applied.

### `GET /v1/sync/events` (auth)

A [Server-Sent Events](https://html.spec.whatwg.org/multipage/server-sent-events.html)
stream (`Content-Type: text/event-stream`). It sends the current revision on
connect and again every time the user's revision changes (a push from any
device, including this one), plus a keep-alive comment every 25 seconds:

```
event: revision
data: {"revision":42}

: keep-alive

event: revision
data: {"revision":44}

```

Events carry only the revision number; react by calling
`GET /v1/sync/changes?since=<last known revision>` when it is higher than
yours. Rapid pushes may be coalesced into one event. The server closes the
stream on shutdown; reconnect with backoff.

---

## Remote configuration (replaces LaunchDarkly and content.arc.net)

### `GET /v1/config`

No authentication.

```json
{
  "flags": {"adBlocker": true, "aiFeatures": true, "sync": true},
  "commandBarBehavior": {"dedupByTitleAndHostList": ["figma.com", "maps.google.com", "notion.so", "app.notion.com", "zoom.us", "opentable.com", "zillow.com", "github.com", "app.mode.com", "console.cloud.google.com"]},
  "memoryBehavior": {"tabDiscardAfterMinutes": 60, "archiveAfterHours": 12},
  "webContentBehavior": {"keepaliveAllowList": [{"urlRegex": "^https://mail\\.google\\.com/mail"}, {"urlRegex": "^https://calendar\\.google\\.com/calendar"}]}
}
```

(`webContentBehavior` default abbreviated.) Each section comes from a file in
`<data-dir>/config/` when present, otherwise from the built-in default:

| Section | File |
|---|---|
| `flags` | `flags.json` |
| `commandBarBehavior` | `command_bar_behavior.json` |
| `memoryBehavior` | `memory_behavior.json` |
| `webContentBehavior` | `web_content_behavior.json` |

A file **replaces** its section entirely (no merge) and must contain a JSON
object; an unreadable or invalid file is logged and the default is served.
Files are re-read on every request, so edits apply without a restart. The
default `aiFeatures` flag is `false` when no Anthropic API key is configured.

The response has a strong `ETag` and `Cache-Control: no-cache`. Send
`If-None-Match: <etag>` to get `304 Not Modified` when nothing changed.

---

## Block lists (replaces dia-blocklists)

Lists are the files `<data-dir>/blocklists/<id>.txt` (Adblock Plus / EasyList
syntax), where `<id>` matches `^[a-z0-9][a-z0-9_-]{0,63}$`; other files are
ignored. Drop in your own lists, or start the server with
`-blocklist-refresh 24h` to download EasyList
(`https://easylist.to/easylist/easylist.txt`) and EasyPrivacy
(`https://easylist.to/easylist/easyprivacy.txt`) at startup and then at that
interval. Downloads are written atomically; a failed download keeps the
previous file.

### `GET /v1/blocklists/manifest.json`

```json
{
  "lists": [
    {
      "id": "easylist",
      "name": "EasyList",
      "url": "https://arrow.example.com/v1/blocklists/easylist",
      "sha256": "3a7bd3e2360a3d29eea436fcfb7e44c735d117c42d1c1835420b6b9942dd4f1b",
      "size": 1843211,
      "updatedAt": "2026-10-27T04:00:12Z"
    }
  ]
}
```

Sorted by `id`; `lists` is `[]` when there are none. `sha256` is the hex
digest of the file; `updatedAt` its modification time.

### `GET /v1/blocklists/{id}`

Serves the raw list as `text/plain; charset=utf-8` with
`ETag: "<sha256>"`. Supports `If-None-Match` (→ `304`), `If-Modified-Since`
and `Range`. `404 not_found` for unknown ids. Verify the body against the
manifest `sha256` before compiling it into content-blocker rules.

---

## Updates (replaces releases.arc.net)

### `GET /v1/updates/appcast.xml`

A Sparkle 2 appcast (`application/rss+xml`). Set Arrow's `SUFeedURL` to
`<ARROW_PUBLIC_URL>/v1/updates/appcast.xml` and `SUPublicEDKey` to **Arrow's
own** EdDSA public key (sign archives with Sparkle's `sign_update`).

It is generated from `<data-dir>/releases/releases.json` (newest first):

```json
[
  {
    "version": "120",
    "shortVersion": "1.2.0",
    "url": "https://github.com/arrow-browser/arrow-browser/releases/download/v1.2.0/Arrow-1.2.0.zip",
    "length": 48213377,
    "edSignature": "3H1u0m...base64...==",
    "minimumSystemVersion": "14.0",
    "releaseNotesHTML": "<h2>What's new</h2><ul><li>Split view</li></ul>",
    "pubDate": "2026-10-01T12:00:00Z"
  }
]
```

`version` is `CFBundleVersion`, `shortVersion` is
`CFBundleShortVersionString`. Output:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>Arrow</title>
    <link>https://arrow.example.com/v1/updates/appcast.xml</link>
    <description>Arrow browser updates</description>
    <language>en</language>
    <item>
      <title>Version 1.2.0</title>
      <pubDate>Thu, 01 Oct 2026 12:00:00 +0000</pubDate>
      <sparkle:version>120</sparkle:version>
      <sparkle:shortVersionString>1.2.0</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <description><![CDATA[<h2>What's new</h2><ul><li>Split view</li></ul>]]></description>
      <enclosure url="https://github.com/arrow-browser/arrow-browser/releases/download/v1.2.0/Arrow-1.2.0.zip" length="48213377" type="application/octet-stream" sparkle:edSignature="3H1u0m...base64...=="></enclosure>
    </item>
  </channel>
</rss>
```

Without `releases.json` the channel has no items. An invalid file yields
`500 internal` (and a log line).

---

## Sharing (replaces arc.net/object, /easel, /note, /boosts)

A share is a **public** snapshot: anyone with the link can read it, so its
payload is stored in plain JSON (unlike sync documents). Only publish what the
user explicitly chose to share.

### `POST /v1/shares` (auth)

```json
{
  "kind": "folder",
  "title": "Reading list",
  "payload": {"items": [{"title": "The Go Blog", "url": "https://go.dev/blog/"}]}
}
```

- `kind`: one of `space`, `folder`, `easel`, `note`, `boost`, `tab`.
- `title`: required, ≤ 200 printable characters.
- `payload`: any JSON value except `null`. For `space` and `folder`, use
  `{"items": [{"title", "url"}]}` so the web page can list the links.

`201 Created`

```json
{"id": "a1B2c3D4e5", "url": "https://arrow.example.com/s/a1B2c3D4e5", "createdAt": "2026-10-27T21:42:00Z"}
```

IDs are 10 random base62 characters.

### `GET /v1/shares/{id}`

No authentication. `404 not_found` if unknown.

```json
{
  "id": "a1B2c3D4e5",
  "kind": "folder",
  "title": "Reading list",
  "payload": {"items": [{"title": "The Go Blog", "url": "https://go.dev/blog/"}]},
  "createdAt": "2026-10-27T21:42:00Z",
  "owner": {"displayName": "Ada"}
}
```

### `GET /v1/shares` (auth)

The caller's shares, newest first (payloads omitted):

```json
{"shares": [{"id": "a1B2c3D4e5", "kind": "folder", "title": "Reading list", "url": "https://arrow.example.com/s/a1B2c3D4e5", "createdAt": "2026-10-27T21:42:00Z"}]}
```

### `DELETE /v1/shares/{id}` (auth)

`204 No Content`. `403 forbidden` if the caller is not the owner,
`404 not_found` if unknown.

### `GET /s/{id}`

A small self-contained HTML page (escaped with `html/template`) showing the
title, kind, owner and, for `space`/`folder`, the list of links (only
`http`/`https` URLs are rendered, with `rel="noopener noreferrer nofollow"`),
plus an **Open in Arrow** link to `arrowBrowser://share/<id>`. The Arrow app
must register the `arrowBrowser` URL scheme and fetch
`GET /v1/shares/<id>` when it receives that URL. The page is served with
`Content-Security-Policy: default-src 'none'; style-src 'sha256-…';
base-uri 'none'; form-action 'none'; frame-ancestors 'none'` (no scripts,
no external resources) and `<meta name="robots" content="noindex">`.

---

## AI (replaces the Arc Max backend)

### `POST /v1/ai/messages` (auth)

```json
{
  "task": "tidy-tab-title",
  "messages": [{"role": "user", "content": "Title: arrow-browser/arrow-browser: An open-source Arc re-implementation\nURL: https://github.com/arrow-browser/arrow-browser"}],
  "stream": false,
  "maxTokens": 256
}
```

- `task`: one of the tasks below. Each has a fixed server-side system prompt.
- `system`: optional, **only** accepted for `chat` (replaces the default chat
  prompt); `400` for any other task.
- `messages`: 1–100 turns, `role` is `user` or `assistant`, `content` is a
  non-empty string, and the **last message must be `user`**. Put page
  content (title, URL, extracted text) in the user message.
- `maxTokens`: optional; clamped to the task maximum, which is also the
  default. It covers the model's internal thinking as well as the answer.
- `stream`: `true` for Server-Sent Events.

| `task` | Arc Max feature | Expected user content | Effort | Max tokens |
|---|---|---|---|---|
| `tidy-tab-title` | Tidy tab titles | `Title: …\nURL: …` → returns 1–5 words | `low` | 1024 |
| `tidy-download-name` | Tidy downloads | `File: …\nURL: …\nPage title: …` → returns a file name | `low` | 1024 |
| `preview-summary` | 5-second link previews | `Title: …\nURL: …\n\n<page text>` → ≤ 5 bullet points | `medium` | 16000 |
| `ask-page` | Ask on page | page text, then the question(s) | `medium` | 16000 |
| `chat` | Command bar / ChatGPT-style chat | free-form | `medium` | 16000 |

Server-side details (not part of the wire contract, listed for reference):
the default model is `claude-opus-5-5` (`ARROW_AI_MODEL`); requests set
`output_config.effort` per task, never send `temperature`/`top_p`/`top_k` or
thinking settings, and opt into Anthropic's server-side refusal fallback
(`fallbacks: "default"`, beta `server-side-fallback-2026-07-01`), so a policy
decline is retried on Anthropic's recommended fallback model within the same
call. The `model` field in responses names the model that actually answered.

#### Non-streaming response

`200 OK`

```json
{"text": "Arrow Browser Repo", "stopReason": "end_turn", "model": "claude-opus-5-5", "usage": {"inputTokens": 61, "outputTokens": 9}}
```

`stopReason` is passed through from the API: `end_turn`, `max_tokens`,
`stop_sequence`, or `refusal`. **When it is `refusal`, `text` is always
empty** — show a "can't help with that" state, not an answer.

#### Streaming response (`"stream": true`)

`200 OK`, `Content-Type: text/event-stream`. One `delta` event per text
chunk, then exactly one `done` event:

```
event: delta
data: {"text":"Arrow "}

event: delta
data: {"text":"Browser Repo"}

event: done
data: {"stopReason":"end_turn","usage":{"inputTokens":61,"outputTokens":9}}

```

If `done.stopReason` is `refusal`, **discard all text received so far**:
a refusal can arrive after partial output. If the provider fails after the
stream started, the server sends a final `error` event instead of `done`:

```
event: error
data: {"error":{"code":"ai_upstream_error","message":"the AI service returned an error"}}

```

Failures before the first event are returned as regular JSON errors with
their HTTP status.

Errors: `400 invalid_request`, `429 rate_limited` (30 requests/min per user),
`502 ai_upstream_error`, `503 ai_disabled`, `503 ai_unavailable`.

---

## Feedback (replaces incoming.browserinternal.com/bug-report)

Arrow sends nothing automatically. This endpoint only receives reports the
user explicitly submits.

### `POST /v1/feedback` (authentication optional)

```json
{
  "message": "The sidebar froze after splitting a tab.",
  "email": "ada@example.com",
  "appVersion": "0.1.0 (12)",
  "osVersion": "macOS 26.1 (25B78)",
  "logs": "2026-10-27 21:40:01 [Sidebar] ...\n"
}
```

- `message`: required, ≤ 20,000 characters.
- `email`: optional, must be a valid address if present (for a reply).
- `appVersion`, `osVersion`: optional, ≤ 64 characters.
- `logs`: optional free text; the whole body is limited to 2 MiB.

If a valid bearer token is sent, the report records the user ID; an invalid
token is ignored and the report is stored anonymously.

`202 Accepted`

```json
{"id": "20261027T214200Z-9e2e8df6e113"}
```

Reports are stored as `<data-dir>/feedback/<id>.json`.

---

## Scaling limits and operational notes

This server targets a person, family or small team. Know its limits:

- **Everything lives in memory and in JSON files.** `auth.json` and
  `shares.json` are rewritten in full on every write (login, share), and a
  user's whole sync file is rewritten on every push. That is fine up to
  hundreds of users and tens of MiB of sync data per user; beyond that,
  replace `internal/store` with SQLite or Postgres behind the same API.
- **Single process only.** Rate limits, the sync event broker and file
  locks are in-process; do not run several replicas against one data dir.
- `GET /v1/sync/changes` is not paginated: a fresh device downloads every
  document in one response.
- Rate limits key on the TCP peer address and deliberately ignore
  `X-Forwarded-For` (spoofable). Behind a reverse proxy all anonymous
  clients therefore share one bucket for login/register and anonymous
  feedback.
- Back up the data directory as a whole while the server is stopped, or
  snapshot it (each file is always internally consistent).
- Expired sessions are pruned on the next login/registration.
