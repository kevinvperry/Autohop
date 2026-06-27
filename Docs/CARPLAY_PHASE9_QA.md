# CarPlay Phase 9 QA

AI CONTEXT: This file records the Phase 9 verification status for Autohop's
CarPlay implementation. Keep it factual: separate checks completed by Codex from
checks that require Apple's CarPlay Simulator app or real vehicle hardware.

Date: 2026-06-26

## Codex-Verified Checks

- Xcode package resolution completed for the `Autohop` scheme.
- The generated Xcode project builds successfully for the booted iOS Simulator.
- The focused CarPlay behavior tests pass in the Xcode app test target.
- `CarPlayBehaviorTests` cover downloaded-only queue projection, empty queue projection, Play Next with and without a current episode, current-episode archive advance/clear behavior, playback speed cycling, and Shared Listening toggle/speed updates.
- XcodeGen regeneration preserves the test target Info.plist generation needed for Xcode test execution.

## Environment Limits

- Apple's CarPlay Simulator app was not found in `/Applications`, `/System/Applications`, `/Library/Developer`, or the installed Xcode app bundle.
- Because the CarPlay Simulator app is unavailable on this Mac, the visual CarPlay runtime checklist has not been completed here.
- Real wired or wireless CarPlay hardware checks require the app to be installed on a device connected to a compatible vehicle or head unit.

## Manual CarPlay Simulator Checklist

- Launch Autohop from the CarPlay home screen.
- Launch while the iPhone UI is already open.
- Launch while the iPhone UI is not open.
- Confirm a current episode opens Now Playing.
- Confirm no current episode opens Queue.
- Confirm an empty queue shows `No downloaded episodes`.
- Open Queue, tap a row, and confirm the action page shows Play Now, Play Next, Play Last, and Archive.
- Confirm Now Playing Archive advances to the next downloaded episode.
- Confirm the speed button opens slower/faster controls using Autohop's existing preset speeds.
- Confirm Shared Listening can be toggled and its speed picker works.
- Check light and dark appearances.
- Check compact and wide CarPlay screen sizes if available.

## Manual Hardware Checklist

- Test wired CarPlay.
- Test wireless CarPlay if available.
- Start playback from CarPlay while the iPhone is locked.
- Render the downloaded queue from CarPlay while the iPhone is locked.
- Confirm head unit controls work.
- Confirm steering wheel play, pause, and skip controls work.
- Disconnect and reconnect during playback.
- Change audio routes during playback.
- Test poor or unavailable network and confirm CarPlay does not start downloads, feed refresh, search, browsing, or streaming.

## Phase 9 Gate Status

- No app build failures found in Codex verification.
- No focused CarPlay behavior test failures found in Codex verification.
- CarPlay visual runtime gate remains pending until CarPlay Simulator or real hardware is available.
- Locked-device and hardware gates remain pending until real device testing is performed.
