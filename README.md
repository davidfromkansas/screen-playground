# Screen Playground

A free, native macOS app for beautiful screen recordings: auto-zoom, a smooth re-rendered cursor, motion blur, wallpapers, a webcam overlay, and one-click MP4/GIF export. It is a clone of the feature set in [docs/FEATURES.md](docs/FEATURES.md).

**Website and download:** https://www.davidfromkansas.com/screenplayground/

## Let AI agents make demo videos

Screen Playground ships with `pgctl`, a command-line tool that AI agents (and you) can use to record and edit demos.
An agent writes a short script — click this, type that, show this caption — and Screen Playground performs it
with a smooth, real cursor while recording. It then auto-zooms on the clicks, adds the captions, cuts dead time
and exports an MP4.

**Set it up:** open Screen Playground › Settings › *Agents & command line* and click **Set Up…** next to your
agent app, or run one of these:

```bash
pgctl install --for claude-code      # Claude Code: adds a skill; it runs pgctl from its terminal
pgctl install --for claude-desktop   # Claude app chats: adds an MCP server (pgctl mcp)
pgctl install --for codex            # Codex CLI / IDE: adds an MCP server
```

(`pgctl` lives inside the app at `Screen Playground.app/Contents/MacOS/pgctl`; `pgctl install` links it into `~/.local/bin`.)

Then just ask: *"Make a 20-second demo of the signup flow on localhost:3000."*

- Allow **Screen Recording** and **Accessibility** for Screen Playground. Accessibility is what lets it click and type.
- While a demo runs, your cursor moves on its own. **Press Esc or move the mouse to stop it**; whatever was
  recorded so far is kept.
- It won't type into password fields, and it won't click when a popup is covering the target. If the app you're
  demoing needs a login, sign in to it yourself before the demo starts.
- Cloud-hosted agents can't use it: Codex cloud tasks, claude.ai on the web and Claude Code on the web run on
  remote machines and can't see your screen.

| Command | What it does |
|---|---|
| `pgctl run demo.json` | Perform a demo script while recording, then finalize and export it (`pgctl help script` explains the format). |
| `pgctl record start` / `mark` / `record stop` | Record while the agent drives the app itself, dropping caption and zoom marks. |
| `pgctl frames <project>` | Render frames and a contact sheet, so the agent can check its own video. |
| `pgctl edit <project>` | Add captions or zooms, cut, speed up, cut idle time, or change the look; changes are saved to the project. |
| `pgctl export <project> out.mp4` | Export to MP4, GIF or ProRes. |
| `pgctl mcp` | The same tools, served over MCP for apps without a terminal. |

Add `--json` to any command for machine-readable output; errors include a `code` and a suggested `fix`. The
agent skill is in [skills/screen-playground-demo/SKILL.md](skills/screen-playground-demo/SKILL.md).

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
