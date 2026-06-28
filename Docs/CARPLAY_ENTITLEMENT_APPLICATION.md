# CarPlay Entitlement Application Draft

Use this as the working copy when requesting the CarPlay app entitlement in Apple Developer.

## Recommended entitlement category

Audio app.

Autohop is a native iOS podcast player. Its CarPlay experience should focus on playback of downloaded podcast episodes, lightweight Up Next navigation, Now Playing controls, and hands-free continuity while driving.

The relevant entitlement key is:

```xml
<key>com.apple.developer.carplay-audio</key>
<true/>
```

## Short description

Autohop is a download-first podcast player for high-volume listeners. It automatically builds a priority-based queue from the user's subscribed podcasts, downloads episodes ahead of time, and keeps playback moving with minimal interaction. In CarPlay, Autohop will provide a road-safe audio experience for starting, pausing, resuming, skipping, and choosing from already downloaded podcast episodes.

## Why Autohop belongs on CarPlay

Autohop is designed for listeners who often consume podcasts while driving and want fewer screen interactions, not more. The core product behavior is an automatically maintained playback queue: after the user sets podcast priorities on iPhone, Autohop selects downloaded, unplayed episodes and advances through them without requiring manual queue management.

CarPlay support would let users control that existing audio experience through the vehicle interface while keeping attention on the road. The CarPlay app will avoid browsing-heavy workflows and will not expose podcast discovery, account setup, feed management, detailed settings, or long-form reading surfaces in the car.

## Proposed CarPlay feature set

- Now Playing screen for the current podcast episode.
- Play, pause, skip back, and skip forward using the user's configured skip intervals.
- Continue the automatic priority queue.
- View a short Up Next list of downloaded episodes.
- Select an already downloaded episode from Up Next.
- Access a small library view limited to subscribed podcasts with downloaded, playable episodes.
- Support lock screen, Control Center, steering wheel, and remote transport commands through the existing audio session and Now Playing integration.
- Keep artwork, episode title, podcast title, duration, and progress visible where supported by CarPlay templates.

## Excluded from CarPlay

- Podcast discovery and search.
- Adding RSS feeds.
- Subscription management and reordering.
- Detailed app settings.
- Stats and listening history.
- Long episode descriptions, show notes, web pages, or links.
- Social sharing.
- Any feature requiring text entry while driving.
- Sleep Schedule setup, Release Radar configuration, diagnostics, acknowledgements, onboarding, or other maintenance flows.

## Safety and distraction-reduction approach

Autohop's CarPlay interface will be template-based and limited to audio playback tasks. The default behavior is continuous playback from a precomputed queue, so the driver does not need to build or manage a queue while driving. Interactions will use short labels, large controls, and shallow navigation. Autohop will rely on system media controls and CarPlay audio templates instead of custom, visually dense UI.

Autohop is also download-first: the queue only plays files already on the device. This reduces the need for troubleshooting playback while driving due to weak cellular coverage or buffering.

## Technical readiness

Autohop already includes the core audio behaviors needed for a CarPlay audio app:

- Native iOS audio playback engine.
- Background audio playback mode.
- Now Playing metadata and remote command handling.
- Local downloaded episode files.
- Automatic downloaded queue.
- Podcast artwork, title, episode title, duration, and progress metadata.
- User-configurable skip durations.

The CarPlay implementation will add a CarPlay scene and use Apple's CarPlay framework templates for audio playback and list-based episode selection.

## Rules from CarPlay Developer Guide 2026-06-08

- CarPlay apps are not separate apps. Autohop would add CarPlay support to the existing iOS app.
- The app must be designed primarily for the requested category. For Autohop, the CarPlay category should be audio playback.
- All CarPlay flows must be meaningful while driving and possible without interacting with iPhone.
- The app must never instruct the driver to pick up iPhone. If login or another blocking condition exists, the message should tell them the condition and let them act later when safe.
- CarPlay UI must use supported templates for their intended purpose. Unsupported templates can trigger runtime exceptions.
- Audio apps can use list, tab bar, grid, alert, action sheet, and now playing templates, but should keep the hierarchy shallow.
- Audio apps are limited to a template depth of 5, including the root template.
- Some cars dynamically limit lists to 12 items, so Autohop should be useful even when only 12 Up Next rows are visible.
- The Now Playing template must be populated whenever CarPlay can show it, including when opened from the CarPlay home screen or navigation bar.
- Only a list template can be pushed on top of the Now Playing template. Autohop's "Playing Next" action should therefore open a list of upcoming episodes.
- The app icon appears on the CarPlay home screen once the entitlement is added; Autohop cannot selectively hide CarPlay from some users.
- CarPlay is frequently used while iPhone is locked, so downloaded audio files, artwork, queue state, and playback metadata must be accessible while locked.
- Files protected with `NSFileProtectionComplete` or `NSFileProtectionCompleteUnlessOpen` are not accessible while locked. Keychain items requiring unlocked access are also unavailable.
- The audio session should activate only when Autohop is actually ready to play audio, not merely because CarPlay launched.
- Recording is generally unsupported in CarPlay and should not be enabled by Autohop.
- CarPlay assets should support 2x and 3x scales plus light and dark appearances. SF Symbols are encouraged for template icons.
- CarPlay notifications are not relevant to Autohop's audio entitlement path; the guide lists them for communication, EV charging, parking, public safety, and driving task apps.

## Proposed CarPlay IA

Keep the first version deliberately flat:

1. Root template: Now Playing when metadata is available, otherwise Up Next.
2. Primary tab/list: Up Next, containing the current automatic downloaded queue.
3. Now Playing: shared `CPNowPlayingTemplate`.

Avoid search as a primary workflow. If search is ever added later, it should be an alternate parked/safe interaction because cars may disable keyboards while driving.

## Pre-implementation checks

- Confirm current downloaded audio files are readable while the phone is locked.
- Confirm artwork cache files needed by CarPlay are readable while locked, or provide safe placeholder artwork.
- Confirm queue state needed by CarPlay is available without opening the iPhone UI scene.
- Confirm playback can launch from a CarPlay-only scene.
- Confirm remote commands and Now Playing metadata remain correct when CarPlay is connected.
- Confirm Autohop does not activate its audio session merely when the CarPlay scene connects.
- Confirm list rendering remains useful with a 12-item cap.

## Suggested Apple form response

Autohop is a native iOS podcast player and should be considered for the CarPlay audio app category.

Autohop helps high-volume podcast listeners play downloaded podcast episodes with minimal manual interaction. The user subscribes to podcasts and sets a priority order on iPhone. Autohop then automatically builds a queue from downloaded, unplayed episodes and continues from one episode to the next.

The planned CarPlay experience is intentionally limited to road-safe audio tasks: Now Playing, play/pause, skip back/forward, continuing the automatic queue, viewing a short Up Next list, and selecting already downloaded episodes from subscribed podcasts. Autohop will not include discovery, search, subscription management, feed editing, settings, stats, sharing, web content, or text-entry workflows in CarPlay.

CarPlay support would let drivers control Autohop through the vehicle interface and system media controls while keeping focus on the road. Because Autohop is download-first and queue-driven, the driver can listen continuously without managing playback from the phone or handling buffering problems while driving.

## Evidence to prepare before submission

- App name: Autohop.
- Bundle ID.
- Apple Developer team ID.
- App Store status or TestFlight status, if applicable.
- Screenshots or short screen recording of the iPhone Now Playing screen.
- Screenshot or demo of the automatic queue.
- Explanation that Autohop is a podcast/audio playback app, not a navigation, parking, vehicle-control, or messaging app.
- Brief CarPlay mockup or bullet list showing only Now Playing and Up Next.

## Implementation notes after entitlement approval

- Add the CarPlay entitlement to the app target.
- Add a CarPlay scene configuration to `Info.plist`.
- Implement a CarPlay scene delegate.
- Use CarPlay audio/list templates for Now Playing, queue, and downloaded podcast lists.
- Reuse existing playback, queue, artwork, and remote command services.
- Test with the CarPlay simulator from Apple's additional tools for Xcode.
