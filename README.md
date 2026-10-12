# Screen Playground

A free, native macOS app for beautiful screen recordings: auto-zoom, a smooth re-rendered cursor, motion blur, wallpapers, a webcam overlay, and one-click MP4/GIF export. It is a clone of the feature set in [docs/FEATURES.md](docs/FEATURES.md).

## Build and run

Requires macOS 15+ and Xcode 26+. You also need `xcodegen` and `ffmpeg`/`jq` (the last two are only for the end-to-end tests): `brew install xcodegen ffmpeg jq`.

```bash
make run        # generate the Xcode project, build, launch
make test-fast  # pure-Swift unit tests (seconds)
make test       # all package tests incl. Metal render + export
make e2e        # headless persona scenarios → MP4s checked with ffprobe
```

On first launch, grant **Screen Recording** in the window that appears.
- Microphone, Camera, Accessibility and Input Monitoring are optional.
- Debug builds are ad-hoc signed, so macOS may ask for Screen Recording permission again after a rebuild.
- To make the grant stick, set a signing identity in `project.yml`, for example a free Apple Development certificate (Xcode › Settings › Accounts).

## How it works

- **Record raw, render in post.**
  - ScreenCaptureKit records the screen *without* the cursor into crash-safe fragmented movies.
  - Mouse moves, clicks, keys and cursor images are logged as JSONL.
- **Edit non-destructively.** All editing is project state (`project.json` inside a `.screenplayground` package).
- **Deterministic motion.** Spring physics baked at 960 Hz drive the cursor and camera. One Metal compositor renders both the preview and the export, so what you see is what you export.

| Package module | Role |
|---|---|
| `PlaygroundCore` | Project format, typed source/output time, bundle I/O |
| `Timeline` | TimeMap (cuts/speed), edits, undo history, auto-zoom |
| `Motion` | Springs, cursor processing, camera path |
| `Composition` | Scene evaluator and layout → `FrameDescription` |
| `Render` | Metal compositor (shaders compiled at runtime), cursor art, wallpapers |
| `Media` / `Export` | Decoding, audio composition, MP4/GIF/ProRes export |
| `Capture` | Recorder: SCStream, mic/camera, event tap, recovery |

`pgctl` is a headless CLI: `make-fixture`, `export` (with `--aspect`, `--cut`, `--speed`, `--auto-zoom`, `--preset`), `render-frame` and `info`.

## Keyboard shortcuts

- **Anywhere:** ⌥⌘↩ record/stop · ⌥⌘P pause · ⌃⌥⌘F flag.
- **Editor:**

  | Key | Action |
  |---|---|
  | Space | Play |
  | C | Split |
  | X | Ripple delete |
  | Z | Add zoom |
  | M | Add mask |
  | ←/→ | Step |
  | ⌘C | Copy frame |
  | ⌘Z / ⇧⌘Z | Undo / redo |
  | ⌘E | Export |
