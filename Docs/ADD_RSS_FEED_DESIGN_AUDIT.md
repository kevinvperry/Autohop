# Add RSS Feed redesign — Version 1.7

AI CONTEXT: AddFeedView remains the manual RSS entry flow for Search and App Settings. Keep SubscriptionStore.add as the subscription path and retain mini-player ownership. Preview must correspond to the entered URL; editing invalidates the preview. Do not subscribe automatically or read the clipboard silently.

## Design review and implementation

The previous page led with a technical URL field, an empty Preview section and raw episode media URLs. It lacked a brief explanation of RSS and clear distinction between previewing and subscribing.

- Replay-style glass cards, purple icons and buttons, dark background and responsive Form sizing.
- Intro explains the purpose and the three actions: paste, check, subscribe.
- Step 1 provides a labelled, multiline, high-contrast URL field with URL keyboard and no autocorrection/capitalisation. Standard system paste remains available; no unsolicited clipboard access.
- Expandable RSS help explains where to find a link and distinguishes podcast web pages from feeds.
- Preview button disables for blank input and while loading, shows progress and dismisses the keyboard. The address is disabled during fetch.
- Step 2 explains that nothing is added before Subscribe. Loaded preview shows artwork with fallback, podcast title, author, latest episode and chapter count. Raw media URL remains available under Episode link.
- Feed errors show a plain-language recovery prompt and expandable original error details. Save errors remain visible beside Subscribe.
- Back navigation, successful dismissal, store validation and mini-player are preserved.

## Correctness follow-up

Editing the URL clears cached preview and save errors. Pasted surrounding whitespace is trimmed consistently for preview and save. This avoids associating an old parsed feed with a newly typed URL. No download policy, persistence format or subscription default changes.

## Validation

Final iOS simulator build succeeded; whitespace validation passed. Source review covers idle, loading, error, loaded and save-error states. Runtime visual checks, real-feed submission, duplicate-feed error, keyboard, VoiceOver, large Dynamic Type and iPad/Mac checks remain outstanding. No subscription was added during validation.

### Preview button visibility follow-up

Preview Podcast is hidden for empty or whitespace-only input, appears after typing or pasting a link, and remains visible with its progress indicator during loading. Clearing the field hides it again. Existing URL validation is retained.
