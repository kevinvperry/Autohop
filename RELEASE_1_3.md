# Autohop 1.3 Release Boundary

<!--
AI CONTEXT — RELEASE_1_3.md
Operational source of truth for the Version 1.3 App Store submission. This is
not a roadmap: it records deliberately excluded implementations and the checks
required to prevent them reaching production. Code availability is owned by
ReleaseFeatures in Store/AutohopProStore.swift; project versioning and target
separation are owned by project.yml.
-->

## Shipping scope

- Submit only the `Autohop` iOS scheme, version 1.3 build 4 or later.
- Do not upload or submit the separate `AutohopTV` target (development version 0.1).
- Do not attach `autohop_pro_monthly` to the 1.3 App Review submission.
- Keep the subscription unavailable for sale while Pro remains under development.
- Do not advertise Apple TV, Autohop Pro, or Relay-assisted delivery in 1.3 metadata.

## Enforced application behavior

The ordinary Version 1.3 Release build defines neither
`AUTOHOP_PRO_ENABLED` nor `AUTOHOP_RELAY_ENABLED`. Therefore:

- App Settings contains no Autohop Pro row.
- StoreKit product loading, entitlement observation, purchase, and restore are inactive.
- Relay registration, feed reconciliation, sync nudges, heartbeats, and push handling are inactive.
- APNs registration remains active because CloudKit uses it independently of Relay.
- Local feed refresh, background tasks, downloads, notifications, and optional private
  CloudKit sync continue to operate normally.

For controlled development only, add `AUTOHOP_PRO_ENABLED` and
`AUTOHOP_RELAY_ENABLED` to the iOS target's Swift Active Compilation Conditions.
Relay cannot become active unless Pro is also enabled. Do not add these conditions
to the normal Release configuration used for App Store archives.

## External actions that code cannot enforce

- In App Store Connect, submit the iOS version only and leave tvOS unsubmitted.
- Leave the Autohop Pro subscription out of the selected review items and unavailable.
- In Cloudflare, pause the production Worker's crawler schedules and push fan-out;
  retain a separate staging deployment for controlled testing.
- Confirm website, App Store description, screenshots, promotional text, support,
  intelligence, and privacy copy contain no claims for the three excluded features.

## Archive verification

Before upload, inspect the archive and confirm:

- `CFBundleShortVersionString` is `1.3` and the build number is current.
- The archive contains only the iPhone application—not `AutohopTV.app`.
- `Autohop.storekit`, project metadata, Apple TV artwork, and marketing source images
  are absent from the application bundle.
- A clean install has no Autohop Pro settings entry and produces no `relay.*` network logs.

