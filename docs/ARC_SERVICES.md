# Arc server dependencies and their Arrow equivalents

Arc (The Browser Company) depended on several hosted services. Arrow does not
reuse Arc's providers: it ships its own small, self-hostable server
([`server/`](../server/README.md)) for the pieces it needs, talks to a few
third parties directly from the app, and drops everything that was analytics.

Inventory source: Arc 1.170.0 (`/Applications/Arc.app`), from
`strings -n 8 Contents/MacOS/Arc` and `Contents/Info.plist`. Firebase hosts
(`identitytoolkit`/`securetoken`/`firestore.googleapis.com`,
`*.cloudfunctions.net`) are built at runtime by the Firebase SDK and do not
all appear as literal URLs.

Status legend: **Replaced** = served by `arrow-server`; **Third party** = the
app calls the provider directly, nothing goes through Arrow's server;
**Dropped** = intentionally not reimplemented.

## Services

| # | Arc service | What it did in Arc | Arc endpoint(s) | Arrow | Arrow endpoint / approach |
|---|---|---|---|---|---|
| 1 | Firebase Auth | Account sign-in; ID tokens for Firestore and cloud functions. | Firebase Auth SDK (Google Identity Toolkit) | **Replaced** | `POST /v1/auth/register`, `POST /v1/auth/login`, `POST /v1/auth/logout`, `GET /v1/me`. Email + password, PBKDF2 hashes, opaque bearer tokens (90 days). |
| 2 | Cloud Firestore | Sync of sidebar, spaces and items across devices. Values were end-to-end encrypted strings (`StorableFirebaseEncryptionKey`; a "recovery card" restored the key on a new device). | Firestore SDK | **Replaced** | `GET /v1/sync/changes`, `POST /v1/sync/push`, `GET /v1/sync/events` (SSE). Opaque E2E-encrypted documents (AES-GCM) with per-user revisions and per-document optimistic concurrency. The 256-bit key stays in the Keychain and is moved to another Mac as a recovery key (Arc's recovery card). |
| 3 | Firebase Cloud Functions | Server-side helpers behind sharing and account features. | `*.cloudfunctions.net` | **Replaced** | Folded into the endpoints above and `/v1/shares`. |
| 4 | Apple CloudKit | Older sidebar sync path (`ARC_SidebarSyncCloudKit` bundle). | CloudKit private database | **Dropped** | Superseded by `/v1/sync`; avoids tying self-hosted sync to an Apple account. |
| 5 | LaunchDarkly | Feature flags, streamed to the client. | `clientstream.launchdarkly.com`, `mobile.launchdarkly.com` (`app.launchdarkly.com` dashboard) | **Replaced** | `GET /v1/config` → `flags` (operator-edited `config/flags.json`, polled with `ETag`). No per-user targeting or experiments. |
| 6 | Remote behavior configs | Tunables fetched at runtime: command-bar dedup hosts, tab memory/archiving, web-content keep-alive list. | `https://content.arc.net/command_bar_behavior.json`, `memory_behavior.json`, `web_content_behavior.json` | **Replaced** | `GET /v1/config` → `commandBarBehavior`, `memoryBehavior`, `webContentBehavior`, each with a built-in default. |
| 7 | Ad/tracker block lists | Filter lists for the built-in ad blocker, described by a manifest. | `https://dia-blocklists-release.diabrowser.engineering/manifest.json` | **Replaced** | `GET /v1/blocklists/manifest.json`, `GET /v1/blocklists/{id}`; optional periodic download of EasyList and EasyPrivacy (`-blocklist-refresh`). |
| 8 | Arc Max AI backend | Ask on page, 5-second link previews, tidy tab titles, tidy downloads, chat. Proxied Anthropic and OpenAI models. | `https://ai-service.diabrowser.engineering/aiproxy` (+ `ai-service-eval`, `ai-service.staging`), `https://aiproxy.diabrowser.engineering/api/dia-claude-stream`, `https://webresultproxy.diabrowser.engineering/api/claude-stream`, `/api/open-ai-chat-stream` | **Replaced** | `POST /v1/ai/messages` with a fixed task list (`tidy-tab-title`, `tidy-download-name`, `preview-summary`, `ask-page`, `chat`), backed by Claude via the official Anthropic SDK. The API key stays on the server; disabled (503) when unset. |
| 9 | Web-results proxy | Search results fed to AI features ("Browse for Me"). | `https://webresultproxy.diabrowser.engineering/api/web-results`, `https://websearch.diabrowser.engineering/api/web-results` | **Dropped** (for now) | No search-results API in v1; the app opens a normal search instead. |
| 10 | Remote assets CDN | Downloadable app artifacts/assets. | `https://artifactcdn.diabrowser.engineering/` | **Dropped** | Assets ship inside the app bundle. |
| 11 | Sparkle update feed | Auto-update appcast, verified with Arc's EdDSA key (`SUPublicEDKey`). | `https://releases.arc.net/updates.xml` (`SUFeedURL`) | **Replaced** | `GET /v1/updates/appcast.xml`, generated from `releases/releases.json`. Arrow signs with its own EdDSA key. |
| 12 | Datadog | Product analytics, logs and RUM. | `https://browser-intake-datadoghq.com/` (+ `.eu`, `us3`, `us5`, `ap1`) | **Dropped** | Privacy: Arrow collects no analytics or telemetry. |
| 13 | Sentry | Crash and error reporting. | `https://…@o298668.ingest.sentry.io/5513396` | **Dropped** | Privacy. Users can attach logs to opt-in feedback instead (row 14). |
| 14 | Bug reports | In-app "send feedback / report a bug". | `https://incoming.browserinternal.com/bug-report` | **Replaced** | `POST /v1/feedback` (opt-in, user-initiated only; stored as JSON files). |
| 15 | Sharing | Public links to shared objects, Easels and Notes. | `https://arc.net/object`, `https://arc.net/easel`, `https://arc.net/note` | **Replaced** | `POST/GET/DELETE /v1/shares`, public page `GET /s/{id}`, deep link `arrowBrowser://share/<id>`. |
| 16 | Boost gallery | Browse and install community Boosts. | `https://arc.net/boosts?ref=arc-app` | **Replaced** (partially) | A Boost can be published as a share (`kind: "boost"`); there is no curated public gallery. |
| 17 | Redirect-link image helper | Image endpoint for redirect links (purpose inferred from the path). | `https://arc.net/api/redirect-links/image?url=` | **Dropped** | The share page renders text links only; the app loads images directly. |
| 18 | Gift / referral | Invite and gift flow. | `https://arc.net/gift/` | **Dropped** | Arrow has no referral program. |
| 19 | Web pages and help | Onboarding, release notes, privacy policy, Max tutorial, farewell, help center. | `arc.net/welcome-to-arc`, `/get-started-with-arc`, `/release-notes`, `/privacy`, `/max/tutorial`, `/farewell`, `help.diabrowser.com` | **Dropped** | Documentation lives in the Arrow repository. |
| 20 | Google search suggestions | Command-bar suggestions. | `https://www.google.com/complete/search?q=` | **Third party** | Called directly by the app (provider configurable in the client). |
| 21 | Google favicons | Favicon fallback for tabs and pinned items. | `https://www.google.com/s2/favicons?sz=…&domain_url=` | **Third party** | Called directly by the app. |
| 22 | Google integrations | Calendar/Gmail/Drive previews and quick actions, via the user's Google sign-in. | `accounts.google.com`, `calendar.google.com`, `mail.google.com`, `docs.google.com`, `drive.google.com` | **Third party** | OAuth and API calls stay on the device; tokens never reach Arrow's server. |
| 23 | Microsoft integrations | Outlook calendar and mail previews. | `https://login.microsoftonline.com/common/oauth2/nativeclient`, `https://graph.microsoft.com/v1.0/me/calendar/calendarView`, `/v1.0/me/mailFolders/Inbox/messages`, `outlook.live.com` deep links | **Third party** | Same as row 22. |
| 24 | App Store lookup | App metadata lookup by bundle ID. | `https://itunes.apple.com/lookup?bundleId=` | **Third party** | Called directly if the feature is kept. |

## Domain model

Business entities behind Arc's server usage and how Arrow models them.
**Owner** says where the source of truth lives:

- **client-only**: stored on the Mac, never uploaded;
- **synced (E2E)**: the client encrypts the entity and syncs it as an opaque
  sync document of the given `kind` (`/v1/sync/*`, stored in
  `sync/<userId>.json`); the server sees only `id`, `kind`, `revision`,
  `deviceId` and `updatedAt`;
- **server-native**: the server owns and understands the data.

| Entity | Key fields | Owner | Backed by |
|---|---|---|---|
| Account / User | `id`, `email`, `displayName`, `passwordHash`, `createdAt` | server-native | `auth.json`; `/v1/auth/*`, `GET /v1/me` |
| Session token | token (client Keychain), `sha256(token)`, `userId`, `createdAt`, `expiresAt` (90 days) | server-native (digest only) | `auth.json`; `Authorization: Bearer` |
| Device | `deviceId` (UUID generated per install), local name | client-generated; the server records it, no registry | `deviceId` on every sync document (Arc: `originatingDevice`, `lastChangedDevice`) |
| Sync key | 256-bit AES-GCM key (Arc: `StorableFirebaseEncryptionKey` + recovery card) | client-only (Keychain); exported/imported as a recovery key | Never sent to the server. The `keyEnvelope` kind is reserved for a future wrapped-key flow |
| Profile | `id`, `name`, `isDefault`; isolated cookies, storage and cache (one Chromium request context and cache directory per profile) | client-only; website data never leaves the device | Local store. Spaces refer to it by `profileID` (Arc: `profile: {default}` or `{custom}`) |
| Space | `id`, `title`, `icon`, `theme` (gradient colors, harmony, light/dark/automatic, intensity, grain), `profileID`, `pinned` and `today` item trees | synced (E2E) `space` — one document per space, including its item tree | `/v1/sync/*` |
| Space order and profiles | ordered space IDs (Arc: `orderedSpaceIDs`), profile list | synced (E2E) `settings` document `layout` | `/v1/sync/*` |
| SidebarItem | `id`, `parentID`, ordered `childrenIDs`, `type` (`tab`, `folder`, `splitView`, `easel`, `note`), `title`, `createdAt`, `isUnread`, `originatingDevice`; tab: `savedURL` (pinned URL), `currentURL`, `savedTitle`, `isMuted`, `timeLastActiveAt` | synced (E2E) inside its `space` document (the `item` kind is reserved for finer-grained sync) | Arrow models the tree as nested values (`Tab`, `Folder`, `SplitView`); notes and easels are `arrow://note/<id>` / `arrow://easel/<id>` tabs |
| Favorites | per-profile "top apps": ordered tabs keyed by `profileID` | synced (E2E) `favorites` document | `/v1/sync/*` |
| Settings | user preferences that should follow the account, space order | synced (E2E) `settings` | `/v1/sync/*` |
| Archive entry | `id`, `url`, `title`, `spaceID`, `profileID`, `archivedAt`, `reason` (`closed` or `autoArchived`) | client-only | Local store; auto-archive delay comes from `memoryBehavior.archiveAfterHours` |
| Boost | `id`, `domain`, `name`, `isEnabled`, `css`, `js`, `colors`, `font`, `zapRules` (hidden selectors) | client-only | Local store; publishable as a Share (`kind: "boost"`). Could sync later as its own E2E kind (kinds are free-form) |
| Share | `id` (10-char base62), `kind` (`space`, `folder`, `easel`, `note`, `boost`, `tab`), `title`, `payload` (plain JSON), `ownerId`, `createdAt` | server-native, public by design | `shares.json`; `/v1/shares*`, `GET /s/{id}` |
| Feature flags and behavior configs | `flags`, `commandBarBehavior`, `memoryBehavior`, `webContentBehavior` | server-native, read-only for clients | `config/*.json` + built-in defaults; `GET /v1/config` |
| Block list | `id`, `name`, `url`, `sha256`, `size`, `updatedAt`, list text | server-native | `blocklists/*.txt`; `/v1/blocklists/*` |
| Release | `version`, `shortVersion`, `url`, `length`, `edSignature`, `minimumSystemVersion`, `releaseNotesHTML`, `pubDate` | server-native, maintained by the operator | `releases/releases.json`; `GET /v1/updates/appcast.xml` |
| Feedback | `id`, `receivedAt`, `userId?`, `message`, `email?`, `appVersion`, `osVersion`, `logs?` | server-native, write-only | `feedback/<id>.json`; `POST /v1/feedback` |

Notes:

- **From Arc's local shape.** Arc's `StorableSidebar.json` gives each space
  `containerIDs` / `newContainerIDs` as a tagged list
  (`[{pinned:{}}, id, {unpinned:{_0:{shared:{}}}}, id]`). Arrow replaces it
  with explicit `pinned` and `today` lists on the space. Arc's
  `customInfo.iconType` and `customInfo.windowTheme` (palettes, `blendedGradient`
  with `baseColors`/`overlayColors`, `noiseFactor`, `intensityFactor`,
  `overlay: "grain"`, `isVibrant`) become `icon` and `theme`. Items keep Arc's
  `id`, `parentID`, `childrenIds`, `createdAt`, `isUnread`,
  `originatingDevice`, `title` and `data.tab.{savedURL, savedTitle,
  savedMuteStatus, timeLastActiveAt}`.
- **From Arc's sync state.** Arc kept `syncData {dataEra, items: [encrypted],
  spaceModels: [encrypted], orderedSpaceIDs: {value, lastChangeDate,
  lastChangedDevice}}`. In Arrow each space (with its items) is its own
  encrypted document; the server-assigned `revision` plus `deviceId` and `updatedAt`
  replace `lastChangeDate`/`lastChangedDevice`, and per-document conflicts
  replace whole-blob last-writer-wins. A full reset (Arc's `dataEra`) is a
  push of tombstones followed by new documents.
- **Privacy boundary.** Browsing data (profiles' cookies and storage,
  history, archive, Boost code) stays on the device. Only E2E-encrypted sync
  documents, explicit shares and explicit feedback reach the server.
