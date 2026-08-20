# Autohop tvOS Demo Assets

<!--
AI CONTEXT — Source/provenance record for the Release-build App Review demo.
The Swift fixtures and both media files are synthetic first-party material
created for Autohop on 15 August 2026. They contain no podcast excerpts, user
data, third-party artwork, credentials, feeds, analytics or CloudKit records.
Keep resources offline-capable and preserve this provenance when replacing them.
-->

- `Media/autohop-demo-audio.wav`: 30-second generated 220 Hz sine-wave sample,
  mono PCM at 44.1 kHz. Used to exercise local audio playback, pause, seek,
  speed and progress.
- `Media/autohop-demo-video.mov`: 12-second generated 1280×720 H.264 colour
  animation. Used to exercise local video presentation without network access.
- Artwork is generated at runtime from gradients, SF Symbols and synthetic show
  titles in `TVDemoRootView`; there are no external image assets.

The demo app path must remain functional when network and iCloud are unavailable.
