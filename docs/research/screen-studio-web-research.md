# Screen Studio (macOS) feature inventory for building a clone

Research date: 2026-10-11. Current version is **4.0.4** (4.0.0 shipped 2026-10-01).

**How this was gathered.** I fetched and read:
- all 66 articles in the guide (screen.studio/guide/*);
- the homepage, including pricing and FAQ;
- the roadmap, beta, use-case pages, Terms of Service and llms.txt;
- the full changelog. It is rendered client-side, so I pulled all 155 entries from the embedded data. They run from 2023-04 to 2026-10.

I also used archived older guides and pricing, the official Raycast extension source, the data behind a public share page, and third-party reviews and comparisons.

**Source keys** used in the citations below:
- **[HOME]** https://screen.studio
- **[CL]** https://screen.studio/changelog (version and date given inline)
- **[RM]** https://screen.studio/roadmap
- **[G:slug]** https://screen.studio/guide/slug

**About values in this report:**
- Where the guide gives no number, the value is marked *unspecified*.
- Third-party values are labelled as such. Some are from 2023–24 reviews and may be out of date.

---

## 0. Core architecture insight (the thing to copy)

**Cursor captured as data, not pixels.** Screen Studio records the screen **without the cursor** (ScreenCaptureKit, cursor hidden). Alongside the video it records precise mouse position, clicks, cursor type and keystrokes, then **re-renders the cursor in post**. Everything signature follows from this:
- smoothing
- cursor resize and restyle after recording
- high-resolution or vector system cursors at 4K
- auto-zoom on clicks
- hiding an idle cursor
- looping the cursor position
- motion blur
- keystroke overlays

([HOME] FAQ; archived guide "Custom macOS cursor size").

**Consequences:**
- If the user has a custom macOS pointer size, the recorder can fail to hide the real cursor, giving a **double cursor**. The app detects this and warns, linking to a fix (set the pointer to "Normal") ([CL 2.3.0], [CL 2.7.6]: warning can be dismissed with "Don't show it again").
- "Extract raw recording files" gives a raw screen file **without a cursor**. The webcam file has **no audio**; the mic is a separate file ([CL 2.18.1], [G:extracting-raw-recording-files]).
- Imported videos (MP4/MOV) get zooms and effects but **no cursor effects and no selfie camera** ([G:creating-project-from-existing-video]).

**Project format and storage:**
- Projects are `.screenstudio` packages, which appear as a folder to non-macOS tools, so users are told to zip them before sharing ([G:sharing-your-project]).
- Presets are `.screenstudiopreset` files that embed images ([CL 2.12.0]). They are stored in ~/Documents by default, and the location is customizable ([CL 3.2.0], [G:resolving-presets-access-issue]).
- Animation runs on a **spring physics model** ("Newtonian laws of motion": Tension, Friction, Mass) (archived [G:animations-motion]; [CL 2.16.6/2.16.7] mention "object mass" and spring simulation).

**Tech stack:**
- An **Electron** app (developer confirmed on HN, which mentions the Electron autoupdater). One tracker lists about 630 MB installed on Apple silicon (desktopinsights.com).
- Separate Intel and Apple-silicon builds.
- Hardware encoding on the Apple media engine.
- A local "Clarity" super-resolution model for sharp zooms ([HOME]).

**URL scheme:** `screen-studio://` with these commands, found in the Raycast extension (github.com/raycast/extensions/tree/main/extensions/screen-studio):
- `record-display`
- `record-window`
- `record-area`
- `finish-recording`
- `cancel-recording`
- `restart-recording`
- `toggle-recording-area-cover`
- `toggle-recording-controls`
- `open-projects-folder`
- `open-settings`
- `copy-and-zip-project` (copies a zipped project to the clipboard)

---

## 1. Recording

Sources: [G:new-recording], [G:recording-entire-display], [G:recording-single-window], [G:recording-area], [G:webcam-microphone], [G:managing-recording-in-progress], [G:recording-flag], [G:starting-finishing-the-recording], [G:speaker-notes-], [G:recording-system-audio], [HOME], [CL]

### Recording picker (modal)
- Opens automatically when the app launches.
- Reopen it with **⌥⌘↩ (Option-Command-Return)** or the menu-bar icon.
- Recent projects appear next to the picker; a folder button shows them ([CL 4.0.0]).
- Capture modes:
  - **Display**: hover a display and click to confirm. It is auto-selected if there is only one display ([CL 2.8.1]). Use Display mode for full-screen apps.
  - **Window**: click a window to make it active, or right-click the Window button to pick from a list. Notification and reminder popups are left out of the list ([CL 2.25.32]).
  - **Area**: drag a region or type exact dimensions.
    - Guide lines and a grid at 25/50/75% ([CL 2.25.18]).
    - The input form keeps away from the centre of the area ([CL 2.25.12]).
    - Shows the maximum dimensions ([CL 2.24.0]).
    - Area dimensions or aspect ratio can be saved ([CL 2.25.10]).
  - **Device**: an iPhone or iPad over USB (see §11).
- The **"Start recording" button sits next to the chosen window, display or area** ([CL 2.10.8]).
- The recorded window is **focused** before recording starts. This needs the Accessibility permission, with an explicit opt-in in recorder settings ([CL 2.10.8], [CL 2.16.6]).
- **Resize recorded window**: one click sets an exact size.
  - Presets include 1920×1080, 9:16 vertical, smaller sizes and 16:10 ([CL 2.6.2], [CL 2.6.4]; Dave Swift review).
- Unrecorded screen areas are **dimmed**, and this can be turned off ([CL 2.20.0]).
- A "Recording area cover" toggle exists (Raycast command).

### Inputs chosen in the picker
- **Camera**: pick a device and a floating preview appears.
  - The preview is not burned into the recording; content under it is still captured.
  - "Hide camera preview" is available from the camera menu and the context menu ([CL 3.4.7]).
  - A full-frame preview is shown before recording ([CL 3.4.7]).
  - Continuity Camera is supported (Dave Swift review).
  - Camera format options are **720p, 1080p, 4K** ([CL 3.4.5], [CL 3.2.2]); the ideal webcam FPS is set to 30 ([CL 3.4.10]).
  - A camera can be selected without a microphone, with a warning ([CL 2.22.14]).
- **Microphone**: pick a device.
  - A white level bar under the icon shows live input.
  - Stereo mic is supported ([CL 3.4.7]); the exported mic stream used to be mono ([CL 2.24.0]).
  - Auto gain control is **disabled by default**, with an option to enable it ([CL 2.25.7/2.25.8]).
  - It warns when the mic is muted because the laptop lid is closed ([CL 2.22.0]).
- **System audio**: all apps, or **selected apps** (a set; the rest is ignored). Requires macOS 13+ ([CL 2.16.7]).
- iPhone audio can be recorded from the device ([CL 3.2.0]).

### Picker settings (gear icon on the right)
- Show Speaker Notes
- Edit quick export settings
- "Show quick export widget after recording"
- Countdown (customizable)
- Global start/stop shortcut
- Hide desktop icons

### During recording
- **Recording control widget** shows the elapsed time, with Finish, Pause, Restart and Delete.
  - Right-click it and choose "Hide current recording control".
  - The widget is excluded from the capture (macOS 12.3+).
- **Pause and resume** in the same take, with a shortcut ([CL 3.2.0]).
- **Recording flag** (default **⌃⌥⌘F**) marks moments that show as flags on the timeline. Rebind it under Settings › Shortcuts › "Create recording flag".
- Four ways to stop:
  - the widget stop button;
  - the menu-bar icon (hidden by the notch on some MacBooks);
  - Dock icon › Finish Recording;
  - the global start/stop shortcut (set during onboarding).
- **Speaker notes / prompter**:
  - A floating notes window that is never recorded.
  - "Start Prompter" with a shortcut (⌘⌥…).
  - Settings: scroll speed (a faster option was added in [CL 3.4.4]), opacity and font size.
  - Visible in full-screen presentations ([CL 3.1.0]).
  - Disabled if ScreenCaptureKit is off.
- **Crash recovery**: the take is flushed to disk **every 2 seconds** and recoverable after power loss ([HOME]); there is also project recovery for missing data ([CL 3.2.2]).
- Low-disk-space warnings before and during recording ([CL 2.17.12], [CL 3.2.2]).
- The app asks before quitting during a recording or export ([CL 4.0.0]).
- The Enter-to-start shortcut is debounced so only one start signal is sent ([CL 3.0.0-3187]).
- Recording is single-session only: one session at a time is enforced ([CL 3.0.0-3181]).
- **Hide Dock icon** (Settings › General): hidden when no project or recording is open ([G:hiding-dock-icon]).
- **Notifications**: macOS blocks them by default. To capture them, enable System Settings › Notifications › "Allow notifications when mirroring or sharing display" ([G:capturing-notifications]).
- **macOS camera Reactions** (system feature) can leak into recordings; disable them via the green camera menu-bar icon. That menu also offers Background, Portrait and Studio Light ([G:reactions-], [G:camera-settings]).
- New recordings with no detected speech open with "Mute microphone" on ([CL 4.0.0]).
- New recordings are up to 2× smaller in v4 ([CL 4.0.0]).

### Settings › Recording
- "Create zooms automatically" (on by default) ([G:disable-automatic-zooms-]).

---

## 2. Editing (editor, timeline and tools)

Sources: [G:trimming], [G:speeding-up-the-video], [G:set-volume], [G:scrubber], [G:speed-up-typing-segments], [G:adding-a-mask-and-highlight], [G:command-menu], [G:cropping-the-recording], [G:aspect-ratio], [CL]

### Editor layout
- **Preview** in the centre:
  - Aspect-ratio picker above it.
  - Crop button above it.
  - Preview size is adjustable ([CL 2.25.14]).
- **v4 toolbar** next to the preview adds zooms, camera layouts and masks ([CL 4.0.0]).
- **Right sidebar** with panels; ⌘-number shortcuts open them (v4: **⌘5 Captions, ⌘7 Audio**, after Camera Layout and Camera Style were split) ([CL 4.0.0]). Panels named in the guides and changelog:
  - Background and Screen
  - Cursor
  - Camera Layout
  - Camera Style
  - Captions
  - Audio
  - Keyboard Shortcuts
  - Animation
  - Device frame
- Esc closes a custom sidebar panel; pressing it again returns to Background ([CL 2.25.14]).
- The sidebar and the timeline can each be hidden ([CL 2.11.1]).
- **Export** button at the top right; **Presets** button in the project.
- Project title in the top bar renames the file. Clicking outside commits the rename; a single click selects the whole name ([CL 2.10.4], [CL 2.21.1], [CL 2.20.0]).
- Projects reopen at the saved playhead position ([CL 4.0.0]).

### Timeline (stacked tracks)
- **Clip track**: a **yellow** bar showing length and speed.
- **Zoom track**: **purple** blocks.
- Camera **Layouts** track.
- **Mask** track (shortcut **4** activates it).
- **Shortcuts** track.
- Audio **waveform** (mic and system), lazily loaded ([CL 2.10.6], [CL 2.25.11]).
- **Flags** from recording.
- An empty timeline shows the tip "click or drag" ([CL 2.25.18]).
- There are digit shortcuts per track (1/2/3 for zoom and layout, per [CL 2.25.25]).

### Timeline navigation
- Zoom with the slider next to the scissors icon, **pinch**, **⌘+scroll** or **+/-**. Zoom is animated and centred on the playhead ([CL 2.21.0], [CL 3.0.0]).
- Scroll by trackpad swipe or mouse wheel; scrolling works during playback.
- An always-visible scrollbar is an option.
- Arrow keys during playback move 0.5 s, or 1 s with Shift ([CL 2.24.1]).
- Playback goes idle after 30 s of inactivity ([CL 2.25.16]).
- Loop mode.
- **Scrubber**: an audio-scrub mode above the timeline. Playback speed follows drag speed, and you can drag backwards.

### Cutting
- Hold **⌥ (Option)** for the **split/razor** tool, then click to split. Before 2.25.12 it was a toggle on S.
- **C** cuts at the playhead.
- **X** does a **ripple delete**: it removes the clip from the playhead back to the previous cut ([CL 2.25.12]).
- Right-click › Remove.
- Drag clip edges to trim. A trim shows as a **yellow bubble with a scissors icon**; click it to undo.
- Minimum clip length is **100 ms** ([CL 2.25.10]).
- The video can be **extended past the original length** ([CL 2.4.4]).
- "Reset all trims and cuts" ([CL 3.4.11]).
- Undo/redo keeps the playhead on the same source moment.
- Edited items "wiggle", with a wave effect on split ([CL 2.25.12]).

### Per-slice context menu (right-click a clip slice)
- **Set speed**: speed up or slow down from a preset list. Exact values are *unspecified*; at least 1.2× and above 2× exist per fixes. "Apply to all" was added in [CL 3.6.0].
- **Set volume**: from a preset list (values *unspecified*).
- **Hide mouse cursor**: an icon then appears on the slice.
- **Disable smooth mouse movement**: per slice, useful for dropdown menus.
- Slice settings are also editable in the sidebar ([CL 3.1.0]).
- Checkmarks show the current speed and volume.

### Selection and batch editing
- ⌘-click multi-select; copy/paste of zooms, layouts and slices; batch actions on several zoom ranges ([CL 2.25.16/2.25.18]).

### Speed up typing
- Typing segments are detected automatically and suggested on the timeline.
- Click one, set the speed slider, then choose "Apply suggestion" or **"Apply to all typing parts"** ([G:speed-up-typing-segments], [CL 3.0.0]).

### Edit by transcript (v4)
- Delete a sentence to cut it.
- **Remove filler words** (um, uh) offers cuts.
- **Tighten pause** shortens long pauses ([CL 4.0.0]).

### Crop
- **Crop** button above the preview.
- The crop tool supports drag handles, numeric values, a fixed crop aspect ratio and a grid at 25/50/75%.
- Crop is separate from the project aspect ratio.
- Closing without confirming reverts the crop.
- Chrome and Safari crop suggestions remove browser chrome ([CL 2.10.6]).
- History note: C used to open crop, but since 2.25.12 C cuts.

### Masks and highlights
- Shortcut 4 or the toolbar adds them.
- Click the mask track to add one, then set its size and highlight opacity.
- Types:
  - **Sensitive data mask**: in v4 it blends in by sampling the colour of what it covers.
  - **Highlight**: dims the rest of the frame.
- A mask and a highlight cannot share a frame.
- Masks are **static**: they do not follow scrolling content.
- User requests ask for multiple masks at once and auto-masking (hub.screen.studio).

### Command menu
- **⌘K** reaches all actions and settings in context, including export actions.
- Since [CL 3.4.10] it works outside the editor too.

### Other editing features
- **Keyboard shortcut list**: ⌘/.
- **Copy current frame as image**: ⌘C or the preview context menu.
- **Import video**: File › Create project from video… (MP4 and, since 3.2.0, MOV). Audio is included.
- Drag and drop a project file onto the editor or the menu-bar icon to open it ([CL 2.26.0]).

### Roadmap items not yet built [RM]
- **Planned**: multi-clip recordings (merge several recordings), full-text slides, enter/exit animations, create videos from screenshots, voice audio enhancement.
- **Paused**: annotations (click callouts and text).
- **In progress**: teams subscriptions, AI voiceover. The homepage already advertises AI voiceover, so it is partly shipped.
- **On beta**: AI voice cleanup.

---

## 3. Cursor

Sources: [G:cursor], [G:disable-smooth-mouse-movement], [G:hiding-the-cursor-in-specific-sections], [G:mouse-click-sound], [G:animations], [HOME], [CL]

### Cursor panel
- **Hide cursor** (global).
- **Cursor size**: a slider from real size upward. The range is *unspecified*.
- **Cursor type**: macOS or Touch (a circle, for iPhone and iPad).
- **Custom cursor sets**: a large library added in [CL 3.0.0]. Examples:
  - Figma cursors (high-resolution in [CL 2.18.1])
  - macOS Tahoe set, auto-selected on Tahoe ([CL 3.4.8])
  - Halloween set ([CL 3.5.0])
  - seasonal and Christmas sets ("Jingle all the way", 3.0.0-3202)
  - system cursor variants ([CL 3.4.7])
  - previews on hover ([CL 2.25.1])
  - fallback when a custom cursor is missing ([CL 3.2.3])
- **Always use default system cursor** keeps the arrow and ignores I-beam, pointer and similar changes.
- **Hide cursor if it's not moving**: the idle cursor fades out and returns on movement.
- **Loop cursor position**: near the end of the video the cursor glides back to its start, for seamless loops.
- **High-quality system cursors**: known cursors are swapped for high-resolution or vector versions when enlarged.

### Advanced cursor options
- **Rotate cursor while moving**: a slight tilt on fast moves ([CL 2.7.3]).
- **Stop cursor movement at the end of the video**, so you never see it reaching for the stop button.
- **Remove cursor shakes**, for jitter from accessibility tools ([CL 2.17.12]).
- **Optimize original cursor types**: minimises rapid cursor-type flicker; can be disabled ([CL 2.20.0]).
- (Older) disable the text-field I-beam (Dave Swift review).

### Smoothing and animation
- Smoothing is on by default.
- Cursor animation style:
  - v4 guide: **Smooth, Medium, Rapid, None**.
  - Older guide: Slow, Mellow, Quick, Rapid, plus an advanced spring "Customize" with **Tension, Friction, Mass**.
- "Smooth cursor animations" can be toggled off for accuracy.
- Per-slice "Disable smooth mouse movement".

### Click effects
- **Ripple** (a colourful ripple, redesigned in v4), **Circle** (added 2.25.25) and **Shockwave** (3.0.0), or off ([CL 2.24.1], [CL 2.25.25], [CL 3.0.0], [CL 4.0.0]).

### Click sound
- Cursor panel › "Click sound": choose from several sounds (previewable) and set the volume ([CL 3.3.0]).

### Hide cursor per section
- Right-click a slice › Hide mouse cursor.

### Motion blur on cursor
- See §9.

---

## 4. Zoom

Sources: [G:adding-editing-zooms], [G:auto-zoom], [G:manual-zoom], [G:instant-zoom], [G:disable-automatic-zooms-], [G:aspect-ratio], [HOME], [CL]

### Auto creation
- Zooms are created automatically from **click positions** during recording.
- Toggle: Settings › Recording › "Create zooms automatically".
- If a recording starts inside a zoom range, it begins already zoomed in rather than animating ([CL 2.11.2]).

### Zoom track
- Click the track to add a zoom; drag the edges to resize.
- Right-click › **Disable** (keeps the zoom but inactive) or **Remove**.
- Duplicate, slice (split) or copy/paste zooms ([CL 2.10.6], [CL 2.4.3], [CL 2.25.18]).
- Bulk-remove all zooms, handy before exporting raw footage to another editor (Dave Swift review).
- Duplicate zooms are blocked without enough space before the next one.
- Minimum zoom duration:
  - 1 s → 0.1 s in [CL 2.25.30];
  - 1 s for the camera layout → 0.5 s in [CL 2.25.27].

### Zoom settings panel (opens on click)
- **Zoom level** at the top: a slider. Keys **0–9** set the level while hovering ([CL 2.12.5]).
- **"Apply to all"** copies the zoom level to every zoom, with a toast ([CL 2.12.5], [CL 2.25.14]).
- **Mode**:
  - **Auto**: targets the click(s) inside the range and follows the cursor while zoomed. It does nothing if the range contains no click.
  - **Manual**: a frame preview with a **purple dot** to drag onto the target. It shows percentages and **snaps to 50% within ±1%** ([CL 2.25.12]).
- **Instant Animation** toggle: a hard cut-in with no animation ([G:instant-zoom], [CL 3.4.4]).
- (Older) "glide": a slow camera drift while zoomed (Dave Swift review).

### Zoom styles (v4)
- **Classic zoom** (pan and scale the whole frame).
- **Glass Loupe**: a magnifier lens over a detail, with the context left visible ([CL 4.0.0], [HOME]).

### Clarity
- On-device AI super-resolution ("6.5× upscale", trained on 5,000+ generated macOS and SwiftUI screenshots) keeps zoomed text sharp. Debanding is on-device too ([HOME], [CL 4.0.0]).

### Smart framing
- When zoomed, the webcam shrinks so it never covers the cursor; the default shrink is ~70% (Dave Swift review).

### Aspect-ratio-aware behaviour
- Zooms "re-aim" automatically when the aspect ratio changes ([HOME]).
- "Always keep zoomed in" for vertical (a cursor-following crop) existed until v4 and was **removed in 4.0** ([CL 4.0.0]).
- The background no longer moves on zoom ([CL 2.25.30]).

### Zoom animation speed
- Older presets: Slow, Mellow, Quick, Rapid.
- v4 screen animation: **Focused** (settles quickly, readable) vs **Smooth** (more fluid) ([G:animations]).

### User complaints about auto-zoom
- No way to customize default auto-zoom timing.
- Zooms start and end too late.
- Requests for zooms triggered by mouse wiggles, and a "cinematic zoom" style (hub.screen.studio/p/custom-settings-for-default-automatic-zoom-range).

---

## 5. Camera (webcam)

Sources: [G:camera], [G:dynamic-camera-layouts-], [G:camera-settings], [HOME], [CL 4.0.0], [CL 2.25.x]

### Camera Layout panel
- Hide camera.
- **Position**: corner presets; no pixel-perfect placement (Dave Swift review).
- Mirror.
- **Roundness**: from square to circle.
- **Size**.
- **Camera aspect ratio**: replaced "Shape" in v4. "Original" became 1:1; custom aspect ratios have existed since [CL 2.25.14].
- **Camera during zoom**: shrink size, or off to keep the size constant.
- A small webcam keeps a fixed distance from the edge regardless of padding ([CL 2.25.16]).

### v4 layouts (switchable along the timeline)
- **Fullscreen camera**, **Split screen** (side by side, or stacked in vertical videos), **Camera overlay**, **Screen only** and **Camera cutout** (beta: background removed on-device).
- Transitions animate automatically.

### Dynamic layouts
- Add them on the **Layouts track**, the same way as zooms.
- A new layout defaults to fullscreen; switch it to Default (overlay) or hidden.
- A custom layout can optionally have its own camera size ([CL 2.25.16]).
- Creating a layout moves the playhead to its middle.
- Layouts copy and paste.

### Camera Style (v4)
- **Color grading**: 12 built-in looks previewed on your own camera, a strength slider, **custom LUT import** and user-defined presets.
- **Sharpen** (no halos).
- **Camera crop** (keep part of the frame).
- **Face tracking** keeps the face centred.
- **Hide during silence**: the camera steps aside while you are not talking.

### macOS-level effects
- Portrait, Studio Light, Background and Reactions come from the green menu-bar camera icon.

### Requests and complaints (hub)
- "Camera Layout no longer independent in SS4?"
- Automatically hide the face while the mouse moves.

---

## 6. Audio

Sources: [HOME], [CL], [G:set-volume], [G:background-music], [G:recording-system-audio]

### Sources
- Microphone (mono or stereo), system audio (all apps or selected apps), iPhone audio, background music, AI voiceover, click sounds.

### Microphone audio mode (v4)
Replaces the old "Improve microphone audio" (noise reduction plus volume normalization, [CL 2.10.6], [CL 2.18.1]). Options:
- **Standard**
- **Noise reduction** (fans, keyboards, room)
- **Podcast (Beta)** (voice-forward)

Notes:
- All processing is local.
- Not available on Intel Macs or macOS 13 and earlier ([CL 4.0.0]).
- Old projects open in Standard.

### Other audio controls
- **Mute** per source (mic mute since [CL 2.13.0]; external audio mute in the sidebar, [CL 3.2.2]).
- **Per-slice volume**: right-click › Set volume, from a list ([CL 2.20.0]); the waveform reflects the volume.
- **Background music**:
  - Audio panel with a **built-in royalty-free library** (previewable, [CL 3.4.9], [CL 3.4.11]) or **"Add background audio"** (MP3 or MP4).
  - It loops to fit the video and is synced with the timeline.
- **AI voiceover**: generated from a typed script, with an editable voice. It is cloud-based: the typed text is sent ([HOME]).
- **Roadmap**: on-device "AI voice cleanup" (on beta) and "Voice audio enhancement" (planned).
- **Export audio**: 2 channels consistently ([CL 3.2.2]).
- **User request**: separate audio tracks on export (hub).

---

## 7. Captions and transcription

Sources: [G:captions], [CL 4.0.0], [CL 3.5.0], [HOME]

### Generating a transcript
- Captions are off by default.
- Open the Captions panel (⌘5 in v4) and press **Generate transcript**.
- This requires recorded mic audio. Built-in mic audio is allowed since [CL 2.22.0].

### Transcript method
- **Whisper** (local) with model sizes **Base**, **Small** or **Medium** (speed vs accuracy vs storage).
- **Apple Speech Recognition** (local; macOS 26+).
- On macOS 26+, **Whisper is removed** in v4.
- **Cloud transcription** (v4): uploads mic audio for better quality and word timings; the audio is deleted afterwards. It falls back to local if the cloud fails ([CL 4.0.3]).

### Options
- **Language**: auto-detect, or choose one manually.
- **Prompt** (optional): a vocabulary hint for product names and technical terms.

### Display and styling
- Hide or show, and caption size.
- v4: **font style, colour, position**; **line-by-line or word-by-word**; animations **Appear, Fade in, Slide in**.
- Word-by-word highlight (older); a request asks to turn the highlight off.

### Editing and export
- **Edit transcript** opens an editor to fix typos.
- **Export .srt**: since v4 it respects cuts and speed changes (fixed bug).
- Cut parts are skipped in the transcript ([CL 2.25.10]).
- Captions reposition for readability when the aspect ratio changes ([HOME]).

---

## 8. Keyboard shortcut overlay

Sources: [G:shortcuts], [CL 2.7.0], [CL 2.21.0/2.22.0], [CL 2.22.14], [CL 4.0.0]

### Basics
- Shortcuts are detected automatically. The panel is disabled if no keys were pressed.
- "Show shortcuts" toggle.
- **Shortcut labels size** slider.
- **Show single key shortcuts**: off by default. Rapid keystrokes (typing) are ignored heuristically.

### Shortcuts timeline
- Click an item to disable it.
- Right-click › "disable all 'X' shortcuts".
- Option to hide all ([CL 3.4.5]).

### Rendering
- v4 shows real **keycap** overlays: each key is its own cap with the Mac symbol and name.
- Space is shown as the word "Space".
- Ctrl is ordered correctly.
- Fn is hidden for arrow and F1–F12 keys.
- Ignores unknown keys on non-Latin layouts.

---

## 9. Animation and motion

Sources: [G:animations], archived [G:animations-motion], [CL]

### Motion blur
- On by default, with a strength slider.
- The old advanced split had three channels: **Cursor movement**, **Screen zooming in/out** and **Screen moving (pan while zoomed)**. This "Advanced motion blur settings" was **removed in v4**.
- Described as "optics-based"; a new engine arrived in [CL 2.24.1].
- Disabled in Performance preview mode.

### Cursor animation style
- Smooth, Medium, Rapid or None (v4).

### Screen animation
- Focused or Smooth (v4).

### Springs
- Older: a "Customize" option with **Tension, Friction, Mass**.
- "Glide" options were removed from the UI in [CL 2.21.1].

### Animation quality
- Zooms and cursor blend correctly across cuts ([CL 2.25.1]).

---

## 10. Background and styling

Sources: [G:background], [HOME], [CL]

### Background types
- **Wallpaper**:
  - macOS wallpapers (Sonoma, Sequoia, Tahoe, iPadOS 17);
  - 100+ wallpapers by Blue Pixel Studio, plus Raycast and Glassmorphism wallpapers;
  - categories, **favourites** and a **random** button ([CL 2.17.0], [CL 2.17.3]);
  - the default is "Tahoe Light" ([CL 3.5.0]).
- **Gradient**: generated from a chosen colour; reduced banding in v4.
- **Color**: hex input or picker; paste from the clipboard; "#" optional.
- **Image**: upload; falls back to the default wallpaper if the image is inaccessible.
- **Unsplash**: in-app search (v4).
- Background blur (Dave Swift review).

### Frame settings
- **Padding**: 0 means no background visible; shown as % in v4.0.2.
- **Rounded corners**.
- **Inset**: an inner frame with its own colour (real-time colour changes in [CL 3.4.10]).
- **Shadow**:
  - v4: **angle, distance, softness**.
  - Older: presets from flat to dramatic, plus advanced options.

### User request
- Independent per-side padding (hub).

---

## 11. iPhone and iPad

Sources: [G:recording-iphone-ipad], [G:iphone-mirroring], [HOME], [CL]

### USB recording
- Pick the device in the picker's **Device** menu, then "Trust this device", then "Prepare for recording screen".
- Keep the device unlocked and do not lock it during recording.
- USB-C to Lightning is recommended; docks may fail.
- Nothing is installed on the device.
- Device rotation is handled ([CL 2.24.1]).
- iPhone audio can be recorded ([CL 3.2.0]).

### Mockups
- The model and colour are **auto-detected**.
- The **Device frame** tab lets you change the frame or disable the mockup ([CL 2.23.0]).
- The frame list is chronological. It includes:
  - iPhone 11 through iPhone 17 Pro, 17 Pro Max and iPhone Air;
  - iPad Pro 11 and 12.9;
  - horizontal iPad.

### Limitations
- **No tap capture**, so **no auto-zoom** and no cursor.
- A Bluetooth mouse shows a circle cursor, but it is not smoothed.
- Use the Touch cursor style.

### iPhone Mirroring (macOS 15+)
- Record the Mirroring app in Window mode; device frame options are then available ([CL 3.5.0]).

---

## 12. Aspect ratios and social formats

Sources: [G:aspect-ratio], [HOME], [CL 3.0.0-3301]

### Ratio options
- **Auto** (source), **Wide 16:9**, **Vertical 9:16**, **Square 1:1**, **Classic 4:3**, **Tall 3:4**, and **4:5** (added 2025-02).
- Requested: 5:4 (hub).

### Adapting to a ratio change
- Zooms re-aim, layouts rearrange, and captions and shortcuts reposition.

### Reel mode
- Overlays the **Instagram** or **TikTok** UI as a safe-area preview (Off, Instagram, TikTok) ([HOME]).

---

## 13. Export

Sources: [G:exporting-the-video], [G:explanation-of-export-settings], [G:performance-settings], [G:extracting-raw-recording-files], [HOME], [CL], Dave Swift and Bitdoze reviews

### Export dialog
Opened from the Export button (top right) or the Export menu. Settings:
- **Format**: **MP4** or **GIF**.
- **Frame rate**: options include 24, 30 and 60. Default is 60 (Dave Swift review); max 60.
- **Output size**:
  - MP4: **720p, 1080p, 4K** (2160p is labelled "4k").
  - GIF: up to 1080p.
- **Quality / compression preset**: **Studio** (for an NLE), **Social Media**, **Web**, **Web (Low Quality)**. The names come from a review, not the guide.
  - Compression does **not** affect export time; FPS, resolution and format do (a 4K export takes about 4× longer than HD).
- **GIF**: loop count setting ([CL 3.4.0]); a high-quality palette mode; recommended for clips under 1 minute.
- Export file details (path, size) are shown ([CL 3.4.7]); the ⓘ icon shows the full path.

### Actions
- **Export to File**.
- **Copy to Clipboard** (the video file).
- **Shareable link**.
- Remove the project after export ([CL 2.10.6]).

### Settings memory and batching
- **MP4 and GIF settings are remembered separately**.
- "Quick export" reuses the last settings.
- **Batch export** of multiple projects asks for all save locations first ([CL 3.0.0]).

### Performance
- Export can run while editing other projects.
- Exporting stops preview playback.
- A low-memory export option exists ([CL 2.25.26]).
- An experimental **multi-threaded export** is 20–40% faster but has a rare corruption risk ([CL 2.22.14]).
- Speed history: about 25% faster ([CL 2.25.18]); "up to 4×" new engine ([CL 2.25.2]); **up to 3× faster** on Apple silicon in v4.

### Preview performance (menu next to Export)
- **Quality**: matches the export, including motion blur.
- **Performance**: no motion blur, pixelated, higher FPS.
- **Power Saving Mode**.

### Other export outputs
- **Extract raw recording files…** gives the separate screen (no cursor), webcam (no audio), mic and system-audio files.
- **Transcript .srt** export.
- **Copy current frame as image**.

---

## 14. Sharing and cloud

Sources: [G:shareable-links], [G:shareable-links-comments], [G:quick-share-widget-], [G:sharing-your-project], [HOME], [CL], public share page data

### Quick share widget
- Appears at the bottom-left after recording.
- Actions: **Share** (link), **Save** (file), **Copy** (clipboard), **Edit** (or double-click to open the editor).
- "Edit quick export settings" lives in the recording picker.
- You can rename the title before sharing ([CL 3.5.1]).
- An auto-save project option is available ([CL 3.0.0-3337]).
- Disable it with "Show quick export widget after recording".

### Shareable links
- URL form: `screen.studio/share/<8-char id>`; it opens in the browser automatically.
- **1080p, 60 fps, maximum 30 minutes**, raised from a lower cap in [CL 3.3.1].
- You are asked before the first upload.
- The link URL is previewed in the export dialog.

### Visibility and comments
- **Visibility**: public, or **private** (invite by email; only invitees can open) ([CL 3.4.4/3.4.5]).
- **Comments** ([CL 3.4.10]):
  - "Show comments" in the bottom menu or the left menu.
  - Set a username with the pencil icon; anonymous commenters are allowed.
  - **⌘↩** posts a comment pinned to the current timestamp (`atTime`, in seconds).
  - Comment visibility is configurable.

### View counts
- Views counter added in [CL 3.5.1]; the owner's own views are not counted ([CL 3.7.1]).
- View visibility is public or private.

### Other link features
- "Report video" button (moderation policy in the ToS).
- Manage links via the menu bar's **Manage Shareable Links**, which opens the dashboard › Shareable Links tab.

### Observed data model (public page)
- Fields: `id`, `title`, `createdAt`, `thumbnailUrl`, `videoUrl` (a plain **MP4 on Cloudflare R2** via presigned URL, 2 h expiry), `videoDuration` (ms), width and height, `visibility`, `commentsVisibility`, `views`, `viewsVisibility`, `comments[]` (`content`, `atTime`, `userName`, `userEmail`).
- **Weakness**: the page payload exposes the owner's account email publicly.

### Share project (beta, v4)
- Sends the whole editable project as a link that opens in Screen Studio; up to **20 GB** as a single download.
- Manual alternative: zip the `.screenstudio` file and send it by AirDrop or cloud storage.

### Gaps vs Loom and Tella
- No analytics beyond the view count.
- No embeds, password protection or library management; links are capped at 30 minutes (Tella blog comparison).

---

## 15. Presets

Sources: [G:creating-preset], [G:applying-preset], [G:sharing-preset], [CL]

- **Presets** button in the editor: name it, then "Create new preset". A preset captures the whole look: background, aspect ratio, camera position, cursor and more.
- **Apply**: Presets › click a preset.
- **Default preset** is applied to new recordings ([CL 2.20.0]).
- Settings › Editing › "**Use last project settings as default for new recordings**" is on by default ([G:managing-project-settings-for-new-recordings]).
- **Share**: preset settings › "Open in Finder", then send the `.screenstudiopreset` file (it includes images). Import is available from the menu bar.
- Storage location is customizable ([CL 3.2.0]). A Documents-folder permission is needed, otherwise presets fail to load.
- Separate defaults are handled for external-device recordings ([CL 3.0.0-3301]).
- v4 also has **colour-grade presets** for the camera and opens v3 presets.

---

## 16. App settings (Settings window, ⌘,)

Sources: various guides and changelog entries

- **General**:
  - Hide Dock Icon.
  - Default projects folder.
  - Analytics opt-out (also offered at first launch).
- **Recording**: Create zooms automatically; countdown; mic auto gain; Accessibility window focusing.
- **Editing**: Use last project settings as default for new recordings.
- **Shortcuts**: every global action is rebindable, including start/stop, Create recording flag, pause and prompter toggle.
- **Advanced**:
  - Skip network certificate validation (for proxy, VPN and antivirus problems).
  - Share diagnostics info (version, macOS, Mac specs, camera and mic names).
  - Reduce export memory.
  - Multi-threaded export (experimental).
  - Reset all windows to default positions ([CL 3.0.0-3337]).
- **Experimental**: Enhanced shareable links upload settings.
- **View**: always show the timeline scrollbar; show or hide sidebar label tips.

---

## 17. Projects and files

Sources: [G:saving-your-project], [CL]

### Saving
- **⌘S** saves to the default folder; **⌘⇧S** is Save As.
- **Autosave** ([CL 2.25.10]).
- **Each save keeps a backup** of the previous version (v4).
- "Date modified" is updated on save.

### Opening and finding projects
- File › **Open recent** (also from the Dock icon right-click; stale entries are pruned).
- File › **Show previous projects** opens the projects folder.
- Recent projects also appear next to the recording picker (v4).

### Closing and removing
- **Close modal** offers Save or Delete. Delete is only offered for an unedited new recording.
- "Remove project" moves the project to the Trash.

### Finder integration (v4)
- Finder and Quick Look show **previews** of `.screenstudio` files.

### Compatibility
- v4 projects do not open in v3.
- v3 zooms may shift when opened in v4.

### Name validation
- Characters such as "#" used to break projects; this is now validated.

---

## 18. Keyboard shortcut reference (default)

Sources: guides and changelog

| Action | Shortcut |
|---|---|
| Open recording picker | ⌥⌘↩ |
| Start/stop recording (global) | user-set during onboarding |
| Recording flag | ⌃⌥⌘F |
| Pause | user-configurable |
| Prompter start/stop | ⌘⌥… (exact key truncated in the guide) |
| Command menu | ⌘K |
| Shortcut cheat sheet | ⌘/ |
| Save / Save As | ⌘S / ⌘⇧S |
| Settings | ⌘, |
| Cut at playhead | C |
| Split tool (hold) | ⌥ |
| Ripple delete | X |
| Mask track | 4 |
| Zoom / layout tracks | 1, 2, 3 (implied by a shortcut-conflict fix) |
| Set zoom level while hovering | 0–9 |
| Sidebar panels (v4) | ⌘1–⌘7 (⌘5 Captions, ⌘7 Audio) |
| Copy current frame | ⌘C |
| Post comment on a share page | ⌘↩ |
| Step during playback | ←/→ (0.5 s), ⇧←/→ (1 s) |
| Close sidebar panel | Esc |
| Multi-select | ⌘-click |
| Zoom the timeline | ⌘+scroll, pinch, or +/- |
| Hide / minimize app | standard macOS shortcuts |

---

## 19. Pricing and licensing

Sources: [HOME] #pricing and FAQ; ToS https://screen.studio/legal/terms-of-service; archived pricing (web.archive.org, 2025-06); Dave Swift and Bitdoze reviews

### Current pricing
- One plan, with **every feature included**:
  - **Yearly**: **$9/mo**, billed **$108/yr** ("Save 69%").
  - **Monthly**: **$29/mo**.
- Listed inclusions: export up to 4K at 60 fps, shareable links, cloud transcript, sharing projects, new features as they ship.
- **No free tier.** You can download and use the app, but early reviews say export was gated.
- **40% education discount**: automatic with a university email, otherwise send proof.
- **Fees are non-refundable** (ToS).
- Payment is through **Lemon Squeezy** (merchant of record). Subscriptions are managed at app.lemonsqueezy.com/my-orders.
- **Affiliate program**.

### Devices
- The archived 2025 pricing said **3 personal macOS devices** per subscription.
- The ToS says access is "restricted to a specified number of devices… as detailed in an Order".
- Device management: dashboard › Device tab › "Disconnect device". The old device is not needed.

### Pricing history
- **2023**: one-time **$89** for 1 device or **$189** for 3 devices, with 1 year of updates.
- **2025**: also "Pay once" at about **$229**, including 1 year of updates; optional renewal at **$109/yr**.
- **Now**: subscription only. Legacy one-time licenses still work and can be renewed for updates.

### Licensing and activation
- **Email-code** sign-in, which replaced license keys. Legacy keys still go in a field at the bottom of the activation window.
- Lost-key reminder page.
- License status is shown in the menu bar.
- Expired licenses get a dedicated screen; the app can still be used at the old version.
- Refunded subscriptions are deactivated.

### Teams
- **No team plan yet.** "Teams subscriptions architecture" is in progress on the roadmap: the owner invites members, who sign in and auto-activate. Team owners can share presets manually.
- Third-party estimate: about $540/yr for 5 seats on yearly billing.

---

## 20. Platform and requirements

Sources: [G:system-requirements], [G:installing-screen-studio], [G:setting-up-permissions], [HOME]

### Requirements
- macOS **Ventura 13.1+** recommended.
- **Apple M1+** recommended; Intel MacBook Pro 2018+ and MacBook Air 2020+ are supported.
- **8 GB RAM** minimum.
- Separate Apple-silicon and Intel downloads; the site detects the CPU. There is an architecture check ([CL 3.4.2]).
- **Intel limits**: some features are missing, including the mic audio modes.
- Feature gating by OS version:
  - macOS 13+: system audio.
  - macOS 15+: iPhone Mirroring.
  - macOS 26+: Apple Speech.
- **Windows: not planned.**

### Permissions requested at first launch
- Accessibility, Camera, Microphone and Screen Recording. Each opens System Settings with toggles.
- Documents folder access is needed for presets.

### Distribution and channels
- DMG with drag-to-Applications.
- Electron autoupdater with its own UI. The developer has said it checks every 3 hours and checking also downloads the update.
- **Beta channel** (screen.studio/beta).
- Feature hub: hub.screen.studio. Telegram group.
- "Email me a link" download flow for mobile visitors.

### Privacy model
- "Offline first": recording, transcription, voice enhancement, face tracking, cutout, upscaling and encoding are all local.
- Cloud is opt-in: shareable links, shared projects, cloud transcription and AI voiceover. Users are told at the point of choice.
- Analytics can be turned off; the site uses Plausible.
- Note: the FAQ still says it "never sends data about your recordings to servers", which is inconsistent with the cloud features.

---

## 21. UX patterns worth copying

1. **Zero-config polish.** Defaults produce a finished video: auto zooms, a smoothed and enlarged cursor, a wallpaper with padding, shadow and rounded corners, motion blur, and the last project's settings reused. Advanced options are hidden behind "Advanced" disclosures.
2. **Timeline as a stack of semantic tracks.** Clips, zooms, layouts, masks, shortcuts and flags all use the same model: click to add, drag edges, right-click to Disable or Remove, select to edit in the sidebar. Colour-coded: yellow clips, purple zooms.
3. **Post-hoc everything.** Cursor, camera layout, aspect ratio, zoom target, captions and masks are all editable after recording because raw streams and event data are kept separately.
4. **Recording picker with the action next to the target.** Mode buttons, device menus, a Record button placed beside the chosen window or area, a dimmed unrecorded area, exact-size window resizing and guide grids.
5. **Post-record fast path.** The quick share widget (Share, Save, Copy, Edit) means no editor is needed for quick loops.
6. **Keyboard-first.** ⌘K command menu, ⌘/ cheat sheet, single-key editing (C, X, Option, 4, 0–9).
7. **Micro-interactions.** Wiggling edited items, wave-like split animation, toasts after "apply to all", snapping to 50%, animated timeline zoom, fading time marks.
8. **Safety nets.** Two-second disk flush, crash recovery, autosave with backups, quit prevention during recording or export, disk-space checks, a double-cursor warning and friendly error codes.
9. **Mac-native integration.** Menu-bar app, Dock menu, Finder and Quick Look previews, a URL scheme with a Raycast extension, clipboard export, drag and drop of projects.

---

## 22. Known weaknesses and gaps (opportunities for a clone)

### Platform and price
- Mac-only, closed source.
- No free tier.
- $29/mo monthly pricing is criticised (Product Hunt newsletter 2026, Substack review, Tella and Docsie comparisons).

### Editor depth
- A single video track: no multi-clip merge (still planned), no text slides, no annotations or arrows (paused), no intro/outro animations, no picture-in-picture of other media.
- Reviewers call the editor "intentionally minimal".
- Not suited to long-form: timeline crowding past about 10 minutes; the developer admits auto-animation on 30–60 minute videos strains performance.

### Export
- Historically slow: about 3× real-time on an M1 in early reviews (Bitdoze, Dave Swift), and long GIF times.
- Recurring bugs: stuck at 95%, audio distortion, failures with muted audio (see [CL 3.2.x], [CL 3.4.4]).
- Formats are MP4 and GIF only. No ProRes, WebM or MOV export, and no transparent-background export.

### Auto-zoom
- Click-only triggers; no tuning of auto-zoom timing or default level; zooms start or end late (hub request).
- Nothing on iOS recordings, since taps are not captured.

### Masks
- Static: they do not track scrolling content; no auto-detection of sensitive data; a mask and a highlight cannot share a frame.

### Camera
- Corner presets only, no free positioning (older review); v4 users report layouts are no longer independent.

### Sharing
- 30-minute cap.
- Minimal analytics.
- No embeds, passwords, folders or team workspace.
- The public share-page payload exposes the owner's email.

### Collaboration
- No real-time collaboration.
- Project sharing is beta, and file-based sharing needs manual zipping.

### Regressions in 4.0
- Removed "Always keep zoomed in", "Snap to edges" and advanced motion blur settings; Whisper is gone on macOS 26.
- Hub bug reports: SS4 export quality, background glitch over the recording (fixed 4.0.4), cursor size in presets changed.
- v4 projects are not backward compatible with v3.

### Setup friction
- Four system permissions.
- Double cursor with a custom pointer size.
- Network and certificate activation problems behind VPN or antivirus.
- Documents-folder permission needed for presets.
- Intel Macs lack the newer audio features.

### Competitors as a reference
- **Cap**: open source, Mac and Windows, free tier with 5-minute links, paid plans from $29/yr; less cursor polish, no motion blur, and one source says it lacks manual timeline zoom.
- **FocuSee**: Mac and Windows; $49.99/yr or $199.99 lifetime.
- **Tella**: web and desktop; editable auto-zooms with hosted pages, analytics, passwords and embeds; from $13 per user per month.
- **Screenity**: free GPL Chrome extension; cursor highlight and spotlight work only inside Chrome.

Sources: tella.com/blog/best-screen-recorders-with-automatic-zooms-and-hosted-sharing; docsie.io comparisons; openalternative.co/compare/cap/vs/screenity.

---

## 23. Feature timeline (2024–2026)

| Date | Version | Highlights |
|---|---|---|
| 2024-02 | 2.20 | per-clip volume; option to disable dimming of the unrecorded area; delete on exit |
| 2024-03 | 2.22 | custom projects folder; shortcuts timeline; single-key shortcuts; ⌘-scroll timeline zoom |
| 2024-05 | 2.22.14 | experimental multi-threaded export |
| 2024-06/07 | 2.23–2.24 | Sequoia wallpapers; option to disable device mockup; Ripple click effect; device rotation; new motion blur and animation engine |
| 2024-07 | 2.25.1 | ⌘K command menu; iPhone 15 bezels; cutting in the middle of a zoom |
| 2024-08 | 2.25.2 | new export engine (up to 4× faster) |
| 2024-08 | 2.25.10 | autosave; saved area dimensions; auto gain control off |
| 2024-08/09 | 2.25.12–2.25.18 | Option-hold split, C to cut, X ripple delete; crop and area grids; custom webcam aspect ratio; MP4 import; copy frame; multi-select; copy/paste |
| 2024-09 | 2.25.25 / 2.25.30 | Circle click effect; iPad Pro 12.9 and horizontal iPad mockups; 0.1 s minimum zoom |
| 2024-12 | 2.26 / 3.0.0 | **Shareable links, dynamic camera layouts, quick share widget, custom cursor sets, speed-up typing, command menu, batch export**, Shockwave effect, drag-and-drop |
| 2025-02 | 3.0 updates | 4:5 aspect ratio; license management UI |
| 2025-03 | 3.1 | sensitive-data masks and highlights; per-slice cursor hiding |
| 2025-04 | 3.2 | pause/resume; iPhone audio; MOV import; custom preset location |
| 2025-05 | 3.2.2 | 1080p and 4K camera |
| 2025-06 | 3.3 / 3.4.0 | click sounds; 30-minute links; background audio; Tahoe wallpapers; GIF loop count |
| 2025-07 | 3.4.4–3.4.6 | private links; instant zoom; 720p/1080p/4K camera formats; background music library |
| 2025-08 | 3.4.7 / 3.4.8 | stereo mic; export file details; Tahoe cursors; iPhone 16 mockups |
| 2025-09 | 3.4.9 / 3.4.10 | built-in music library; **comments on links**; command menu everywhere |
| 2025-10 | 3.4.11 / 3.5 | Glassmorphism wallpapers; iPhone 17 and Air mockups; **Apple Speech transcripts**; iPhone Mirroring; "magnetic multifunction button"; Halloween cursors |
| 2025-11 | 3.5.1 | link view counter |
| 2026-01/02 | 3.5.2 / 3.6 | iPhone 17 Pro Max mockup; "Apply to all" for slice speed |
| 2026-05 | 3.7.1 | audio fixes; views exclude the owner |
| 2026-10-01 | **4.0** | **Glass Loupe, camera cutout (beta), edit by transcript (filler and pause removal), split screen and 5 layouts, face tracking, hide during silence, colour grading with 12 looks and LUTs, AI sharpening of zoomed text, up to 3× faster exports, Finder previews, recent projects in the picker, keycap shortcut overlays, caption styling and animations, cloud transcription, toolbar, camera crop, Unsplash, blending masks, share project (beta), save backups, mic audio modes (Standard / Noise reduction / Podcast)** |
| 2026-10 | 4.0.2–4.0.4 | padding in %, webcam quality, local transcript fallback, 4K background-over-recording fix |

Earlier, 2023: trim and speed (2.4), area recording and new picker (2.5.7), clipboard export (2.6), shortcuts overlay (2.7), inset (2.8), waveform and audio enhancement (2.10.6), preset file format (2.12), idle hide and loop cursor (2.14), system audio and iOS recording (2.15), new wallpapers (2.17), speaker notes and precise crop and raw file extraction (2.18.1).

---

## Values not found in public sources

These would need hands-on verification in the app:
- the exact zoom-level range and default;
- the cursor-size range and default;
- the speed and volume preset lists;
- padding, roundness and shadow numeric ranges and defaults;
- the countdown durations;
- the full export frame-rate list (24, 30 and 60 are confirmed; others unknown);
- the export bitrates behind each quality preset.

Third-party sources (TemperStack) mention items such as a "Smoothness 50%" setting and High/Medium/Low quality. These do not match the official documentation, so I excluded them.
