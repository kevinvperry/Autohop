# Autohop

**The podcast player for people who are serious about listening.**

Autohop is a native iOS podcast player built around a single idea: your time is the finite resource, not your content. Most podcast apps treat your queue like a to-do list you manage manually. Autohop manages it for you — automatically, intelligently, and indefinitely — so you can focus on everything else.

## Product Vision

Autohop is a **priority-playlist focused podcast player** aimed at serious, high-volume podcast listeners who want a premium, low-friction experience. The goal is an "endless" listening experience that requires minimal engagement from the user once set up, allowing them to stay present in whatever they're actually doing — driving, exercising, working — while the app keeps their listening moving forward without interruption.

Autohop is built for people who already know what they love — who subscribe to more shows than they can easily keep up with and want a player that respects both their taste and their time. It keeps their shows organised, always in the right order, played exactly the way they want them.

## Core Design Goals

**1. Set your priorities once. Listen indefinitely.**
The Priority Stack is a ranked list of subscriptions the user orders once. Autohop works down that list, surfaces only downloaded episodes, and flows from one to the next without any user input. Finish an episode mid-commute and the next one starts automatically — no decisions required.

**2. Audio that is actually comfortable to listen to.**
Per-podcast Trim Silence (four levels), per-podcast Vocal Boost (four intensities), per-podcast playback speed, and per-podcast start/end skip let users dial in the right listening experience for every show independently. A dense interview podcast can be compressed and crisp; a narrative show can stay natural and relaxed.

**3. Surgical queue control when you want it.**
The priority system handles everything automatically, but when a user wants to override it — Play Next or Play Last — two swipe gestures put them back in control instantly. The queue always shows exactly where things stand via color-coded status pills and pin badges.

**4. Downloads first, always.**
Autohop is a download-first player. The queue only ever plays files already on the device: no buffering mid-episode, no stalling on a poor signal. Background downloads keep the queue stocked quietly. Auto-archive policies clean up finished episodes per-podcast on a configurable schedule.

**5. Built for the serious listener, not the median user.**
Autohop's positioning is deliberately premium and niche. The target user subscribes to 10–30+ podcasts, listens several hours a day, and is frustrated that every mainstream app makes them manage their queue manually. This is the gap Autohop fills.


## Current Feature Set

- Priority Stack: drag-ranked subscriptions feed the queue automatically in order
- Endless auto-advancing queue with Play Next / Play Last manual overrides
- Podcast search via the iTunes catalog — search by name, author, or keyword; browse episode list before subscribing; 30-day recently viewed history
- Download-first playback; background downloads via URLSession
- Trim Silence engine (Off / Low / Medium / High, per-podcast) — RMS-based, ported from Pocket Casts algorithm
- Vocal Boost (Off / Light / Standard / Strong, per-podcast) via AVAudioUnitEQ
- Per-podcast playback speed (1.0–2.5x), start skip, and end skip
- Chapter support with active-chapter filtering and disabled-chapter skipping
- Audio and video podcast support with landscape unlock for full-screen video
- Background feed refresh (BGAppRefreshTask, cursor-based round-robin)
- Configurable foreground poll interval and per-podcast exclude-from-refresh
- Auto-archive policies per subscription (Never / After Playing / 24h / 2d / 7d; inactive timeout; episode limit)
- Episode status tracking: Unplayed / Queued / Paused / Playing / Played / Archived / Inactive
- Listening History: searchable per-episode log with 60-second minimum playback threshold, grouped by date
- Playback Stats: lifetime totals for listening time and time saved by Variable Speed, Trim Silence, Skipping, and Auto Skip
- New episode push notifications (per-podcast)
- Keep screen awake during playback option
- Lock screen / Now Playing controls (MPRemoteCommandCenter)
- Diagnostic logging for feeds, downloads, queue, playback, and resource metrics

## Build Notes

- Open `Autohop.xcodeproj` in Xcode.
- Select the Autohop target, configure Signing & Capabilities, and choose a development team.
- Build and run on an iPhone or simulator using iOS 17 or later.

## Scope

The app remains focused on podcast queue automation, downloaded media playback, video podcast support, and clear diagnostic tooling.
