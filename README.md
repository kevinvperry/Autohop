# Autohop

Autohop is an iOS podcast player focused on automatically maintaining a prioritized listening queue from RSS subscriptions. It supports audio and video podcast enclosures, manual and automatic feed refresh, downloaded playback, queue management, per-show playback settings, chapter filtering, vocal boost, listening history, diagnostics, and download monitoring.

## Current Product Direction

- Podcast-first RSS playback with support for audio and video episodes.
- A priority list controls the order in which subscriptions feed the queue.
- The player resumes incomplete episodes, tracks listening history, and advances to the next queued episode.
- Feed refresh can run manually, on an active foreground timer, and opportunistically through iOS background refresh.
- Downloads are tracked on a dedicated page with progress, pause/resume, failed downloads, and recent successful downloads.
- Diagnostic logging records feed refresh, downloads, queue updates, playback, and resource metrics to help investigate bugs.
- Per-subscription settings include title override, priority rank, playback speed, vocal boost, start/end skip, notifications, auto archive, chapter filtering, and auto-refresh exclusion.

## Build Notes

- Open `Autohop.xcodeproj` in Xcode.
- Select the Autohop target, configure Signing & Capabilities, and choose a development team.
- Build and run on an iPhone or simulator using iOS 17 or later.

## Scope

Spotify integration is no longer part of the Autohop project. The app should remain focused on podcast queue automation, downloaded media playback, video podcast support, and clear diagnostic tooling.
