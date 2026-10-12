# Screen Playground — Feature Spec (reverse-engineered from Screen Studio 4.0.4)

> **Purpose.** This is the full feature set (what it does, and how it feels to use) that Screen Playground needs in order to match Screen Studio. It also lists where we can beat it.
>
> **Research date:** 2026-10-11
>
> **Sources**
> - **Hands-on (✅):** Screen Studio 4.0.4 installed on this Mac. I explored its menus, editor panels and activation window.
> - **On-disk (📦):** the `.screenstudio` project bundles and the files inside the app bundle.
> - **Web (🌐):** all 66 guide articles, the full changelog (2023 → 2026-10), pricing, the roadmap and third-party reviews.
>
> Full web research with citations: [research/screen-studio-web-research.md](research/screen-studio-web-research.md).

---

## 0. The one idea everything rests on

**Record the screen without the cursor. Capture every input as data. Re-render it all in post.**

Screen Studio's signature features all fall out of this design:
- the smooth cursor;
- cursor resize and restyle after recording;
- auto-zoom on clicks;
- hiding an idle cursor;
- looping the cursor back to its start;
- motion blur;
- keystroke overlays;
- dynamic camera layouts;
- aspect-ratio changes after recording.

Every visual choice is kept as **non-destructive project state**, and the final video is rendered from raw streams plus that state at export time.

### 0.1 Observed recording bundle (📦 from real projects)

A project is a macOS package directory: `Name.screenstudio/`.

```
Name.screenstudio/
  meta.json                 # app version that wrote it, requiredVersion, createdAt
  project.json              # ALL editing state (see §0.2)
  recording-markers.json    # recording flags (timestamps)
  recording/
    metadata.json           # recorder manifest: channels, sessions, bounds, refresh rate, scale
    channel-N-display-0.mp4 + .m3u8 + -0000.mp4 + -0001.m4s …   # fragmented MP4 / HLS segments (crash-safe)
    channel-N-system-audio-0.m4a (+ segments)
    channel-N-microphone-0.* / camera-0.*                       # when enabled
    mousemoves-0.json       # [{type:"mouseMoved", x, y, cursorId, activeModifiers[], processTimeMs, unixTimeMs}]
    mouseclicks-0.json      # [{type:"mouseDown"|"mouseUp", button, x, y, cursorId, ...}]
    keystrokes-0.json       # [{type, character, isARepeat, activeModifiers[], processTimeMs, unixTimeMs}]
    cursors.json + cursors/*.png   # every cursor image seen: {id, hotSpot{x,y}, standardSize{w,h}, systemCursor}
    polyrecorder.log
```

**Key details**
- Video is written as **fragmented MP4 segments**, flushed about every 2 s, so a crash or power loss loses almost nothing. The segments are concatenated when the recording finishes.
- Every channel and every event carries **both** `processTimeMs` and `unixTimeMs`, which is how all the streams are synced.
- The display manifest stores `cropRect`, `displayId`, `displayRefreshRate` (e.g. 120), `recordingScale`, `excludedWindowIds` (the app's own windows) and `excludeFinderDesktopIcons`.
- Each recording "session" covers one continuous take, so pause/resume produces several sessions.

### 0.2 Observed `project.json` schema (📦 real defaults)

```jsonc
{
  "id", "name", "createdAt", "updatedAt", "lastSavedAt",
  "config": {
    // Background
    "backgroundType": "system" | "gradient" | "color" | "image" | "unsplash",
    "backgroundSystemName": "macOS/tahoe-light.jpg",
    "backgroundGradient": {"start":{x,y},"end":{x,y},"stops":[{color,at}]},
    "backgroundColor": "#3F37C9", "backgroundImage": null, "backgroundBlur": 0,
    "backgroundPaddingRatio": 0..~10,
    "insetPadding": {top,right,bottom,left}, "insetColor": "#000000", "insetAlpha": 0.5,
    "windowBorderRadius": 12,
    "shadowIntensity": 0.75, "shadowAngle": 90, "shadowDistance": 25, "shadowBlur": 20, "shadowIsDirectional": false,
    "defaultOutputAspectRatio": null,           // null = Auto
    "recordingCrop": {x:0,y:0,width:1,height:1}, // normalized
    "recordingRange": [0, durationMs],

    // Cursor
    "cursorSet": {"id": "macos" | "macos-tahoe" | "touch" | "halloween" | "custom-N", "variants": {}},
    "cursorSize": 0.5..1.5+, "hideCursor": false, "alwaysUseDefaultCursor": false,
    "useDefaultCursorIfAppCursorHasLowResolution": true,
    "hideNotMovingCursorAfterMs": 2000 | null, "loopCursorPositionBeforeEndMs": null,
    "stopCursorMovementInLastPartMs": 0, "removeCurshorShakeTreshold": 500,
    "optimizeOriginalCursorTypes": true,
    "cursorBaseRotation": 0, "cursorRotateOnXMovementRatio": 0.5,
    "clickEffect": null | "circle" | "ripple", "clickSoundEffect": null | "apple-magic-mouse" | "logitech-mx-master",
    "clickSoundEffectVolume": 0.25,

    // Physics (springs) — the "feel"
    "mouseMovementSpring":  {"stiffness": 470, "damping": 70, "mass": 3},
    "screenMovementSpring": {"stiffness": 200, "damping": 40, "mass": 2.25},
    "mouseClickSpring":     {"stiffness": 700, "damping": 30, "mass": 1},
    "disableMouseMovementSpring": false,
    "motionBlurAmount": 1, "motionBlurCursorAmount": 1, "motionBlurScreenMoveAmount": 1, "motionBlurScreenZoomAmount": 1,
    "alwaysKeepZoomedIn": false,

    // Camera
    "hideCamera": false, "mirrorCamera": false, "cameraRoundness": 0.25, "cameraSize": 0.35,
    "cameraPosition": "bottom-right", "cameraPositionPoint": {x:1,y:1},
    "cameraScaleDuringZoom": 0.7, "cameraAspectRatio": "original",
    "defaultLayout": {"type": "both", "cameraSize": 0.35, "cameraPositionPoint": {x:1,y:1}},

    // Overlays
    "showShortcuts": false, "hiddenShortcuts": {}, "showShortcutsWithSingleLetters": false, "shortcutsSizeRatio": 1,
    "showTranscript": true, "transcriptSizeRatio": 1,

    // Audio
    "audioVolume": 1, "muteMicrophone": false, "muteSystemAudio": false, "muteExternalDeviceAudio": false,
    "improveMicrophoneAudio": false, "microphoneInStereoMode": false,
    "backgroundAudioFileName": null, "muteBackgroundAudio": false, "backgroundAudioVolume": 0.05,

    // Devices
    "deviceFrameKey": null, "enableDeviceMockup": true, "adjustDeviceFrameToRecordingSize": true
  },
  "scenes": [{
    "id", "name": "Default", "type": "recording", "sessionIndex": 0,
    "slices": [{   // the edit decision list over source time
      "id", "sourceStartMs", "sourceEndMs", "timeScale": 1 /* 0.25 = 4x faster */,
      "volume": 1, "systemAudioVolume": 1, "externalDeviceAudioVolume": 1,
      "hideCursor": false, "disableSmoothMouseMovement": false
    }],
    "zoomRanges": [{
      "id", "startTime", "endTime", "zoom": 1.3..3.4,
      "type": "follow-click-groups" | "manual",
      "manualTargetPoint": {x,y},      // normalized, used when type = manual
      "snapToEdgesRatio": 0.25, "glideDirection": null, "glideSpeed": 0.5,
      "isDisabled": false, "isSystem": false /* auto-created */, "hasInstantAnimation": false
    }],
    "layouts": [], "masks": [], "voiceOvers": [],
    "resolvedTypingSpeedIncreaseSuggestions": []
  }]
}
```

**Takeaways for our design**
1. The edit model is a list of **slices over source time**. Each slice has its own speed, volume and cursor flags.
2. Zooms, layouts and masks are **ranges on output time**.
3. Motion is driven by **spring physics** (stiffness, damping, mass) rather than easing curves.
4. All geometry is **normalized 0–1**, so aspect-ratio changes never lose data.
5. `scenes[]` already allows several recordings or scenes per project; the UI doesn't expose this yet ("multi-clip" is on their roadmap).

### 0.3 Native helper architecture (📦 app bundle)

Screen Studio is an Electron editor UI (obfuscated JS, WebGPU/Dawn caches) with **native Swift helper binaries**:

| Helper | Role → what we need |
|---|---|
| `polyrecorder` | Multi-channel recorder: ScreenCaptureKit display/window, camera, mic, system audio, cursor images, input events, segmented fMP4 |
| `list-windows`, `manage-window` | Window picker; resizing a window to an exact size before recording |
| `hide-icons`, `macos-wallpaper` | Hide desktop icons while recording; read the user's wallpaper |
| `cursor-rect` | Cursor geometry and hotspots |
| `whisper-darwin-arm64`, `transcribe-audio` | Local speech-to-text (Whisper, or Apple Speech on macOS 26) |
| `MossFormer2_SE_48K` (CoreML) + `mlx.metallib` + `tf-restormer.safetensors` | Voice enhancement / noise reduction; image restoration (the "Clarity" zoom upscaler) |
| `detect-silence` | Hide camera during silence; tighten pauses |
| `face-detector` | Camera face tracking and auto-framing |
| `segment-video` | Camera cutout (background removal) |
| `dynamic-mask-tracker` | Masks that track content |
| `video-border-colors` | Sample edge colours (blend-in masks, auto inset) |
| `audio-composer` | Mixing audio for export |
| `ffmpeg`, `gifsicle` | Encoding, GIF optimisation |
| `file-icon`, Quick Look | Finder previews of projects |

**Bundled content to recreate (with our own assets):**
- **Wallpapers:** 9 categories, about 190 images: macOS (19), Energy (24), Glassmorphism (11), Iridescent (18), Midnight (19), Radiant (21), Raycast (32), Spring (25), Sunset (22).
- **Cursor sets:** `macos` (43 cursor types), `macos-tahoe` (43), `touch`, `halloween`, plus custom-1…custom-20 themed sets.
- **Click sounds:** Apple Magic Mouse and Logitech MX Master, each with down/up/click samples.
- **Recording sounds:** begin and end chimes.
- **Background music:** 17 royalty-free tracks in 4 categories (Commercial, Electronic, Instrumental, Lo-Fi).

---

## 1. App shell and lifecycle

| Feature | Details |
|---|---|
| Menu-bar app plus Dock | Menu-bar icon (record, stop, status); option to hide the Dock icon when idle |
| Main menus (✅) | **App:** About, Check for updates, What's new, Website, Send feedback, Account dashboard, Manage shareable links, Activate, Settings<br>**File:** Open recent, Open project…, Open last project, Show previous projects, Create project from video…, Import preset…<br>**Record:** New recording…, Record display / window / area; *After recording:* Create project / Export & copy to clipboard / Export & create shareable link / Export & save to file; toggle *Automatically create zooms*<br>**Export:** Open recent clipboard exports<br>**View:** jump to each panel; Show audio waveform, Smooth waveform, Loop playback, Always show timeline scrollbar, Show speaker notes, Show recording widget<br>**Window:** standard items plus Reset window positions |
| Onboarding | Permission walkthrough (Screen Recording, Accessibility, Camera, Microphone, Documents), each step opening the right System Settings pane; set a global record shortcut; analytics opt-out |
| Activation (✅) | Email-code sign-in ("Activate Screen Studio — enter your email"), with alternatives: Use license key, SSO, Manage account, Purchase |
| Auto-update | Background update checks, a "What's new" page, a beta channel |
| URL scheme | `screen-studio://record-display \| record-window \| record-area \| finish-recording \| cancel-recording \| restart-recording \| toggle-recording-controls \| open-settings \| copy-and-zip-project` (powers a Raycast extension) → we need `screen-playground://` |
| Safety nets | Confirm before quitting during recording or export; low-disk warnings; crash recovery; autosave with a backup on each save; double-cursor warning (custom macOS pointer size) |

---

## 2. Recording

### 2.1 Recording picker (opens on launch or with ⌥⌘↩)
- **Modes:** Display · Window · Area · Device (iPhone/iPad over USB).
  - **Display:** hover a display to highlight it, then click. Auto-selected when there is only one display.
  - **Window:** hover to highlight, click to choose; right-click opens a list of windows. Notifications are excluded. The window is brought to the front before recording.
  - **Area:** drag a rectangle. Includes resize handles, numeric W×H input, max-size hint, a 25/50/75% guide grid, saved sizes and aspect ratios, and dimming outside the area (can be turned off).
- **One-click window resize** to presets (1920×1080, 16:10, 9:16, smaller sizes).
- **Record button placed next to the chosen target**, not in a fixed toolbar.
- **Input selectors:**
  - Camera (720p, 1080p or 4K; floating live preview that is never recorded; mirror; hide preview).
  - Microphone (live level meter; stereo option; auto-gain off by default; warning when the laptop lid is closed).
  - System audio (all apps or selected apps).
  - Device audio (iPhone).
- **Picker settings (gear):** countdown (configurable), show speaker notes, quick-export settings, show quick-share widget after recording, hide desktop icons, global start/stop shortcut.
- **Recent projects** are shown beside the picker (v4).

### 2.2 During recording
- Floating **control widget**: elapsed time, Finish, Pause/Resume, Restart, Delete. It is excluded from capture and can be hidden from its context menu.
- **Recording flags** (⌃⌥⌘F) appear as markers on the timeline.
- **Speaker notes / teleprompter:** a floating window that is never captured, with scroll speed, opacity and font size.
- Ways to stop: the widget, the menu-bar icon, the Dock menu, or the global shortcut.
- Start and end sounds; countdown overlay.
- Captured as data: mouse moves, clicks (with button and modifiers), keystrokes, the cursor image for each move, window bounds and refresh rate.

### 2.3 After recording
- The **"after recording" action** is configurable: open the editor, or quick-export to the clipboard, a shareable link or a file.
- **Quick-share widget** (bottom-left): Share link · Save · Copy · Edit, with title rename. Double-click opens the editor.
- If no speech is detected, the microphone starts muted in the project.
- Auto-zooms are generated from clicks.

### 2.4 Other inputs
- **Import a video** (MP4/MOV) as a project. Zooms and backgrounds work; cursor effects do not.
- **iPhone/iPad over USB:** auto device-frame mockup (model and colour auto-detected), rotation handling, Touch cursor style. No tap capture, so no auto-zoom.
- **iPhone Mirroring window** recording, with device frame.

---

## 3. Editor: layout and UX (✅ observed)

```
┌───────────────────────────────────────────────────────────────────────────────┐
│ ●●●  📁 🗑      Project Name.screenstudio        ⌘  ↶ ↷   ✦ Presets ▾  [Export] │  top bar
├────┬──────────────────────────────────────────────────┬──┬──────────────────────┤
│ 🔍+│ [▭ Auto ▾] [⌗ Crop]      [⚙ Preview quality Full ▾] 🔍− 🔍+ │▣ │ Panel (scrolls)       │
│ 🔍◎│                                                  │➤ │  section headers,     │
│ ▭👤│              LIVE PREVIEW (WYSIWYG)              │🎥│  segmented buttons,   │
│ ▯▯ │                                                  │👤│  sliders + Reset,     │
│ 👤 │                                                  │💬│  toggles with help    │
│ ▣  │                                                  │☰ │  text, collapsible    │
│ ⊘  │                                                  │🔊│  "Advanced" sections  │
│ ▨  │                                                  │⌘ │                       │
│    │                                                  │↯ │                       │
├────┴──────────────────────────────────────────────────┴──┴──────────────────────┤
│ ✂  0:00.00   ⏮ ▶ ⏭   0:18.26                 〰 (audio scrub)  1× ──●── (tl zoom) │ transport
│ ├──0:05──────0:10──────0:15──┤ ruler                                           │
│ [██████████ Clip · 19s · ⏱1× ███████ (waveform overlaid) ██████████]  yellow    │
│ [Zoom]        [██████ Zoom · 🔍1.3× · Auto ██████]                       purple   │
│ (+ Layouts, Masks, Shortcuts, Captions, Flags tracks when present)              │
└───────────────────────────────────────────────────────────────────────────────┘
```

- **Top bar:**
  - Open-projects button and delete-project button.
  - Centred, editable project title (the extension is dimmed).
  - Command-menu button (⌘K), Undo/Redo, Presets dropdown, and **Export** (the only filled, accent-coloured button).
- **Above the preview:** aspect-ratio dropdown (Auto/16:9/9:16/1:1/4:3/3:4/4:5), Crop, Preview-quality dropdown (Full / Performance / Power saving), and preview zoom −/+.
- **Left floating toolbar (v4):**
  - Add zoom, add Glass Loupe.
  - Camera layouts: overlay, split, camera-only/fullscreen, screen-only, hide camera.
  - Add mask, add highlight.
- **Right icon rail with panels.** Each panel can be opened with ⌘1…⌘9 or from the View menu, and each is **disabled when the recording lacks that data** (e.g. no camera → Camera Layout disabled; no mic → Captions disabled; no keystrokes → Shortcuts disabled):
  1. Background · 2. Cursor · 3. Camera Layout · 4. Camera Style · 5. Captions · 6. Edit by Transcript · 7. Audio · 8. Keyboard Shortcuts · 9. Animations (+ Device Frame for iOS)
- **Visual language:**
  - Dark UI with a single indigo/purple accent.
  - Segmented "pill" buttons for enums; sliders with a lavender thumb and a separate **Reset** button.
  - Toggle switches with grey help text; chevron disclosures for "Advanced".
  - Generous spacing; section dividers.
- **Micro-interactions:**
  - Edited items wiggle; a wave animation plays on split.
  - Toasts appear after "Apply to all".
  - 50% snap on manual zoom targets.
  - Animated timeline zoom; the playhead position is restored when a project reopens.

---

## 4. Timeline and editing

| Feature | Behaviour |
|---|---|
| Tracks | Clip (yellow, with waveform), Zoom (purple), Layouts, Masks, Shortcuts, Captions, Flags. Every track uses the same rules: click empty space to add, drag edges to resize, drag the body to move, right-click → Disable/Remove/Duplicate, select to edit in the sidebar |
| Clip label | `Clip · 19s · ⏱1×` (duration and speed) |
| Zoom label | `Zoom · 🔍1.3× · Auto` (level and mode); disabled zooms are faded |
| Split | Hold ⌥ for the razor and click; **C** cuts at the playhead; ✂ button |
| Delete | **X** ripple-deletes back to the previous cut; right-click → Remove |
| Trim | Drag clip edges; the trimmed region shows as a bubble with ✂ that you click to restore; "Reset all trims & cuts" |
| Per-slice menu | Set speed (presets, plus Apply to all), Set volume (presets), Hide mouse cursor, Disable smooth mouse movement |
| Speed up typing | Typing segments are auto-detected and shown as suggestions; set the speed, then Apply / Apply to all typing parts |
| Edit by transcript | Delete words or sentences to cut the video; Remove filler words; Tighten pauses |
| Navigation | Pinch / ⌘-scroll / +− to zoom the timeline (animated, centred on the playhead); scroll horizontally; ←/→ ±0.5 s, ⇧←/→ ±1 s; loop playback; audio scrub mode |
| Selection | ⌘-click multi-select; copy/paste of zooms, layouts and slices; batch-edit selected zooms |
| Limits | Minimum slice 100 ms; minimum zoom 0.1 s; minimum layout 0.5 s |
| Undo/Redo | Full history; the playhead stays on the same source moment |
| Command menu | ⌘K runs any action or setting; ⌘/ shows the shortcut cheat sheet |
| Copy frame | ⌘C copies the current frame as an image |

---

## 5. Zoom system (signature feature)

- **Auto-zoom generation:**
  - Clicks are grouped in time and space ("click groups"), and each group becomes a zoom range (`isSystem: true`).
  - It can be turned off globally.
  - If the video starts inside a zoom, it begins already zoomed.
- **Modes:**
  - **Auto (`follow-click-groups`):** targets the clicks in the range and follows the cursor while zoomed, using `snapToEdgesRatio` so the frame doesn't pan past the content edges.
  - **Manual:** a mini-frame preview with a draggable purple target dot, percentage readout and a snap at 50%.
- **Zoom level:** a slider, with keys 0–9 setting it while hovering; *Apply to all*. Observed values range from 1.3× to 3.4×.
- **Instant animation:** a hard cut instead of an animated zoom.
- **Styles (v4):**
  - **Classic:** scale and pan the whole canvas.
  - **Glass Loupe:** a magnifier lens over a detail, keeping the context visible.
- **Clarity:** ML super-resolution keeps zoomed text sharp (recording at Retina resolution also helps).
- **Camera behaviour during zoom:** the camera bubble shrinks (default 0.7×) so it never covers the action.
- **Aspect ratio aware:** zooms re-aim automatically when the output ratio changes.
- **Motion:** the screen spring is set by the Screen animation style (*Focused* = snappy and readable; *Smooth* = fluid).

**Known gaps to beat:**
- Auto-zoom timing and default level can't be tuned; zooms start and end late.
- Clicks are the only trigger (no dwell or typing focus).
- Nothing for iOS recordings.

---

## 6. Cursor (✅ panel fully observed)

| Control | Options / default |
|---|---|
| Cursor size | slider + Reset (stored 0.5–1.5+) |
| Cursor style | horizontal swatch row of sets: macOS, macOS Tahoe (auto-selected on Tahoe), Touch (circle, for iOS), Figma pointer, Halloween, about 20 themed custom sets; previews on hover |
| Always use pointer cursor | "Don't change cursor, even if selecting text, etc." |
| Hide cursor if not moving | fades after 2000 ms idle |
| Loop cursor position | "Near the end of the video, cursor will move back to its initial position" |
| Hide cursor | global (per-slice hiding lives in the timeline) |
| Click effect | None / Circle / Ripple (+ Shockwave in some versions) |
| Click sound | None / Magic Mouse™ / MX Master™ (volume 0.25) |
| **Rotation ▾** | Rotate cursor (base angle slider); *Rotate while moving*: **Tilt** ("leans with fast horizontal movement, settling back upright at rest") or **Follow** (points in the direction of travel); Tilt amount |
| **Advanced ▾** | Stop cursor movement at end of video (slider; hides the reach for "Stop recording"); Remove cursor shakes (on) + threshold; Optimize cursor changes (on; suppresses rapid I-beam/pointer flicker) |
| Smoothing | Cursor animation style: Smooth / Medium / Rapid / None (spring presets); per-slice "Disable smooth mouse movement" |
| Quality | Known system cursors are swapped for high-resolution or vector versions; low-resolution app cursors fall back to the default arrow |

---

## 7. Background and frame (✅)

- **Type:** Wallpaper · Gradient · Color · Image · Unsplash.
  - **Wallpaper:**
    - ★ Favorites plus category pills (macOS, Spring, Sunset, Radiant, Energy, Iridescent, Midnight, Glassmorphism, Raycast…).
    - A thumbnail grid.
    - **Pick random wallpaper** button.
    - Default: macOS Tahoe Light.
  - **Gradient:** start and end points with colour stops (default `#3F37C9 → #8C87DF`).
  - **Color:** picker plus hex input (accepts pasted values; `#` optional).
  - **Image:** "Click to select, drop image, or press ⌘V while hovering."
  - **Unsplash:** in-app search.
- **Background blur** slider.
- **Padding** slider + Reset (0 = edge to edge; shown as %).
- **Rounded corners** (default 12 px).
- **Inset** toggle ("Add inset around the screen"): per-side inset with its own colour and opacity, live preview.
- **Shadow:**
  - Intensity slider + Reset (default 0.75).
  - **Classic / Directional**.
  - *Advanced shadow settings ▾*: Distance (25), Angle (90°), Blur (20).
- **Crop** (above the preview): drag handles, numeric values, a fixed-ratio lock, a 25/50/75% grid, browser-chrome auto-crop suggestions; cancel reverts.
- **Aspect ratio:** Auto, 16:9, 9:16, 1:1, 4:3, 3:4, 4:5.
  - **Reel safe-area overlay:** Off / Instagram / TikTok.
  - On a ratio change, layouts, captions and shortcuts reposition automatically.
- **Device frame** (iOS): auto-detected iPhone 11 → 17 Pro Max / Air, iPad Pro 11 / 12.9 (portrait and landscape); can be turned off.

---

## 8. Camera (✅ Camera Layout panel observed)

- **Hide camera** toggle.
- **Default layout:** Camera overlay · Split screen · Camera cutout (beta; background removed on-device). The timeline can also switch to Fullscreen camera or Screen only.
- **Layouts track:** layouts change over time with animated transitions, each optionally with its own size. A new layout defaults to fullscreen camera.
- **Camera position:** an **8-point grid** (corners plus edge midpoints) stored as a normalized point.
- **Camera aspect ratio:** 16:9 · 4:3 · 1:1 · 3:4 · 9:16.
- **Camera size** + Reset (default 0.35). *Camera size during zoom ▾*: shrink factor (0.7).
- **Camera rounded corners** + Reset (squircle → circle; 0.25).
- **Hide during silence:** the camera steps aside when you're not talking.
- **Mirror.**
- **Camera Style panel (v4):**
  - Colour grading (12 looks plus strength).
  - Custom **LUT import** and user grade presets.
  - Sharpen.
  - Camera crop.
  - **Face tracking** (keeps the face centred).

---

## 9. Audio (✅)

- **Microphone:** Mute toggle; audio mode **Standard / Noise reduction / Podcast (beta)** (on-device ML); stereo mode.
- **System audio** and **device audio:** mute and volume each.
- **Per-slice volume** (right-click a slice). The waveform reflects the volume, and can be shown smoothed or hidden.
- **Background audio:**
  - Category pills: **Lo-Fi / Commercial / Electronic / Instrumental**.
  - Track pills (e.g. Sunny Lo-Fi, Lean Groove, Bright Lounge…) with preview.
  - **Add background audio** (your own MP3/MP4).
  - Loops to fit; default volume 5%.
- **Click sounds** (see Cursor).
- **AI voiceover** (cloud): type a script, choose a voice, and it is placed on the timeline (`voiceOvers[]`).
- Export mixes to 2-channel audio.

---

## 10. Captions and transcript (✅)

- **Generate transcript:**
  - Method **Cloud** (better quality and word timings; the audio is deleted afterwards; falls back to local) or **Local** (Apple Speech on macOS 26, otherwise Whisper Base/Small/Medium).
  - **Language** dropdown or auto-detect.
  - Optional **vocabulary prompt**.
- **Caption display:** show/hide, size, font, colour, position; **line-by-line vs word-by-word** highlight; animations Appear / Fade in / Slide in.
- **Edit transcript** to fix typos.
- **Export .srt**, which respects cuts and speed changes.
- **Edit by transcript:** text-based video editing (see §4).

---

## 11. Keyboard shortcut overlay

- Shortcuts are detected automatically from the keystroke log. The panel is disabled when none were recorded.
- Show shortcuts toggle; label size; "Show single-key shortcuts" (off; typing runs are ignored heuristically).
- **Shortcuts track:** click to hide a single shortcut; right-click → hide all "⌘C"s, or hide all.
- Rendered as macOS **keycaps** (one cap per key, with symbol and name; "Space" spelled out; correct modifier order; Fn hidden for arrow and F-keys).

---

## 12. Animations and motion (✅)

- **Screen animation style:** Focused / Smooth + Reset.
- **Cursor animation style:** Smooth / Medium / Rapid / None + Reset.
- **Motion blur** slider ("Elements that are moving will have a cinematic motion blur effect applied"). It is applied separately to cursor movement, screen pan and zoom (separate amounts in the data).
- Springs are used for everything (see the §0.2 defaults). Animation blends correctly across cuts.

---

## 13. Masks and highlights

- **Mask track:** rectangles placed over a time range.
  - **Sensitive-data mask:** blur or solid fill; v4 **blends** by sampling the surrounding colour.
  - **Highlight:** dims everything except a rectangle (adjustable opacity).
- They can't overlap in time. Masks are static in time (they don't follow scrolling); a `dynamic-mask-tracker` helper suggests tracking is coming.

---

## 14. Presets

- **Presets ▾** in the editor:
  - Create from the current look (background, ratio, camera, cursor, animations…).
  - Apply with one click.
  - Set a **default preset** for new recordings.
- "Use last project settings as default for new recordings" (on by default).
- Portable `.screenstudiopreset` files with embedded images: File → Import preset; "Open in Finder" to share. Folder location is configurable.

---

## 15. Export

- **Format:** MP4 · GIF.
- **Resolution:** 720p · 1080p · 4K (GIF up to 1080p).
- **FPS:** 24 / 30 / 60.
- **Quality preset:** Studio · Social Media · Web · Web (Low).
- **GIF:** loop count, high-quality palette.
- **Destinations:** Save to file · Copy to clipboard (the file itself, so it pastes into Slack, Linear and similar) · Create shareable link.
- **Behaviour:**
  - MP4 and GIF settings are remembered separately.
  - Quick export reuses the last settings.
  - **Batch export** of several projects.
  - Export keeps running while you edit other projects.
  - Shows file path and size; optional "remove project after export".
- **Other outputs:** extract raw recording files (screen without cursor, camera, mic, system audio); .srt; current frame as PNG.
- **Performance:** hardware (Media Engine) encoding; multi-threaded mode (experimental); low-memory mode; preview quality modes.

---

## 16. Sharing (cloud)

- **Shareable link:** `screen.studio/share/<id>`.
  - Uploaded as 1080p60 MP4, max 30 min.
  - Opens in the browser automatically.
  - Consent prompt before the first upload.
- **Visibility:** Public, or Private (invite by email).
- **Share page:**
  - Player, title, view count (owner excluded; visibility can be toggled).
  - **Timestamped comments** (⌘↩ to post; anonymous allowed; comment visibility can be toggled).
  - Report button.
- **Manage links** dashboard (web).
- **Share project (beta):** send the full editable project (≤20 GB) as a link that opens in the app.

---

## 17. Settings (⌘,)

- **General:** hide Dock icon, projects folder, analytics opt-out.
- **Recording:** auto zooms, countdown, mic auto-gain, focus the window before recording (Accessibility), hide desktop icons.
- **Editing:** reuse last settings for new projects.
- **Shortcuts:** every global action can be rebound (start/stop, pause, flag, prompter, open picker).
- **Advanced:** skip certificate validation (VPN/proxy), diagnostics, low-memory export, multi-threaded export, reset window positions.
- **Experimental:** enhanced upload.

---

## 18. Default keyboard shortcuts

| Action | Key |
|---|---|
| Open recording picker | ⌥⌘↩ |
| Recording flag | ⌃⌥⌘F |
| Command menu / cheat sheet | ⌘K / ⌘/ |
| Save / Save As | ⌘S / ⌘⇧S |
| Cut at playhead / razor / ripple delete | C / hold ⌥ / X |
| Add mask | 4 |
| Zoom / layout tracks | 1 / 2 / 3 |
| Set zoom level (hover) | 0–9 |
| Sidebar panels | ⌘1…⌘9 |
| Copy frame | ⌘C |
| Step | ←/→ 0.5 s, ⇧←/→ 1 s |
| Close panel | Esc |

---

## 19. Business model (for reference)

- **Screen Studio pricing:**
  - $29/mo, or $108/yr ($9/mo), all features included.
  - No free tier.
  - 40% education discount.
  - 3 Macs per licence.
  - Lemon Squeezy billing.
  - Previously $89–229 one-time.
- Sign-in by email code, with legacy licence keys and SSO.
- **No team plan yet** (on their roadmap).

---

# Screen Playground — build plan

## MVP (parity with the core)

1. **Recorder (Swift + ScreenCaptureKit):**
   - Display, window and area capture with the cursor hidden.
   - Segmented fMP4 (crash-safe).
   - Mic and system audio.
   - Mouse, click and keystroke JSON logs; cursor image capture.
   - Countdown; control widget (pause/restart/stop).
   - Global shortcut; menu-bar item.
2. **Project format:** a `.playground` package that mirrors §0.1/§0.2 (slices, zoomRanges, layouts, masks; normalized geometry; spring configs). Version it from day one.
3. **Renderer:** a GPU compositor (Metal, or WebGPU in Electron/Tauri). The same code path renders the preview and the export:
   - background, padding, rounded corners, shadow;
   - spring-animated zoom and pan;
   - re-rendered cursor with smoothing and motion blur;
   - click effects.
4. **Auto-zoom** from click groups, plus the Auto/Manual zoom editor.
5. **Editor:**
   - Preview, right panels (Background, Cursor, Animations, Audio).
   - Timeline with Clip and Zoom tracks.
   - Split / trim / ripple delete / speed / volume; undo/redo.
6. **Export:** MP4 at 720p/1080p/4K and 30/60 fps, GIF, copy to clipboard.

## v1 (full parity)

- Camera: overlay, split, cutout; layouts track; the camera panel options in §8; shrink on zoom.
- Aspect ratios + crop + reel safe areas.
- Presets with import/export.
- Captions: local Whisper or Apple Speech; styling; .srt.
- Keyboard-shortcut overlay with keycaps and a shortcuts track.
- Masks and highlights.
- Speed up typing.
- Background music library.
- Click sounds.
- Quick-share widget; ⌘K command menu.
- iPhone over USB with device frames.
- Shareable links with comments and views.
- Edit by transcript (filler and pause removal).

## Differentiators (where Screen Studio is weak)

1. **Free tier and fair pricing** (they have no free tier and charge $29/mo monthly).
2. **Tunable auto-zoom:** lead-in and lead-out timing, default level, triggers beyond clicks (dwell, typing focus, window changes). Their users explicitly ask for this.
3. **Multi-clip projects and scenes** (their data model supports it; the UI doesn't): merge takes, add title and text slides, intro/outro.
4. **Annotations:** arrows, text callouts and spotlight shapes (paused on their roadmap).
5. **Tracking masks** that follow scrolling content; auto-detection of emails, keys and other PII.
6. **More export formats:** ProRes/MOV, WebM, transparent background, separate audio stems; faster exports.
7. **Better sharing:** no 30-min cap, embeds, passwords, folders, analytics, team workspaces. Never leak the owner's email in the share-page payload.
8. **Free camera placement** (not just 8 snap points) and per-side padding.
9. **Long-form performance:** timeline virtualisation for 30–60 min recordings.
10. **Cross-platform:** a Windows recorder (they have none planned).
