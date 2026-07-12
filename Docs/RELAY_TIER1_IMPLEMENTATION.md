# Autohop Relay — Tier 1 Implementation Specification

<!-- AI CONTEXT — Canonical cross-repository contract for the Autohop app and
Cloudflare relay. Protocol v2 (2026-07-12) uses batched/diffed membership,
opaque feed IDs, durable per-device change coalescing, targeted app refresh,
and persisted client/server pressure guards. Implementation claims below must
be kept synchronized with Relay/*.swift and ../autohop-relay/src + migrations. -->

Status: BUILT — core loop + hardening complete, unverified against real Apple traffic.
Worker live on Kevin's Cloudflare account: D1 schema migrated, all 4 queues + cron
attached, all 7 secrets set, `/health` verified. App-side (§4): StoreKit product,
purchase flow, Settings UI entry point, register/feeds/heartbeat/sync-nudge all wired
end-to-end (2026-07-09/10). Server-side hardening landed 2026-07-10: real JWS x5c
chain verification (pinned Apple Root CA G3 — see appleRoot.ts), SSRF per-hop redirect
re-validation, rate limiting on /v1/register, daily reconciliation cron, orphan/expired
sweep, App Store Server API client. Protocol-v2 performance hardening landed 2026-07-12
but has not been deployed in this workspace pass; deploy the compatible app first, then
migration 0002, then Worker code. REMAINING: real x5c verification is implemented but
UNTESTED against an actual Apple-signed transaction — no live purchase available this
pass (local StoreKit Testing will now correctly FAIL it, since it signs with a test
root, not Apple's real one — that's expected, not a regression). Also still open: Apple
ASN not yet configured in App Store Connect to point at /v1/asn; DNS-rebinding SSRF
protection (redirect-hop IPs are checked, but a hostname resolving to a private IP at
connect time isn't); privacy-policy text update. Audience: implementing engineer or AI
coding agent. Document style: canonical, deterministic, contract-first. Prose minimized.

Naming/pricing (DECIDED): service = `Autohop Relay`; paid product = **`Autohop Pro`** —
auto-renewable monthly, **AUD $2.99/mo**, 7-day free trial. bundle id = `com.kevinperry.autohop`;
relay origin = `https://autohop-relay.kevin-453.workers.dev` (live Workers.dev URL;
a custom domain like `relay.kevmarl.com` is a later polish step, not yet mapped).
**Tiers 2 & 3 are DROPPED. Tier 1 (operator-hosted) is the only relay model.**

---

## 0. SCOPE

Tier 1 = **operator-hosted** central service that gives paying users reliable, locked/overnight
new-episode delivery on iOS/tvOS, funded by a monthly auto-renewable subscription.

IN SCOPE:
- Operator-run RSS crawler (Cloudflare) that watches subscribers' public feed URLs.
- Operator-run APNs push relay that wakes subscriber devices via silent (`content-available`) push.
- StoreKit 2 subscription gating + server-side entitlement validation.
- Optional secondary message type: `sync-nudge` (reduces iPhone↔tvOS CloudKit lag) reusing the same relay.

OUT OF SCOPE:
- Tiers 2 & 3 (user-hosted crawler / fully self-hosted app) — DROPPED, not being built.
- On-device refresh logic (already exists; Tier 1 only ADDS wake events, never replaces the local path).

INVARIANT-0 (graceful degradation): if the relay is unreachable, expired, or unsubscribed, the app
MUST behave exactly as Tier 0 (today's on-device refresh). Tier 1 is strictly additive.

---

## 1. GLOSSARY

| Term | Definition |
|---|---|
| `subscriber` | One paying account, keyed by Apple `originalTransactionId` (stable across renewals + the user's devices signed into the same Apple ID). |
| `device` | One app install. Keyed by `device_id` (relay-issued UUID). Owns one APNs token. |
| `sync_group_id` | Anonymous per-user id = `CKContainer.fetchUserRecordID` (identical across a user's devices; not PII). Used to fan `sync-nudge` between a user's own devices. |
| `feed` | A distinct public RSS/Atom URL. Crawled ONCE regardless of how many devices subscribe. |
| `wake push` | APNs `content-available:1` background push with no alert/sound/badge. Wakes the app in the background. |
| `entitlement` | Server-validated proof that a subscriber's `Autohop Pro` subscription is active (has `expires_at > now`, not revoked). |

---

## 2. ARCHITECTURE

```
                       ┌───────────────────────── Cloudflare ─────────────────────────┐
  iOS/tvOS app         │                                                              │
  ├─ StoreKit 2        │   Worker: API           Worker: Crawler        Worker: Push  │
  │  (buy sub)         │   /v1/register   ─────►  (Cron every N min)     (Queue        │
  ├─ register token ───┼─► /v1/feeds      ─┐      walk feeds, cond-GET   consumer)     │
  ├─ receive wake push │   /v1/heartbeat   │      detect new GUID ──► enqueue fan-out  │
  │  → refresh + DL ◄──┼── APNs ◄──────────┼──────────────────────────► APNs send     │
  └─ (Tier 0 fallback) │                   ▼                                           │
                       │                 D1 (subscribers, devices, feeds, feed_devices)│
  Apple App Store  ───►│   /v1/asn (App Store Server Notifications V2 webhook)         │
                       └──────────────────────────────────────────────────────────────┘
```

Workers (logical; may be one Worker with multiple routes + a Cron handler + a Queue consumer):
- **API Worker** — device registration, feed-list sync, heartbeat, ASN webhook. HTTP request/response.
- **Crawler** — Cron-triggered; selects due feeds; conditional GET; diff; enqueues fan-out.
- **Push consumer** — Cloudflare Queue consumer; batches APNs sends; handles APNs responses.

State: **D1** (SQLite). Fan-out + crawl sharding: **Cloudflare Queues**. Schedule: **Cron Triggers**.
Secrets (Worker Secrets): `APNS_KEY_P8`, `APNS_KEY_ID`, `APNS_TEAM_ID`, `APPSTORE_KEY_P8`,
`APPSTORE_KEY_ID`, `APPSTORE_ISSUER_ID`, `ASN_SHARED` (optional), `HMAC_DEVICE_SECRET_PEPPER`.

---

## 3. DATA MODEL (D1 DDL)

```sql
CREATE TABLE subscribers (
  original_transaction_id TEXT PRIMARY KEY,   -- Apple, stable per subscriber
  product_id              TEXT NOT NULL,
  status                  TEXT NOT NULL,       -- enum: active|grace|expired|revoked
  expires_at              INTEGER NOT NULL,    -- unix seconds
  environment             TEXT NOT NULL,       -- Production|Sandbox
  created_at              INTEGER NOT NULL,
  updated_at              INTEGER NOT NULL
);

CREATE TABLE devices (
  device_id           TEXT PRIMARY KEY,        -- relay-issued UUIDv4
  original_transaction_id TEXT NOT NULL REFERENCES subscribers(original_transaction_id),
  apns_token          TEXT NOT NULL,           -- hex; unique per (app, device)
  sync_group_id       TEXT,                    -- anonymous CloudKit user record id (nullable)
  device_secret_hash  TEXT NOT NULL,           -- HMAC-SHA256(secret, pepper); bearer auth
  platform            TEXT NOT NULL,           -- ios|tvos
  bundle_env          TEXT NOT NULL,           -- production|sandbox (APNs endpoint select)
  last_seen_at        INTEGER NOT NULL,
  created_at          INTEGER NOT NULL,
  UNIQUE(apns_token, bundle_env)
);
CREATE INDEX idx_devices_sub   ON devices(original_transaction_id);
CREATE INDEX idx_devices_group ON devices(sync_group_id);

CREATE TABLE feeds (
  feed_url        TEXT PRIMARY KEY,            -- normalized (see 5.2)
  etag            TEXT,
  last_modified   TEXT,
  last_guid       TEXT,                        -- newest item guid seen
  last_pub_at     INTEGER,                     -- newest item pubDate (fallback ordering)
  last_checked_at INTEGER,
  last_changed_at INTEGER,
  error_count     INTEGER NOT NULL DEFAULT 0,
  next_check_at   INTEGER NOT NULL DEFAULT 0,  -- adaptive backoff
  subscriber_count INTEGER NOT NULL DEFAULT 0  -- denormalized fan-out size
);
CREATE INDEX idx_feeds_due ON feeds(next_check_at);

CREATE TABLE feed_devices (                    -- inverted index feed → device
  feed_url  TEXT NOT NULL REFERENCES feeds(feed_url),
  device_id TEXT NOT NULL REFERENCES devices(device_id),
  PRIMARY KEY (feed_url, device_id)
);
CREATE INDEX idx_fd_device ON feed_devices(device_id);
```

Derived rule: `feeds.subscriber_count = COUNT(feed_devices WHERE feed_url)`. When it reaches 0,
delete the `feeds` row (stop crawling orphan feeds).

---

## 4. CLIENT (APP) INTEGRATION

**IMPLEMENTED 2026-07-09** — `Store/AutohopProStore.swift` (§4.1), `Relay/RelayClient.swift`
+ `Relay/RelayCredentialsStore.swift` + `Relay/RelayModels.swift` (§4.2–4.5 transport),
`App/AppDelegate.swift` (APNs registration/token capture/push dispatch), `App/AppState.swift`
(register/unregister/feed-sync/wake-push glue — see its "Autohop Relay" MARK section).
Local testing: `Autohop.storekit` + `project.yml`'s `storeKitConfiguration` key. NOT wired: no
Settings UI calls `AutohopProStore.purchase()` yet (nothing to click); §4.5 heartbeat isn't
scheduled anywhere (RelayClient.heartbeat() exists but nothing calls it on foreground yet).

### 4.1 Entitlement (StoreKit 2)
- Product: one auto-renewable subscription `Autohop Pro` (monthly, AUD $2.99, 7-day free trial). See §8.
- Gate: relay features active IFF `Transaction.currentEntitlements` contains a non-revoked
  `Autohop Pro` transaction. Observe `Transaction.updates` to react to renew/lapse in real time.
- On entitlement gained/lost, call `POST /v1/register` / `POST /v1/unregister`.
- IMPL: `AutohopProStore.isPro` (published) is that gate; `AppState` observes `$isPro` and
  calls `registerWithRelayIfPossible()` / `relayClient.unregister()` accordingly.
- **Signature-result invariant (fixed 2026-07-12):** the Worker verifier returns a
  discriminated `{ok:true}` / `{ok:false,reason}` object. Registration explicitly
  tests `verification.ok`; it must never negate the result object itself because a
  JavaScript object is truthy even when it represents failure. The former boolean-era
  call pattern was found during the final cross-repository audit and corrected.

### 4.2 Registration payload
On first entitlement or token change, app sends the **signed StoreKit 2 transaction JWS** as proof.
Relay validates it (§6.1). Relay returns a `device_id` + `device_secret` (store in Keychain).
Subsequent calls authenticate with `Authorization: Bearer <device_id>.<device_secret>`.
- IMPL: `RelayCredentialsStore` (kSecClassGenericPassword, `kSecAttrAccessibleAfterFirstUnlock`
  so a background wake after first-unlock-since-boot can still read it).

### 4.3 Feed-list sync
App sends its current subscribed feed URL set (or add/remove deltas) via `POST /v1/feeds`.
Send full set on register; deltas on subscription changes. Idempotent.
- IMPLEMENTED 2026-07-12: `AppState` compares the canonical real-subscription feed set after a
  broad `SubscriptionStore` notification and does nothing for episode/metadata-only saves. A fresh
  registration or missing baseline sends one full `set`; ordinary subscribe/unsubscribe changes
  send only `add`/`remove`. The last server-acknowledged set and opaque ID mapping are persisted.
- Cancellation safety: the 2 s debounce Task clears its stored reference before URLSession begins,
  so a later store change can cancel only a pending sleep, never an in-flight request. A 15 s request
  timeout plus persisted exponential retry/circuit state (30 s → 15 min cap, honoring server
  `retryAfter`) prevents transport failures or relaunches from recreating the former request storm.
- Worker: validates a bounded body/library, computes a set difference, writes additions/removals via
  `env.DB.batch()`, recomputes all touched counts with set-based SQL, and deletes orphan feeds in the
  same request. The response includes `{count,changed,revision,feeds:[{id,url}]}`; IDs are opaque.

### 4.4 Wake-push handling
On protocol-v2 silent push (`type=feed-updated`, `feed_ids:[...]`): resolve the opaque IDs through
the last acknowledged membership response and refresh only those subscriptions. The relay never
puts RSS URLs in APNs. A legacy v1 push without IDs runs a bounded, due-only eight-feed fallback
that honors feed backoff; it never performs the former unbounded full-library sweep. On
`type=sync-nudge`: trigger an immediate CloudKit fetch.
`AppDelegate` enforces a **20-second one-shot completion deadline** with
`RelayPushCompletionGate`. Actual work completion and the deadline race on the
main actor; whichever arrives first calls the background completion handler
exactly once. The deadline returns `.noData` and deliberately does not cancel
AppState's shared refresh cycle, because foreground, audio, or a BGTask may also
own it. A refresh that finishes after the deadline emits `relay.pushLateResult`.
Media downloads are separate durable intents and never hold this path open. No UI.
- IMPL: `AppState.handleRelayPush(type:feedIDs:)`, dispatched from `AppDelegate.didReceiveRemoteNotification`.
  sync-nudge reuses `CloudSyncEngine.fetchAllSubscriptionsNow`/`fetchAllHistoryNow` — the same
  primitives TV's own launch/foreground prime uses (`AutohopTVApp.primeLibraryFromCloudSoon`) —
  without TV's 15 s activation-retry loop (no time budget for that in a background push).
  RESOLVED 2026-07-09 (no new code needed): the note here previously flagged CloudSyncEngine as
  having no push wiring of its own. Research (WWDC23 "Sync to iCloud with CKSyncEngine" +
  apple/sample-cloudkit-sync-engine, which has zero `didReceiveRemoteNotification` code) showed
  CKSyncEngine listens for its own CloudKit pushes independent of the app delegate — the ACTUAL
  gap was that nothing in this app ever called `registerForRemoteNotifications()`, so CKSyncEngine
  had no APNs token to receive its subscription pushes on. That call was added today for the relay
  (AppDelegate item 9) and fixes CloudKit's native push delivery as a side effect. Needs real-device
  verification (Simulator can't receive CloudKit push), not more code.

### 4.5 Heartbeat
`POST /v1/heartbeat` on foreground (≤1/day). Updates `last_seen_at`; lets relay prune dead devices.
- IMPLEMENTED 2026-07-10: `AppDelegate.applicationDidBecomeActive` → `AppState.
  sendRelayHeartbeatIfDue()`. The ≤1/day budget is persisted via UserDefaults
  (`com.autohop.relay.lastHeartbeatAt`), NOT an in-memory timestamp — a relaunch
  must not reset it, or a frequently-force-quit-and-reopened app would heartbeat
  every launch instead of daily. A failed heartbeat does NOT update the
  timestamp, so it retries next foreground rather than waiting a full day after
  a transient error. If the response entitlement isn't active/grace, triggers
  `AutohopProStore.refreshEntitlement()` so local StoreKit state catches up to
  a server-side change the app never otherwise saw (e.g. a missed ASN webhook —
  belt-and-suspenders alongside §8's reconciliation cron).

---

## 5. CRAWLER

### 5.1 Schedule
Cron trigger every `CRAWL_TICK` minutes (default 5). Each tick:
```
now = unixNow()
due = SELECT feed_url FROM feeds WHERE next_check_at <= now ORDER BY next_check_at LIMIT BATCH
for each shard of `due` (size ≤ QUEUE_BATCH): enqueue to CRAWL_QUEUE   // avoid per-invocation limits
```
Sharding via Queue keeps each Worker invocation within CPU + subrequest limits.

### 5.2 Feed URL normalization (dedup key)
lowercase scheme+host; strip fragment; strip tracking query params; NO trailing-slash collapse if it
changes semantics. Store canonical form as PK. Reject non-`https?` schemes.

### 5.3 Per-feed crawl (Queue consumer, per feed_url)
```
req = GET feed_url with headers { If-None-Match: etag?, If-Modified-Since: last_modified? }
      timeout 10s; max body 8 MB; follow ≤3 redirects (same SSRF checks each hop, §7.4)
switch status:
  304: touch(last_checked_at=now); schedule_next(feed, changed=false); return
  200: items = parseFeedNewestFirst(body)          // RSS <item>/Atom <entry>
       newestGuid = items[0].guid ?? items[0].enclosureURL ?? hash(items[0].title+pubDate)
       if newestGuid != last_guid:
           update feeds SET last_guid=newestGuid, last_pub_at=items[0].pubDate,
                            etag=resp.etag, last_modified=resp.lastModified,
                            last_changed_at=now, error_count=0
           enqueue FANOUT_QUEUE { feed_url }      // §6.2
       else:
           update feeds SET etag/last_modified/last_checked_at; error_count=0
       schedule_next(feed, changed=(newestGuid!=last_guid)); return
  4xx/5xx/timeout:
       error_count += 1; schedule_next_backoff(feed); return    // exp backoff, cap 6h
```

### 5.4 Adaptive interval (`schedule_next`)
Base interval per feed; tighten for feeds that change often, loosen for quiet feeds.
```
if changed:            next = now + max(MIN_INTERVAL, floor(median_gap * 0.5))
elif error_count>0:    next = now + min(6h, MIN_INTERVAL * 2^error_count)
else:                  next = now + clamp(observed_gap_estimate, MIN_INTERVAL, MAX_INTERVAL)
MIN_INTERVAL=5m  MAX_INTERVAL=6h
```
This is the SERVER-side analog of Release Radar, but it only governs CRAWL frequency (cheap 304s),
NEVER whether a device is told — every subscriber of a changed feed is always notified.

---

## 6. VALIDATION & PUSH

### 6.1 StoreKit JWS validation (registration + ASN)
- Verify JWS signature chain to Apple root CA (`AppleRootCA-G3`). Reject on chain/exp failure.
- Extract: `originalTransactionId`, `productId`, `expiresDate`, `revocationDate`, `environment`.
- Upsert `subscribers`. Set `status`: `active` if `expiresDate>now && !revocation`, else `expired`/`revoked`.
- Reuse Apple's **App Store Server API** (`GET /inApps/v1/subscriptions/{originalTransactionId}`) as the
  source of truth when JWS is stale.
- IMPLEMENTED 2026-07-10 — was the standing "REQUIRED before production" TODO:
  `appstore.ts verifyJwsSignature()` now does real 4-stage verification (chain
  of trust to a PINNED Apple Root CA G3 — `appleRoot.ts`, fetched + fingerprint-
  verified against Apple's own published value, NEVER trusts the root a JWS
  itself supplies; certificate validity windows; Extended Key Usage OIDs on
  leaf + intermediate; the JWS's own ES256 signature against the leaf cert).
  Uses `node:crypto`'s `X509Certificate` (Cloudflare added real Workers support
  for this specific class for this specific Apple use case) bridged to
  WebCrypto for the signature step. Matches Apple's own `app-store-server-
  library`'s approach in full, including the EKU checks (see next item).
- **CORRECTED same day, from live traffic, not a retest**: this doc previously
  claimed here that local StoreKit Testing would "correctly FAIL" the chain
  check, and that skipping EKU checks was fine since chain-of-trust was
  "load-bearing" and EKU merely "defense-in-depth." Both wrong — a real
  registration from Kevin's local `.storekit` build SUCCEEDED against the
  deployed verification. `Transaction.Environment` has a documented `.xcode`
  case, and Apple's local StoreKit Testing genuinely signs those transactions
  with a chain that verifies against the real pinned Apple Root CA G3 (via a
  testing-scoped intermediate/leaf) — the crypto was correct, nothing checked
  WHICH environment or WHICH purpose the certs were for. Two fixes landed same
  day: (1) `verifyAndUpsertSubscriber` rejects any `environment` that isn't
  `Production`/`Sandbox` (cheap, immediate); (2) the EKU check itself is now
  actually implemented (`x509ExtendedKeyUsage.ts` — a purpose-built DER/ASN.1
  reader, NOT a general X.509 library), the more correct certificate-level fix
  matching what Apple's own library checks. The parser was independently
  validated before being wired in: cross-checked against `openssl x509 -text`
  on the real pinned root cert (exact match on all 3 real extensions present,
  correctly reports none of them is ExtendedKeyUsage), plus a hand-constructed
  round-trip of both Apple OIDs. Verified live: the stale `environment:
  "Xcode"` subscriber row this whole sequence created, plus the 93 feeds and
  zero-device fanout waste it caused, were found via a live Cloudflare Logs
  review and cleaned up directly in D1. STILL UNTESTED: a real Sandbox or
  Production purchase (Production isn't possible pre-launch; Sandbox is the
  next thing to try) — Xcode-environment rejection is confirmed working on
  real traffic; the EKU parser is confirmed correct against real Apple DER
  data (the root cert) but has never seen a real StoreKit leaf/intermediate
  certificate, and Production/Sandbox acceptance itself remains unverified.
- §6.1's "when JWS is stale" fallback is NOT called from `/v1/register` (would
  need cheaply detecting staleness, which the JWS's own contents don't make
  easy) — `appStoreServerAPI.ts`'s live-lookup client exists and IS used, just
  by §8's daily reconciliation cron instead, which achieves the same
  self-correcting-entitlement goal on a bounded daily cadence. Documented
  deviation, not silent.

### 6.2 Fan-out (FANOUT_QUEUE consumer)
```
devices = SELECT d.device_id, f.feed_id FROM feed_devices fd JOIN feeds f USING(feed_url)
          JOIN devices d USING(device_id)
          JOIN subscribers s USING(original_transaction_id)
          WHERE fd.feed_url = :feed_url AND s.status IN ('active','grace')
for each device: UPSERT pending_feed_changes(device_id, feed_id)
for each device without an outstanding flush: enqueue PUSH_QUEUE { device_id }
```

### 6.3 Push coalescing (MANDATORY — iOS throttles background pushes ~2–3/hr/device)
Do NOT send one push per changed feed. Per device, collapse to ≤1 wake push per `COALESCE_WINDOW`
(default 15 min). D1's `pending_feed_changes` durably retains every coalesced opaque identity;
`feed_push_state` guarantees at most one immediate/delayed queue flush per device. A push carries
at most eight IDs. IDs are deleted only after APNs accepts that payload, and a change written while
APNs is in flight survives the conditional delete for the next flush.

### 6.4 APNs send (PUSH_QUEUE consumer)
```
jwt = cachedApnsJwt()                        // ES256 over {iss:TEAM,iat}, kid=APNS_KEY_ID, reuse ≤50m
endpoint = bundle_env=='sandbox' ? api.sandbox.push.apple.com : api.push.apple.com
POST https://{endpoint}/3/device/{apns_token}
  headers: authorization: bearer {jwt}
           apns-topic: {bundle_id}
           apns-push-type: background
           apns-priority: 5                    // REQUIRED for content-available-only
           apns-expiration: {now + 3600}
  body: {"aps":{"content-available":1},"type":"feed-updated","v":2,
         "feed_ids":["opaque-id", ...]}
handle response:
  200: ok
  410: delete device (token unregistered)
  429: respect, requeue with delay
  400 BadDeviceToken/DeviceTokenNotForTopic: delete device
  else: log; bounded retry
```
`sync-nudge` uses the same send with `body.type="sync-nudge"` and targets `sync_group_id` peers
(SELECT devices WHERE sync_group_id = :gid AND device_id != :origin).
- SEND-SIDE FIXED 2026-07-10: previously only the RECEIVE side existed (a TV device could be
  nudged, but nothing ever asked to nudge it) — `sync_group_id` was also never populated at
  registration, so even the receive side would have no-op'd. Both fixed: `AppState.
  resolveRelaySyncGroupID()` fetches+caches `CKContainer.fetchUserRecordID()` and passes it to
  `/v1/register`; `CloudSyncEngine.onLocalChangesPushed` (fires on every successful CK push) drives
  `AppState.scheduleRelaySyncNudge()` — a 5 s quiet period, persisted five-minute client minimum,
  and exponential retry circuit — into `RelayClient.syncNudge()`. The Worker enforces a one-minute
  source-device request minimum and coalesces several sources targeting the same device. End-to-end:
  iPhone change → CK push succeeds → debounced
  POST /v1/sync-nudge → Worker fans to sync_group_id peers → TV's already-built receive path fetches.

---

## 7. SECURITY & PRIVACY

### 7.1 Data stored (EXHAUSTIVE)
`originalTransactionId` (Apple billing id), `apns_token` (opaque), `sync_group_id` (anonymous),
`device_secret_hash`, `platform`, and the list of `feed_url`s a device subscribes to (all PUBLIC).
**NOT stored**: listening history, playback positions, stats, names, emails, IP beyond transient logs.

### 7.2 Privacy-policy delta (REQUIRED before ship)
Disclose: "With Autohop Pro enabled, your subscription feed URLs (public) and an anonymous push
token are sent to the Autohop Relay solely to notify your devices of new episodes. Your listening
history, positions, and stats remain on-device and in your own iCloud, and are never sent to Autohop."
Keep the Stats-page copy accurate (listening data still local).

### 7.3 AuthN/AuthZ
- Registration: authenticated by valid StoreKit JWS (only real subscribers can create records).
- All other endpoints: `Bearer {device_id}.{device_secret}`; compare `HMAC(secret,pepper)`.
- Rate-limit `/v1/register` by IP + token (Cloudflare rules).
- IMPLEMENTED 2026-07-10: Workers-native Rate Limiting binding (GA Sept 2025,
  not a Dashboard WAF rule — `wrangler.jsonc` `ratelimits`), 5 attempts/60s keyed
  by `cf-connecting-ip` (by IP only, not "IP + token" — there's no token to key
  by at this endpoint; it's what ISSUES the token). Verified live: 7th rapid
  attempt from the same IP correctly returned `429 rate_limited`. Note:
  observed a real propagation delay on a brand-new rate-limit namespace right
  after first deploy (~30s before it started enforcing) — expected only once,
  for this specific namespace's first activation, not an ongoing concern.

### 7.4 Crawler SSRF hardening
Resolve target; REJECT if IP ∈ private/loopback/link-local/reserved ranges; `https?` only; deny
non-feed content-types over a size cap; 10s timeout; ≤3 redirects re-validated each hop.
- FIXED 2026-07-10: the redirect re-validation wasn't implemented — `crawler.ts` used
  `redirect: "follow"`, which lets Cloudflare's fetch chase redirects internally with NO
  per-hop check, so a feed 302'ing to a private/loopback address sailed past the origin-URL-only
  check. Replaced with `fetchFeedFollowingRedirects()`: `redirect: "manual"` + a loop that calls
  `isSafeFeedHost()` on every hop's resolved Location before following it, capped at
  `MAX_REDIRECTS=3`, throwing (→ normal crawl-error path, backs off) on an unsafe hop, a missing
  Location header, or exceeding the cap.
- STILL NOT DONE: true DNS-rebinding protection (a hostname that only RESOLVES to a private IP at
  connect time — as opposed to a private IP/hostname literally in the URL — isn't caught, since
  Workers' `fetch()` doesn't expose the resolved IP before connecting). Needs a custom resolver or
  Cloudflare's IP-restriction features; still an open item, now clearly scoped rather than vague.

### 7.5 Secrets
APNs `.p8`, App Store `.p8` in Worker Secrets only; never shipped in the app. Rotatable.

---

## 8. BILLING / SUBSCRIPTION (Monthly add-on)

- Product type: **auto-renewable subscription** (StoreKit 2). Product `Autohop Pro`, monthly,
  **AUD $2.99**, with a **7-day free trial** (StoreKit introductory offer).
- App-Store legitimacy: the subscription funds an ongoing **server service** (hosted crawling + push).
  This is a compliant IAP use (contrast with the prohibited silent-audio keep-alive). Provide clear
  value copy + a functional free tier (Tier 0). Restore-purchases supported.
- Entitlement source of truth = server (relay), not the client, to prevent spoofed relay use.
- **App Store Server Notifications V2** webhook `POST /v1/asn`:
  - Verify signed payload (§6.1). Handle: `SUBSCRIBED`, `DID_RENEW`, `DID_CHANGE_RENEWAL_STATUS`,
    `EXPIRED`, `GRACE_PERIOD_EXPIRED`, `REFUND`, `REVOKE`.
  - Update `subscribers.status` + `expires_at`. On `expired/revoked`: stop fan-out (device rows kept
    until pruned; app auto-reverts to Tier 0).
  - The route + handler exist and the INNER transaction JWS is now fully
    chain-verified (§6.1) — but Apple's App Store Connect hasn't actually been
    configured to send notifications to `/v1/asn` yet. Still open; needs Kevin
    to set the URL in App Store Connect → App Info → App Store Server
    Notifications.
- Reconciliation cron (daily): for `subscribers` with `expires_at` near/past, re-query App Store
  Server API; correct drift from missed webhooks.
  - IMPLEMENTED 2026-07-10: `consumers.ts dailyMaintenance()` → `reconcileEntitlements()`.
    Re-queries EVERY `active`/`grace` subscriber (not just near-expiry ones —
    simpler, and cheap at this product's current scale) via `appStoreServerAPI.ts`,
    corrects `status`/`expires_at` on any drift, bounded to 200/run (self-heals
    the remainder next day if ever exceeded, never a hard cutoff). Piggybacks
    on the EXISTING 5-min crawl cron rather than a separate trigger — see §11's
    scaling note and `index.ts`'s `MAINTENANCE_HOUR_UTC`/`MAINTENANCE_MINUTE_UTC`
    gate (fires once/day at 3:15am UTC) — Cloudflare's account-wide 5-cron-
    trigger limit meant a 2nd trigger would have required sacrificing one of
    Kevin's other production feed-crawler Workers' cron slots; not worth it.
- Grace period: honor Apple billing-retry grace (`status=grace` still served).

---

## 9. API CONTRACTS (v2; v1 wake compatibility retained)

All JSON; HTTPS; `Content-Type: application/json`. Errors: `{ "error": {code, message} }`.

| Method | Path | Auth | Body → Response |
|---|---|---|---|
| POST | `/v1/register` | StoreKit JWS | `{jws, apnsToken, platform, bundleEnv, syncGroupId?}` → `{deviceId, deviceSecret, entitlement:{status,expiresAt}}` |
| POST | `/v1/register-paired` | none (trust via syncGroupId) | `{syncGroupId, apnsToken, platform, bundleEnv}` → same shape as `/v1/register`. ADDED 2026-07-10 for tvOS (§4/§14.1) — no purchase of its own; succeeds IFF an already-registered device shares this `syncGroupId` AND has an active/grace subscriber. `402 not_entitled` otherwise. Same rate limiter as `/v1/register`. |
| POST | `/v1/unregister` | Bearer | `{}` → `204` (deletes device + feed_devices) |
| POST | `/v1/feeds` | Bearer | `{set?:[url]}` or `{add?:[url], remove?:[url]}` → `{count,changed,revision,feeds:[{id,url}]}` (diffed + batched; 64 KiB body, 200-set/100-delta limits; 429 includes `retryAfter`) |
| POST | `/v1/heartbeat` | Bearer | `{apnsToken?, syncGroupId?}` → `{entitlement}` (refresh token/group, last_seen) |
| POST | `/v1/sync-nudge` | Bearer | `{recordType?}` → `202` (fan `sync-nudge` to same-group peers) |
| POST | `/v1/asn` | Apple sig | Apple ASN v2 payload → `200` |

Idempotency: `/v1/feeds` diffs normalized membership; registration atomically reuses the existing
device row for `(apnsToken,bundleEnv)` while rotating credentials, preserving crawler history.

---

## 10. FAILURE MODES

| Failure | Behavior |
|---|---|
| Relay unreachable | App uses Tier 0 on-device refresh. No data loss (INVARIANT-0). |
| Subscription lapses | Relay `status=expired` → no fan-out → app reverts to Tier 0. |
| APNs 410 / bad token | Delete device row. App re-registers on next launch. |
| APNs 429 throttle | Requeue with backoff; coalescing (§6.3) keeps volume legal. |
| Feed persistently errors | Exponential backoff to 6h; never dropped, never hammered. |
| Missed ASN webhook | Daily reconciliation cron corrects entitlement. (IMPLEMENTED 2026-07-10) |
| Orphan feed (0 subscribers) | Deleted; crawl stops. (IMPLEMENTED 2026-07-10 — `sweepExpiredAndOrphans()`, same daily maintenance pass as reconciliation; computed via a LEFT JOIN against the live `feed_devices` table, so it self-heals `subscriber_count` drift too, not just true zero-subscriber feeds.) |

---

## 11. SCALING & COST

- Crawl cost ∝ (distinct feeds × 1/interval); 304s are cheap. Feed overlap across users amortizes.
- Shard crawl + fan-out through Queues; keep each invocation under Worker CPU/subrequest limits.
- Push cost ∝ (changed feeds × subscribers-per-feed), bounded by coalescing.
- Baseline: Cloudflare Workers Paid ($5/mo) + D1 + Queues + Cron. Subscription revenue must exceed
  marginal cost; monitor cost-per-active-subscriber and set price accordingly (§8).

---

## 12. OBSERVABILITY

Metrics: crawl ticks, feeds-due, 304 vs 200 ratio, new-episode events, pushes sent, APNs
status histogram, coalesce-suppressed count, active subscribers, cost estimate. Log (no PII):
feed error rates, ASN event counts. Alert on APNs auth failure, ASN signature failure, crawl backlog.

---

## 13. BUILD PHASES

1. **Relay skeleton**: Worker + D1 schema + `/v1/register` + StoreKit JWS validation + device auth.
2. **APNs path**: JWT signer, PUSH_QUEUE consumer, coalescing, token pruning. Manual test push.
3. **Crawler**: Cron + CRAWL_QUEUE + conditional GET + diff + FANOUT_QUEUE. End-to-end new-episode wake.
4. **App integration**: StoreKit 2 product, entitlement gating, register/feeds/heartbeat, wake handling.
5. **Billing hardening**: `/v1/asn` webhook + daily reconciliation + grace handling.
6. **sync-nudge**: app emits nudge on iPhone change; TV wakes + fetches. (High-value; can precede 3.)
7. **Privacy policy update + App Store subscription review submission.**

---

## 14. DECISIONS (resolved)

- **Product**: `Autohop Pro`, auto-renewable monthly, **AUD $2.99**, **7-day free trial** (introductory offer).
- **Defaults**: `CRAWL_TICK`=5m, `MIN_INTERVAL`=5m, `MAX_INTERVAL`=6h, `COALESCE_WINDOW`=15m.
- **Coalescing store**: D1 `pending_feed_changes` + `feed_push_state` for targeted feed wakes;
  `push_state` coalesces identity-free sync nudges. Consider a Durable Object only if contention grows.
- **Wake payload**: protocol v2 carries up to eight opaque relay feed IDs, never RSS URLs. Durable
  per-device coalescing retains additional IDs for later windows. A v1 generic wake remains a
  bounded due-only compatibility fallback in the app.
- **Retention**: purge device rows 30 days after entitlement lapses with no activity.
  IMPLEMENTED 2026-07-10 as `last_seen_at < now - 30d` specifically (`sweep-
  ExpiredAndOrphans()`) — last_seen_at is only ever bumped by §4.5's heartbeat,
  so a device that stops heartbeating (uninstalled, entitlement lapsed and the
  app stopped trying) ages out after 30 days regardless of the exact reason.

### 14.1 Product bundling — tvOS gated to Autohop Pro (under consideration)
The tvOS app relies on iCloud sync that lags badly today; the relay's `sync-nudge` (§6.4) fixes it by
pushing the TV to fetch immediately. Proposed bundling: **make the tvOS app an Autohop Pro benefit.**
Consequences:
- Every tvOS device is a Pro subscriber ⇒ the relay always serves TV ⇒ `sync-nudge` is always available
  where it's needed, and tvOS ships with working sync instead of today's laggy experience.
- iPhone app stays free (Tier 0). `Autohop Pro` adds: overnight freshness + fast multi-device sync + tvOS access.
- Gate tvOS at launch on a validated entitlement (same StoreKit path); no Pro ⇒ tvOS shows an upsell screen.
- **RECEIVE-SIDE BUILT 2026-07-10, THIS DECISION STILL NOT MADE**: sync-nudge's TV half is now real —
  `TV/App/TVAppDelegate.swift` (registerForRemoteNotifications + push dispatch) and `TVAppModel.
  registerWithRelayIfPossible()` (resolves sync_group_id via `CKContainer.fetchUserRecordID()`, calls
  `POST /v1/register-paired`). Deliberately does NOT implement the gating this section is about —
  TV registers unconditionally and just fails quietly (logged, no UI) if the paired iPhone has no
  active subscription, so this piggybacks on whichever way §14.1 eventually resolves rather than
  forcing it. If tvOS-gating is later adopted, `registerWithRelayIfPossible`'s current silent-failure
  posture would need an actual upsell screen wired to the SAME registration-failure signal.
  UNTESTED end-to-end (needs a Sandbox purchase on the iPhone AND a real Apple TV — Simulator can't
  receive push or CloudKit sync).
