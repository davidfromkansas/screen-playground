# Persona test flows

Automated in `App/ScreenPlaygroundTests/PersonaFlowTests.swift`. The tests drive the same `EditorModel` calls the UI makes and run inside the app. Run them with:

```bash
xcodebuild -project ScreenPlayground.xcodeproj -scheme ScreenPlayground -destination 'platform=macOS,arch=arm64' test
```

The fixture recordings are variable frame rate, with an idle gap and no frames, like a real screen recording.

## Leo, developer and educator (tutorials and bug repros)

Leo cuts a lot and fixes mistakes.

| Step | Checks |
|---|---|
| Split at 5 points (C) | 6 segments |
| Select the last segment, then delete it | No crash. The stale inspector binding reads safely and ignores writes. Selection clears. |
| Ripple-delete at the very end (X) | No crash |
| Delete down to the last segment, then try deleting that one | Stays at 1 segment (beep, no crash) |
| Undo back to 6 segments, then redo | History restores correctly |
| Add a zoom, switch it to Manual, aim it at the top-right | Preview jumps into the settled zoom. The target picker shows the real frame. |
| Drag one zoom onto another | Zooms stay side by side, never overlapping |
| Add a blur mask and a Glass Loupe zoom; export 720p Web (Low) | File duration matches the edit |

## Maya, indie founder (product demos)

Maya wants a polished demo with music.

| Step | Checks |
|---|---|
| Open a recording | Auto-zooms are already created from clicks |
| Trim the start and end; speed up the middle 2× | Output 9.0 s |
| Add background music (shorter than the video) at 60% | The preview mix includes the music, looped to the edit length |
| Export MP4 | Has an audio track; duration 9.0 s |
| Remove the music, export again | No audio, so no stale music |

## Priya, product designer (styled loops)

Priya cares about the look.

| Step | Checks |
|---|---|
| Wallpaper, padding, corners, Touch cursor 2.5×, ripple clicks, loop cursor | — |
| Square, then vertical | Canvas is 1080×1080, then 1080×1920 |
| Render a styled vertical frame | Renders at the right size, with the cursor or click effect |
| Save a preset, reset the look, apply the preset | The look is restored |
| Export a square GIF and MP4 | GIF has 144 frames (6 s at 24 fps); MP4 is 1080×1080 |

## Manual checks (need a real screen and permissions)

- Record a display, a window and an area (⌥⌘↩). Stop, and the editor opens with zooms.
- Play with background music: the music is audible and stays in sync when you scrub or loop.
- While paused, click around the timeline: the preview updates every time.
- Hover segments: trim handles appear; drag them to trim.
