# Persona scenarios (acceptance tests)

Screen Playground is free for everyone. Every scenario must end in a downloadable MP4 that plays in QuickTime and on iPhone, and that can be shared via AirDrop, iMessage or Slack.

## Personas

- **Maya, indie SaaS founder.** Makes 1–3 minute product demos for X, Product Hunt and her landing page. She wants zero-edit polish, and both vertical and wide cuts.
- **Leo, developer and educator.** Makes 5–15 minute tutorials and bug repros with his webcam and voice. He wants captions, keyboard-shortcut overlays, cut mistakes, and long typing sped up.
- **Priya, product designer.** Makes iPhone and Figma prototype reels. She wants a device frame, square or vertical format, music, and a looping GIF.

## Scenario status

Some scenarios are covered by `make e2e` (headless, run against a synthetic recording); the rest are checked by hand.

| # | Scenario | Automated (`scripts/e2e.sh`) | Manual check |
|---|---|---|---|
| E1 | **Zero-edit demo.** Record a window → auto-zooms → export 1080p60 | ✅ export + ffprobe | Record a Safari window with ⌥⌘↩ → Window → Record; stop; editor opens with zooms; Export → Save |
| E2 | **Vertical cut.** 9:16, trim start and end, 2× section, preset | ✅ | Aspect menu → Vertical; right-click clip → Speed 2×; Presets → Apply |
| E3 | **Quick share.** Area recording → clipboard | ✅ (720p web) | Area mode, drag 1280×720; Export → Copy to Clipboard → paste in Messages |
| E4 | **Tutorial with face and voice.** Camera, mic, pause, layouts | — | Pick camera and mic in the picker; pause with ⌥⌘P; left toolbar → split layout; export at 4K |
| E5 | **Clean it up.** Transcript edit, captions, keycaps, noise reduction | — (M8/M9) | |
| E6 | **Bug repro.** Cut, blur mask, Glass Loupe, small file | ✅ (cut, small file) | Press X at a mistake; left toolbar → blur mask; zoom → Glass Loupe; export 720p Web (Low) |
| E7 | **iPhone reel.** USB device, frame, square, music | — (M10) | |
| E8 | **Figma loop.** Touch cursor, loop position, GIF + MP4 | ✅ (square + GIF) | Cursor panel → Touch, 1.5×, Loop position; export MP4 and GIF |
| E9 | **Crash recovery.** Kill during recording → recover | — | Start recording; `kill -9` the app; relaunch → "Recovered a recording" → Open → Export |
