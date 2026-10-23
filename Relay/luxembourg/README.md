# Autohop Luxembourg relay (experimental)

This service streams public podcast audio through the server's outbound IP. It does not classify or remove audio. Some hosts may deliver fewer geographically targeted ads; no network-wide or country-wide exemption is assumed. No audio is stored by this service.

## Provisioning and release gate

A live Luxembourg server has **not** been provisioned by this implementation. Before enabling the service:

1. Provision a Linux host with Luxembourg outbound connectivity and Docker Compose. Point a DNS hostname at it. Permit HTTPS, certificate issuance and outbound HTTP/HTTPS; do not expose container port 8080 publicly.
2. Verify the actual IPv4 **and IPv6** egress country from inside the relay container using at least two independent IP-geolocation providers. Disable IPv6 if its egress is elsewhere. Repeat for replacements and IP changes. A hosting region name is not proof of how a podcast host classifies the address.
3. Generate a separate high-entropy token for each beta installation (`openssl rand -hex 32`). In a local, uncommitted `.env`, set `RELAY_HOST`, comma-separated `RELAY_TOKENS` and, only after verification, `LU_EGRESS_VERIFIED=true`. Never embed a shared production token in the application binary. Set file permissions to owner-only.
4. Run `docker compose up --build -d`. TLS is managed by Caddy. Access logging is not enabled. Never enable request-header/body logging, and review infrastructure logging for source URLs and credentials.
5. In Autohop → App Settings → Downloading → Reduce inserted ads, enter the HTTPS address and individual token. Check and save, explicitly select **public** shows, then enable. The application cannot reliably distinguish tokenised private feeds from public feeds: private/paid feeds must remain unselected. Video stays direct.
6. Compare identical episodes fetched directly and via the relay, including human listening around every differing region. Test Australian, US and UK shows, multiple hosts and times. Measure retained programme content, inserted-ad time, errors, throughput and transfer cost. Shorter size alone is not proof of successful ad reduction.

Default disabled until `LU_EGRESS_VERIFIED=true`. Setting it false is the operator kill switch; queued requests fail without redirecting the client. It is an operator attestation, not automated proof of geography. Geo and effectiveness validation, physical-device/background playback, production provisioning and cost validation remain release gates.

## Behaviour and limits

Authenticated `GET /v1/status` returns enabled/region/version. `GET /v1/audio` accepts a base64 publisher URL in `X-Autohop-Source` and a bearer token. The publisher URL is absent from the request line. Only a bounded Autohop user agent (or the server default) and media headers go upstream; client IP headers, cookies and credentials are not forwarded. All publisher redirects are followed by the relay. Redirect responses are never returned to clients.

DNS answers are checked and pinned for every hop. Local/private/special addresses, credentials, other schemes and non-default ports are rejected. HTTPS certificates are verified by Node. Never relax destination validation to work around an upstream issue. The container should additionally have host-level outbound firewall rules blocking internal and metadata networks as defence in depth.

Limits: 2 active transfers and 10 starts/minute per token, 12 active globally, 2 GiB/file, 15 minutes/transfer and 45 seconds idle upstream. Limits are per process, not distributed. Run one instance initially. Tokens are provisioned manually for beta; a public release requires enrolment, revocation and durable per-install quotas/billing controls. Do not publish a common token.

Range requests fail: separate requests may receive different inserted audio. The app deliberately discards relay resume data, and pauses restart from byte zero. No upstream compression is accepted. Completed downloads have a local `.delivery.json` receipt; “Via Luxembourg relay” identifies transport only, not a measured number of ads removed. Existing downloads are never automatically replaced. The completed-download context menu offers an explicit replacement with a warning and resets stored playback position. Existing externally supplied chapter timestamps may not match a different DAI timeline.

Relay failures have Retry and Download normally controls; there is no automatic direct fallback. A normal-download choice is persisted for that episode on this device. Disable a show's relay selection for a permanent per-show override. Relay settings and consent are local; the token is in the non-synchronising device Keychain.

## Checks

`npm test` exercises authentication, disabled operation, exact streaming, range rejection, destination classification and quotas. Run on a supported Node 22+ runtime. Tests use local fixture streams, not live Luxembourg downloads. No dependency packages are required.
