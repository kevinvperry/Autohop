# Settings clarity audit — Version 1.7

AI CONTEXT: Presentation audit of the iOS-family SettingsView and SubscriptionSettingsView main forms. Preserve all bindings, picker values, destinations, sidebar IDs, conditional sections and destructive-action confirmation. This document describes source changes, not device usability certification. Linked feature editors are not redesigned in this pass.

## Findings and approach

The strongest issue was dense footer copy: several paragraphs mixed the purpose of a setting, exceptions and internal behaviour. Global defaults were easy to confuse with changes to existing podcasts. Automation combined three independent controls and the full Play Instant explanation in one block. Technical RSS/OPML labels lacked beginner context.

Retain the familiar glass cards, purple controls and responsive sidebar. Use short paragraphs prefixed with the control name when explaining multiple controls. Put scope first for global defaults. Keep material exceptions visible rather than hiding them in help menus. Shorter copy does not necessarily mean a shorter page: paragraph spacing deliberately trades some height for readability.

## Main Settings review

| Section | Finding and action |
| --- | --- |
| Startup | Removed repeated picker-option explanation and shortened welcome note. |
| Release Radar | Replaced scheduling internals with a plain explanation of learned timing and device constraints. Corrected notification copy to distinguish future defaults from saved podcast choices. |
| Background refresh warning | Split action and force-quit caveat; retain iOS scheduling limitation and Settings link. |
| Auto Archive | Lead with new-subscription scope; separate played, inactive and limit explanations; preserve manual protection, cadence and activity link. |
| Downloading | Shorten network explanation; retain automatic-download scope and background limitations. |
| Controls | Separate awake, scrubbing, badge and skip explanations by control name. |
| Default Playback | Lead with applicability; separate brief audio feature explanations. All shared playback controls retained. |
| Default Episode Trim | Explain intros/outros and recording-time units in two sentences. |
| Subscriptions | Keep all navigation/import/export actions; explain RSS and OPML in a short footer. |
| Sync | Separate synced library, device-local data and initial default; remove iPhone-only wording. No sync behaviour changed. |
| Storage | Existing count, size and management link are clear; retain short space-saving guidance. |
| Diagnostics | Shorten normal/detailed explanation; retain temporary-investigation advice and hidden developer gate. |
| Contact | Shorten support/beta invitation. |
| About | Version, acknowledgements and hidden unlock remain intact; no extra explanatory copy needed. |

## Individual Subscription Settings review

| Section | Finding and action |
| --- | --- |
| Podcast | Title editing, rank editing and author remain; preserve disabled-rank explanation for excluded feeds. |
| Podcast Replay | Existing concise dedicated section already meets the design direction; retained above filters. |
| Download Feed Filters | Short purpose statement plus separate sync/tracking note. Linked editor and manual bypass retained. |
| Playback | Split voice/volume explanation from Vocal Boost/Trim Silence; retain audio-only scope. |
| Episode Trim | Same concise explanation as global defaults. |
| Automation | Separate notifications, exclusion, Play Instant behaviour and waiting safeguards. Preserve manual refresh, priority implications, two-minute threshold, 30-minute wait, warning and return behaviour. |
| Auto Archive | Separate played/inactive/limit guidance; retain news option, manual protection, filters and cadence. Clarify that Replay shares Episode Limit. |
| Chapters | Short explanation of position-based future behaviour, immediate changes and protected current chapter. |
| Feed | Explain publisher RSS and full-address copy action simply. |
| Subscription removal | Existing explicit destructive action and confirmation remain; no shortening of the deletion warning. |

## Functionality safeguards

No settings data, defaults, option sets, persistence, queue policy, sync logic or navigation routes changed. No controls were removed or moved into hidden advanced sections. Sidebar section counts and IDs remain unchanged. Shared playback components and the previously updated filter/replay editors are retained.

## Validation and remaining checks

Source review covers every main-form section listed above. Final iOS simulator build succeeded; `git diff --check` passed. Runtime checks still required: narrow iPhone, iPad/Mac sidebar scrolling, largest Dynamic Type and VoiceOver reading order. Copy-only changes do not justify tests that merely duplicate strings. No device usability result is claimed.
