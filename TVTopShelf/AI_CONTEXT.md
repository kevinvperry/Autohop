# Autohop TV Top Shelf Extension Context

<!--
AI CONTEXT — Entire TVTopShelf directory.

PURPOSE: Memory-bounded TVServices extension that renders the current dynamic
Top Shelf snapshot while the containing tvOS app is not running.

OWNERSHIP: Read-only for all product/domain state. The extension reads
Foundation-only JSON and prepared images from the shared App Group. Its only
write is an atomically replaced, maximum-4 KB operational heartbeat containing
outcome, generation, counts and duration for local Diagnostics. It never writes
content/identity, downloads, opens CloudKit or GRDB, parses RSS, initializes
TVAppModel, mutates queue/history, or plays media.

ACTION CONTRACT: tvOS Select invokes `displayAction` and the remote Play/Pause
button invokes `playAction`; both deliberately point to the exact-identity play
route. Episode-description navigation remains an in-app secondary action.

FAILURE CONTRACT: Any missing entitlement, invalid/stale/oversized manifest,
account-scope mismatch, missing artwork or malformed action returns nil or
omits the affected item so tvOS uses Autohop's static fallback. Completion must
be called exactly once and promptly.

PRIVACY: Never log titles, episode keys, subscription IDs, URLs or account
scope. Demo Library content is never published by the containing app.
-->
