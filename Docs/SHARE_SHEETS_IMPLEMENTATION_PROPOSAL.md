# Autohop — Sharing System Implementation Proposal

<!--
AI CONTEXT — Docs/SHARE_SHEETS_IMPLEMENTATION_PROPOSAL.md

PURPOSE:
Authoritative, staged, AI-executable proposal for replacing Autohop's current
single-purpose episode share sheet with a safe, cost-neutral sharing system
covering episode, podcast, playback-position, chapter, recap, inbound iOS, and
tvOS QR sharing.

SOURCE AND REVIEW STATUS:
Written 2026-07-20 after three rounds of independent Codex and Claude code
review plus cross-review. The reviewers converged with no remaining technical
disagreement. Current-state claims were checked against the live Autohop tree.
The private TWiT and generic NPR-link observations are user-library evidence
verified during the cross-review; this document deliberately records no
credential, private URL, token, or members-only enclosure.

STATUS: PROPOSAL — NOT STARTED.
No application or website code was changed while creating this document.
Kevin authorises each implementation stage separately. An executing model must
complete one stage, run that stage's tests, update the execution ledger, then
stop at its gate unless Kevin explicitly authorises multiple stages.

NON-NEGOTIABLE EXECUTION RULES:
- Read this document completely before editing sharing, RSS parsing, routing,
  App Group, website, privacy, or tvOS code.
- Read the AI CONTEXT headers in Views/EpisodeShareSheet.swift,
  Views/EpisodeShareCardView.swift, Models/Episode.swift,
  Feeds/RSSParser.swift, App/AppRoutingCoordinator.swift, and
  App/AppCompositionRoot.swift before implementation.
- Read DESIGN.md, FEATURES.md, PAGES.md, SYNC_DESIGN.md, project_autohop.md,
  and Docs/WIDGETS_IMPLEMENTATION_PROPOSAL.md for current architecture.
- Preserve the completed AppState decomposition. Sharing policy belongs in
  typed models/services/coordinators, never back in AppState.
- Every new or materially changed source file receives an accurate AI CONTEXT
  header. Update existing headers when behavior changes.
- Xcode project changes go through project.yml and xcodegen. Never hand-edit
  project.pbxproj.
- Private/member feed safety is fail-closed. Convenience never overrides it.
- Universal Links may identify PUBLIC feeds only. No private feed URL, private
  GUID, enclosure, credential, local path, or account identifier enters a
  shared link.
- The website landing route is stateless, performs no arbitrary feed fetch,
  stores no share record, and contains no tracking/analytics.
- No stage may introduce a paid API, new subscription service, hosted media,
  server-rendered card, link shortener, or ongoing storage requirement.
- Never share an enclosure automatically. It is not a substitute for an
  episode webpage.
-->

## 1. Product outcome

Autohop will provide one coherent sharing system with these capabilities:

1. Share an episode as a public link, branded card, structured details, or
   card plus link.
2. Share the active listening position and current chapter from Player.
3. Share a podcast as a podcast, rather than silently sharing its newest
   episode.
4. Protect private/member feeds and paid enclosures by default.
5. Open safe public Autohop links directly in the installed app, including an
   optional timestamp.
6. Give recipients without Autohop a generic, stateless website landing page
   with App Store and publisher-page choices.
7. Accept podcast/RSS/webpage links from other apps through a lightweight iOS
   Share Extension.
8. Produce portrait, square, story, and listening-recap cards on-device.
9. Provide a QR equivalent on tvOS, where a conventional share sheet is not
   available.
10. Continue using Apple system sharing for delivery; Autohop does not build a
    messaging service or recipient directory.

The recipient must not need an Autohop account. Public publisher links remain
useful without Autohop installed.

## 2. Cost and privacy boundaries

### 2.1 Permitted zero-marginal-cost technology

| Capability | Technology | Standing cost |
|---|---|---:|
| System destination picker | `UIActivityViewController` / `ShareLink` | None |
| Cards | SwiftUI `ImageRenderer` | None |
| Rich link previews | Link Presentation | None |
| QR codes | Core Image | None |
| Public deep links | Associated Domains / Universal Links | None |
| Inbound hand-off | iOS Share Extension + existing App Group | None |
| Artwork | Existing `ArtworkImageCache` | None |
| Diagnostics | Existing local `AppLogger` | None |
| Generic web fallback | Existing kevmarl.com deployment | No new service |

### 2.2 Prohibited architecture

- Paid metadata, attribution, shortening, QR, analytics, or card APIs.
- A share database or server-side share record.
- Server-side fetching/parsing of a URL supplied in `/listen` parameters.
- Hosted audio/video clips or copied podcast media.
- Tracking redirects, pixels, fingerprinting, recipient analytics, or account
  correlation.
- Raw private-feed URLs or raw enclosures in activity payloads, logs, QR codes,
  Universal Links, pasteboard items, or website HTML.
- Claims that a publisher homepage is an episode page.

### 2.3 Existing-site qualification

The Universal Link lander uses infrastructure Autohop already maintains, but it
still creates a small maintenance and privacy surface. It therefore has a hard
operational contract:

- static/generic response assembled only from bounded validated parameters;
- no upstream network request;
- no persistent storage;
- no application analytics;
- no raw query-string logging added by Autohop;
- strict parameter and total-URL limits;
- a Privacy Policy disclosure that a normal web request reaches the existing
  site infrastructure.

If the deployed platform cannot meet this contract, Stage 2 stops and the
device-side sharing stages continue without Universal Links.

## 3. Verified current-state audit

### 3.1 Content-sharing implementation

The only content share flow is:

- `Views/EpisodeShareSheet.swift`
- `Views/EpisodeShareCardView.swift`

`EpisodeShareSheet` currently:

1. derives the podcast name from Subscription, Episode author, or a fallback;
2. prefers subscription artwork over episode artwork;
3. resolves a link in this order:
   - `Episode.episodeLink` parsed from RSS `<item><link>`;
   - an HTTP(S) `Episode.guid`;
   - raw `Episode.audioURL` enclosure;
4. loads 176-point artwork through `ArtworkImageCache`;
5. previews a fixed 280×360-point card in a fixed 580-point bottom sheet;
6. renders the card at 3× using `ImageRenderer`;
7. passes two activity items: the UIImage and a URL-backed
   `UIActivityItemSource` with `LPLinkMetadata`.

The current card contains artwork, episode title, podcast name, publication
date, and Autohop branding.

### 3.2 Actual entry points

There are four real presentation locations:

| Location | Current behavior |
|---|---|
| Player | Shares the active episode |
| Podcast Detail toolbar | Shares `subscription.newestEpisode`, not the podcast |
| Podcast Settings toolbar | Shares `subscription.newestEpisode`, not the podcast |
| Episode Detail | Shares that episode |

There is no row-level share action on Podcast Detail, Up Next, Listening
History, or Downloads. Earlier review wording that claimed Podcast Detail rows
already shared was incorrect.

### 3.3 Separate document export surfaces

- Diagnostic Log uses `ShareLink` with a redacted temporary log.
- Feed Refresh Schedule uses `ShareLink` with a generated text report.
- OPML uses a document exporter.

These are document exports, not episode/podcast sharing. They may later reuse
temporary-file and diagnostics infrastructure, but must retain their
appropriate document semantics.

### 3.4 Verified defects and risks

#### Defect A — podcast share misrepresents its payload

Podcast-page toolbar icons visually mean "share this podcast" but select the
newest episode. This is a live correctness defect, not merely a missing
feature.

#### Defect B — raw enclosure fallback

An enclosure is a delivery URL, not a durable public page. It may be temporary,
members-only, signed, authenticated, enormous, or a direct download. Current
code shares it silently when better links are absent.

Cross-review of an actual private members feed found token-free enclosure URLs
that still granted access to paid content to anyone holding the URL. Therefore
query-key scanning alone is insufficient.

#### Defect C — syntactically valid is not semantically useful

An actual generated-feed example supplied a generic publisher homepage as the
episode `<link>`. Current code accepts it because it is HTTP(S), even though it
does not identify the episode.

#### Defect D — destination-dependent multi-item behavior

The card UIImage and rich URL are separate activity items. Destination apps may
send both, accept one, attach them differently, or ignore supplied metadata.
The user cannot currently choose the intended payload.

#### Defect E — fixed presentation and weak failure recovery

- Fixed 580-point sheet can fail with large Dynamic Type, localization, small
  screens, future iPad layouts, or additional controls.
- Card rendering failure silently reduces the payload.
- No explicit "no safe public link" explanation exists.
- Activity completion/cancellation/failure is not captured.
- There are no resolver or share-payload tests.

## 4. Product vocabulary and payload types

Use explicit types. Do not model sharing as an unstructured `[Any]` until the
final UIKit adapter boundary.

### 4.1 Subject types

- `episode`
- `podcast`
- `playbackMoment` (episode + elapsed time + optional chapter)
- `listeningRecap`
- `documentExport`
- `inboundURL`

### 4.2 User-selectable episode modes

| Mode | Payload |
|---|---|
| Link Only | Title/podcast context plus safe public URL |
| Card + Link | Rendered card plus safe public URL |
| Episode Details | Plain text: episode, podcast, date/duration when known, safe URL when available |
| Listening Position | Details plus elapsed time and optional current chapter |
| Card Only / Save Card | Rendered image without an implicit second item |
| Copy Link | Safe public URL only; disabled with explanation when unavailable |

The first release keeps one obvious primary action. Advanced modes remain
secondary choices rather than forcing a decision on every share.

### 4.3 Podcast modes

- Podcast Link
- Podcast Card + Link
- Podcast Details
- Card Only / Save Card

Podcast sharing never substitutes a newest episode.

## 5. Feed privacy classification

### 5.1 Required model

Every share resolver receives an explicit privacy classification:

- `public`
- `privateOrMember`
- `unknown`

This classification is feed-level. It governs every URL derived from that feed.

### 5.2 Fail-closed rules

For `privateOrMember`:

- card-only and details-only are allowed;
- public-link, enclosure, Copy Link, Universal Link, and QR modes are disabled;
- no feed/GUID/enclosure value is logged;
- the UI explains: "This podcast uses a private or members-only feed, so
  Autohop will not share its links."

For `unknown`:

- a separately verified public publisher episode page may be shared;
- no enclosure or feed-address fallback;
- no Universal Link containing the feed address until classified public;
- card/details modes always remain available.

For `public`:

- safe public publisher and Universal Link modes are allowed;
- raw enclosure still does not become the automatic fallback.

### 5.3 Classification evidence

Automatic private/member evidence includes:

- URL user-info credentials;
- recognized credential/auth/signature query fields;
- an existing private-feed/import flag;
- authentication challenge or private-feed workflow evidence;
- an explicit user selection;
- known subscription provenance that marks the feed members-only.

Opaque secrets may appear in URL paths and cannot be reliably detected.
Therefore:

- subscriptions added through public search/catalog resolution may default
  public;
- suspicious or authenticated manual RSS additions default private;
- ordinary manual RSS with insufficient evidence defaults unknown;
- Podcast Settings eventually exposes a clear privacy classification override.

Implementation must never write example secret values into fixtures or logs.

### 5.4 Persistence and sync decision

Persist the classification with subscription settings so safety survives app
restart. Before adding a CloudKit field, Stage 0 must decide whether the
classification syncs. Recommended policy: sync only the enum/boolean safety
classification, never new credential material. A remote `privateOrMember`
classification always wins over `public` until the user explicitly reviews it.

## 6. Link quality and safe resolution

### 6.1 Quality levels

The resolver returns both URL and quality:

1. `verifiedEpisodePage`
2. `probableEpisodePage`
3. `podcastOrPublisherHomepage`
4. `publicEnclosure`
5. `unsafeOrSensitive`
6. `unavailable`

UI copy and enabled actions derive from quality. A homepage is never labelled
"Episode link."

### 6.2 Recommended episode resolution

1. Validate `Episode.episodeLink` as public HTTP(S).
2. Compare it with the stored channel/publisher homepage once Stage 4 adds that
   field; exact generic-homepage matches are downgraded.
3. Consider an HTTP(S) GUID only if it passes the same privacy and quality
   checks.
4. Resolve an Autohop Universal Link only for public feeds.
5. If no useful safe URL exists, return details/card-only capability.

The raw enclosure is retained in the Episode model for playback but removed
from automatic share resolution. A future explicitly labelled "Copy direct
media URL" developer feature is outside this proposal.

### 6.3 Normalization and validation

- schemes: HTTPS preferred; HTTP allowed only for legitimate public publisher
  resources;
- reject non-web schemes, file URLs, loopback, link-local, private-network and
  malformed hosts;
- reject embedded user-info;
- reject control characters and oversized components;
- preserve valid publisher URLs without destructive query stripping;
- treat all website query/display parameters as untrusted;
- never fetch a URL merely to determine whether sharing it is safe.

## 7. Universal Link contract

Universal Links are approved in principle, subject to Stage 2's gate.

### 7.1 Route

Canonical route:

`https://kevmarl.com/listen`

Versioned bounded parameters may represent:

- schema version;
- public feed identity or public feed URL for unknown-podcast preview;
- subscription-scoped episode GUID/key;
- elapsed whole seconds;
- safe public publisher fallback;
- optional bounded display hints.

Exact names and encoding are finalized in Stage 2 tests. Total URL target is
≤2,048 characters; lower per-field limits apply.

### 7.2 Public-feed requirement

Including a public feed URL is permitted only when:

- classification is `public`;
- URL passes the strict public-network validator;
- there are no credentials, sensitive query fields, or user-info;
- the generated Universal Link stays within size limits.

This permits an installed recipient to enter the existing preview/subscription
flow for an unknown public podcast. A private/unknown feed never receives this
link.

### 7.3 Installed-app behavior

The app:

1. parses the Universal Link through a dedicated strict parser;
2. emits a typed `AppRouteCommand`;
3. resolves an existing subscription by public feed identity;
4. resolves the episode by subscription-scoped stable identity;
5. if unknown and public, enters the existing browse-preview path;
6. validates a timestamp against duration before seeking;
7. never auto-subscribes, auto-downloads, or auto-plays solely because a link
   was opened without an explicit user action;
8. handles stale/missing episodes with a useful podcast/preview fallback.

The existing `autohop://` widget routes are not exposed as the public recipient
link. They may be reused internally after validated Universal Link parsing.

### 7.4 Website fallback behavior

The generic page:

- says the content was shared from Autohop;
- offers Open in Autohop / App Store;
- offers the validated publisher fallback when supplied;
- does not claim unverified title/podcast hints are authoritative;
- does not fetch the feed;
- does not expose the feed URL visibly unless the user explicitly chooses a
  public RSS action in the future;
- has useful no-script behavior.

### 7.5 Website security tests

- correct AASA content type and no redirect;
- only intended app identifiers and `/listen` components;
- oversized/malformed parameters rejected or ignored;
- private-network fallback URLs rejected;
- HTML escaping for every display hint;
- no outbound request during route rendering;
- no storage or analytics event;
- rate-limit behavior inherited safely from existing site deployment.

## 8. Architecture

### 8.1 Proposed components

| Component | Responsibility |
|---|---|
| `SharePrivacyPolicy` | Feed-level classification and allowed capability calculation |
| `ShareURLResolver` | URL validation, quality classification, publisher/Universal Link resolution |
| `SharePayloadBuilder` | Typed episode/podcast/moment/recap payloads |
| `ShareCardRenderer` | Local card format rendering |
| `SharePresentationCoordinator` | Preparation cancellation, activity presentation, completion diagnostics |
| `ShareUniversalLinkParser` | Strict public `/listen` parsing into typed commands |
| `InboundShareStore` | Small atomic App Group hand-off from extension to app |
| `InboundShareCoordinator` | Main-app validation and preview routing |

Names are recommendations, not mandatory spellings. Responsibilities and
boundaries are mandatory.

### 8.2 Ownership

- Construct app-side sharing services in `AppCompositionRoot`.
- Route navigation through `AppRoutingCoordinator`.
- Resolve live subscriptions/episodes through existing stores/coordinators.
- Do not give the Share Extension database, playback engine, GRDB, or broad app
  target membership.
- Keep card views presentation-only and synchronous at render time.
- Keep UIKit `[Any]` adaptation at the final activity-controller wrapper.

### 8.3 Typed payload outline

A payload should carry only the information required to render/present:

- subject/mode;
- title and subtitle;
- safe public URL and quality, if any;
- artwork reference or prepared image;
- publication date/duration;
- elapsed time and chapter title/start, if selected;
- accessibility description;
- privacy classification;
- capability set;
- diagnostics-safe reason codes.

It must not carry:

- feed credentials;
- raw private feed/enclosure URLs;
- local media paths;
- full Subscription/Episode graphs;
- CloudKit identifiers;
- relay credentials;
- recipient/destination information.

## 9. User experience

### 9.1 Share Centre

Replace the fixed single-purpose preview with an adaptive Share Centre:

- card preview;
- one primary Share action using the last safe mode;
- Link Only;
- Card + Link;
- Episode/Podcast Details;
- Copy Link;
- Save Card;
- Player-only Include Position and Include Chapter controls;
- clear private/no-public-link explanation;
- preparation progress and recoverable error state.

Presentation:

- content-sized/medium-large detents rather than one fixed height;
- internal scrolling at large Dynamic Type;
- iPhone portrait/landscape support;
- future iPad popover source anchoring;
- no interruption to playback;
- cancellation-safe repeated taps.

### 9.2 Activity-specific delivery

`UIActivityItemSource` may tailor representations where Apple supplies the
activity type:

- copy receives the intended URL/text rather than an arbitrary image;
- photo/save actions receive card-only;
- Messages/Mail receive context plus URL;
- unsupported destinations receive the generic selected payload.

Do not hard-code behavior for third-party bundle identifiers. Provide honest
generic fallbacks because destination behavior changes across OS/app versions.

### 9.3 Accessibility

- Every exported image gets an accessibility-oriented text alternative in the
  accompanying payload where supported.
- VoiceOver describes share mode, link availability, privacy restriction, and
  preview.
- Controls meet minimum target sizes.
- Card information is not conveyed by colour alone.
- Dynamic Type must not hide Share or Cancel.
- Localized strings replace embedded English during implementation.

## 10. Inbound Share Extension

### 10.1 Supported inputs

Initial scope:

- one HTTP(S) URL from Safari or another podcast app;
- public RSS/feed URL;
- Apple Podcasts/podcast webpage;
- public episode webpage.

Multiple URLs, text scraping, media files, and OPML import are deferred.

### 10.2 Extension behavior

1. Extract one bounded URL.
2. Validate basic scheme/length locally.
3. Write a versioned atomic hand-off record to the existing App Group.
4. Request opening Autohop through the SDK-supported extension mechanism.
5. If opening is unavailable, show a concise completion instruction.
6. Main app consumes once, deletes the record, performs network discovery, and
   routes to preview/subscribe.

No feed discovery, database access, artwork fetch, playback, or subscription
mutation occurs inside the extension.

### 10.3 Security and durability

- record expiry measured in minutes, not days;
- one pending item or a very small bounded queue;
- atomic write and consume-once semantics;
- reject file/private-network/custom schemes;
- revalidate everything in the main app;
- App Group file protection consistent with intended locked-device behavior;
- no automatic subscription.

The exact ability to open the containing app from the chosen extension type
must be verified against the installed Xcode SDK before selecting Share vs
Action Extension. This is a Stage 5 hard gate.

## 11. Card system

### 11.1 Formats

| Format | Purpose |
|---|---|
| Portrait 280×360 pt | Refined version of current share card |
| Square 1:1 | Messages and square social posts |
| Story 9:16 | Story/status destinations |
| Recap | Weekly/monthly listening and time-saved summary |

All formats render locally. No template marketplace or remote renderer.

### 11.2 Optional content

- publication date;
- duration;
- elapsed time badge;
- chapter title;
- chapter artwork when already available and safe;
- Video/Explicit indicators;
- short user-authored recommendation;
- QR code for safe public Universal Link;
- artwork-derived accent colour with contrast validation.

Never automatically quote long show notes or copy audio. User-authored text has
a strict local length limit and is not logged.

### 11.3 Recap card

Uses existing on-device Stats data, for example:

- listening time;
- time saved;
- episodes completed;
- selected period.

It must not imply server verification or comparative rankings. Values use the
same calculation paths and caveats as Stats, including estimated labels where
applicable.

## 12. tvOS QR sharing

tvOS has no conventional iOS share sheet. The Player may offer "Share with QR":

1. Resolve the same typed safe public payload.
2. Generate QR locally from the Universal Link.
3. Display title/podcast, QR, and a privacy-safe explanation.
4. Private/member or unknown feeds show details only and no QR.
5. QR remains high-contrast, sufficiently large, and tested at television
   viewing distance.

The QR does not contain a raw private feed URL or enclosure. tvOS must reuse the
same privacy/resolver contract rather than implementing a parallel policy.

## 13. Diagnostics and temporary data

### 13.1 Allowed local diagnostics

Recommended greppable events:

- `share.prepared`
- `share.presented`
- `share.completed`
- `share.cancelled`
- `share.failed`
- `share.linkUnavailable`
- `share.privateRestricted`
- `share.inboundAccepted`
- `share.inboundRejected`
- `share.routeAccepted`
- `share.routeRejected`

Metadata may include:

- subject/mode;
- safe reason/quality enum;
- artwork available boolean;
- preparation duration;
- completed/cancelled/failed;
- source surface.

Never log:

- full shared URL/query;
- feed/GUID/enclosure for private or unknown feeds;
- recipient;
- destination account;
- user-authored recommendation;
- copied text;
- inbound URL query values.

Do not add a user-visible "share count" to Stats without a separate product
decision.

### 13.2 Temporary artifacts

- dedicated bounded temporary directory;
- data protection appropriate to content;
- non-sensitive filenames;
- cleanup after activity completion plus startup age-based recovery;
- rendering/output size caps;
- card preparation cancellation when the sheet closes or subject changes.

## 14. Implementation stages

Each stage ends at its gate. Later stages depend on completed earlier stages
unless explicitly stated otherwise.

### Stage 0 — Contract, privacy model, and characterization

Work:

- Add pure sharing vocabulary and privacy/link-quality types.
- Decide classification persistence and sync schema.
- Characterize all four existing entry points and current outputs.
- Add fixtures for public, unknown, private/member, generic homepage, missing
  link, malformed GUID, and token-free members CDN cases using synthetic URLs.
- Document resolver capability expectations.

Tests:

- privacy capability matrix;
- encoding/decoding compatibility;
- private classification dominance;
- no fixture contains a real private value.

Gate:

- Review matrix proves private/member feeds cannot produce link/QR capability.
- Kevin approves user-facing private-feed wording and sync choice.

### Stage 1 — Safe resolver and live-defect repair

Work:

- Implement `SharePrivacyPolicy`, `ShareURLResolver`, typed payload builder.
- Remove raw enclosure automatic fallback.
- Add link quality classification and generic-homepage downgrade.
- Correct Podcast Detail and Podcast Settings share semantics so they no
  longer silently share `newestEpisode`.
- Preserve current episode sharing from Player and Episode Detail.
- Retain a safe card/details fallback.

Tests:

- resolver priority and downgrade table;
- credential/user-info/private-network rejection;
- private feed with token-free enclosure still produces no link;
- podcast toolbar payload is podcast, not episode;
- malformed/missing inputs never crash.

Gate:

- Existing episode sharing still works for safe public episodes.
- Private/member tests prove fail-closed behavior.
- Kevin verifies podcast toolbar wording and subject.

### Stage 2 — Constrained Universal Links and website fallback

Work:

- Add Associated Domains through project.yml/entitlements.
- Deploy correct AASA file.
- Implement versioned `/listen` builder and strict app parser.
- Add typed routing for existing/unknown public podcast and episode/timestamp.
- Add generic stateless kevmarl.com fallback page.
- Update website Privacy Policy before production deployment.

Tests:

- parser round-trip/fuzz/oversize/reserved characters;
- public versus private capability;
- timestamp clamping;
- AASA headers/path/app identifiers;
- HTML escaping;
- no Worker outbound fetch;
- no persistence/analytics;
- installed/uninstalled physical-device behavior.

Gate:

- Public link opens the intended installed-app route.
- Unknown public feed enters preview without subscribing automatically.
- Uninstalled path renders generic page.
- Private/unknown feed cannot generate `/listen`.
- Production website behavior and privacy copy verified live.

### Stage 3 — Adaptive Share Centre and episode modes

Work:

- Replace fixed preview with adaptive Share Centre.
- Add Link Only, Card + Link, Details, Copy Link, and Card Only/Save Card.
- Add Player position/chapter inclusion.
- Add preparation cancellation, text-only recovery, local last-safe-mode.
- Keep system activity controller as destination picker.

Tests:

- each mode's exact typed payload;
- current chapter and elapsed boundary cases;
- card-render failure falls back safely;
- repeated presentation/cancellation;
- Dynamic Type and small-screen layout;
- VoiceOver labels.

Gate:

- Kevin validates all modes on Messages, Mail, Notes, Copy, AirDrop, Save Image,
  and at least one installed third-party destination.
- Playback continues uninterrupted throughout preparation/presentation.

### Stage 4 — Genuine podcast sharing and RSS channel link

Work:

- Parse/store RSS channel publisher webpage separately from episode links.
- Add podcast payload/card/details modes.
- Use channel webpage quality in episode generic-homepage detection.
- Add safe privacy classification control to Podcast Settings if Stage 0
  requires user review/override.

Tests:

- RSS channel link parsing;
- episode and channel link separation;
- podcast card uses podcast metadata;
- private podcast remains card/details-only;
- persistence/sync compatibility for new fields.

Gate:

- Podcast Detail and Podcast Settings share the podcast.
- Episode Detail and Player share the selected episode.
- Generic homepage is labelled accurately.

### Stage 5 — Inbound iOS Share Extension

Work:

- Verify appropriate extension APIs with installed SDK.
- Add minimal extension target through project.yml.
- Add bounded App Group hand-off contract/store.
- Consume/revalidate in main app and enter existing preview flow.
- Add explicit empty/error/completion states.

Tests:

- Safari public webpage/RSS input;
- Apple Podcasts link input;
- malformed/file/private-network rejection;
- expiry, overwrite/queue limit, consume once;
- locked/restarted app behavior;
- extension memory and execution duration.

Gate:

- "Open/Subscribe in Autohop" path works from supported apps without the
  extension doing discovery or mutation.
- App Review/private API check passes.

### Stage 6 — Card Studio and recap cards

Work:

- Add square and story formats alongside portrait.
- Add bounded card options, QR for public subjects, contrast-safe accent
  extraction, chapter artwork.
- Add weekly/monthly Stats recap card using existing Stats calculations.

Tests:

- pixel sizes and file-size limits;
- long titles/locales/Dynamic Type-independent export;
- square crop/video artwork;
- QR scan success across sizes;
- dark/light artwork contrast;
- Stats value parity and estimated labels.

Gate:

- Kevin approves rendered fixture gallery.
- No format requires network/server rendering.

### Stage 7 — Context-menu discoverability

Work:

- Add context-menu share access to appropriate Podcast Detail episode, Up Next,
  Listening History, Downloads, and Discover episode rows.
- Reuse one subject resolver and Share Centre.
- Do not add another swipe action.
- Add Copy Link only when capability allows.

Tests:

- selected row identity remains correct after queue/store mutation;
- archived/history episode resolution;
- private capability respected on every surface;
- accessibility actions and labels.

Gate:

- All entry points produce identical payload decisions for the same episode.
- Existing swipe gestures remain unchanged.

### Stage 8 — tvOS QR sharing

Work:

- Add Player QR presentation using shared resolver policy.
- Add public Universal Link QR and details fallback.
- Test focus, dismissal, contrast, and viewing distance.

Tests:

- public/private/unknown matrices;
- QR scan from representative television distance;
- oversized link rejection;
- tvOS route does not expose credentials.

Gate:

- Physical Apple TV validation.
- Private/member content never renders a QR.

### Stage 9 — Durability, documentation, and release audit

Work:

- Add activity completion diagnostics and temp cleanup.
- Perform destination compatibility and accessibility audit.
- Review privacy/security threat model.
- Update AI CONTEXT headers and all affected project docs.
- Update in-app Support and mirrored website Support/Privacy/Features claims.
- Update VERSION_1.4.md or the actual shipping-version document.
- Record implementation evidence in this ledger.

Tests:

- full automated suite;
- release configuration;
- install/upgrade persistence;
- offline and artwork-failure behavior;
- private-feed regression suite;
- website live verification;
- diagnostic log contains safe reason codes and no sensitive URLs.

Gate:

- No known private URL leakage path.
- No new paid/standing service.
- Documentation describes only shipped behavior.
- Kevin completes physical-device release checklist.

## 15. Required test matrix

Every relevant stage maintains this matrix:

| Feed/link case | Card/details | Publisher link | Universal Link | QR | Raw enclosure |
|---|---:|---:|---:|---:|---:|
| Public + verified episode page | Yes | Yes | Yes | Yes | Never automatic |
| Public + generic homepage | Yes | Labelled homepage only | Yes if bounded identity valid | Yes if Universal Link valid | Never automatic |
| Public + no page | Yes | No | Yes if bounded identity valid | Yes if Universal Link valid | Never automatic |
| Unknown manual RSS | Yes | Verified public page only | No | No | No |
| Private/member feed | Yes | No | No | No | No |
| Malformed/suspicious URL | Yes | No | No | No | No |
| Missing artwork | Placeholder card/details | Per policy | Per policy | Per policy | No |

Additional device/destination matrix:

- current and smallest supported iPhone;
- large Dynamic Type;
- VoiceOver;
- portrait and landscape;
- locked/unlocked hand-off where applicable;
- Messages, Mail, Notes, Copy, AirDrop, Save Image, Files;
- at least one third-party messaging/social destination;
- tvOS QR physical scan;
- app installed versus not installed Universal Link.

## 16. Documentation obligations

Update when behavior actually ships:

- `DESIGN.md`: Share Centre, card formats, QR, context-menu pattern.
- `FEATURES.md`: sharing modes, podcast sharing, privacy behavior, inbound
  extension, recap cards.
- `PAGES.md`: every entry point and presentation route.
- `SYNC_DESIGN.md`: privacy classification sync decision.
- `project_autohop.md`: targets/services and website contract.
- `README.md`: concise shipped feature statement.
- `VERSION_1.4.md` or current release document.
- `Views/SupportContent.swift` and website Support mirror.
- website Features and Privacy Policy.
- onboarding only if sharing becomes an explicitly taught workflow.
- this document's execution ledger after every stage.

Claims must distinguish:

- device-side shipped behavior;
- website Universal Link behavior actually deployed live;
- deferred card/extension/tvOS stages;
- private-feed restrictions.

## 17. Corrections and convergence ledger

| Earlier claim/design | Correction |
|---|---|
| Podcast Detail episode rows already share | False. No row share exists; toolbar shares newest episode |
| Podcast toolbar share is podcast-level | False. It currently selects `newestEpisode` |
| Sensitive-query scanning protects private feeds | Insufficient. Token-free members CDN URLs can still leak paid media |
| Raw enclosure is an acceptable silent fallback | Rejected. It is never automatic |
| Any HTTP(S) `<item><link>` is an episode page | False. Generic publisher homepages occur and need lower quality |
| Put every feed URL in a Universal Link | Rejected. Public classified feeds only |
| Worker should fetch the supplied feed for landing metadata | Rejected due to SSRF/amplification/privacy/cost risk |
| Share Extension should resolve feeds itself | Rejected. Validate/stash/open; main app resolves |
| Universal Links must be excluded to remain cost-neutral | Resolved: approved using the existing stateless site under the hard no-storage/no-fetch/no-analytics contract |
| User-visible share count belongs in Stats | Deferred pending separate product value |

Final convergence:

- Device-side Stages 0–9 accepted.
- Universal Links accepted with constrained public-only design.
- Feed-level privacy classification is authoritative.
- Inbound Share Extension, recap cards, and tvOS QR remain in scope.
- There are no open technical disagreements in this proposal.

## 18. Execution ledger

| Stage | Status | Date | Notes |
|---|---|---|---|
| 0 | Not started | — | — |
| 1 | Not started | — | — |
| 2 | Not started | — | — |
| 3 | Not started | — | — |
| 4 | Not started | — | — |
| 5 | Not started | — | — |
| 6 | Not started | — | — |
| 7 | Not started | — | — |
| 8 | Not started | — | — |
| 9 | Not started | — | — |

## 19. Definition of done

The sharing program is complete only when:

- podcast toolbar actions share podcasts;
- episode actions share the intended episode;
- private/member feeds cannot emit links, QR codes, enclosures, or sensitive
  diagnostic metadata;
- raw enclosures are not automatic fallbacks;
- safe public recipients can open installed Autohop at the intended subject and
  bounded timestamp;
- recipients without Autohop receive a useful generic, stateless fallback;
- Share Centre modes work with graceful card/link failures;
- inbound sharing hands public links safely to main-app preview;
- portrait/square/story/recap cards render entirely on-device;
- tvOS QR uses the same privacy contract;
- all entry points share one resolver and capability policy;
- temporary files are bounded and cleaned;
- accessibility and destination/device matrices pass;
- website and app documentation describe only live behavior;
- no new paid API, storage service, tracking system, or hosted media exists.
