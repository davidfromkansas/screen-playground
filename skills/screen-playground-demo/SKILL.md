---
name: screen-playground-demo
description: Record polished product demo videos on this Mac with Screen Playground — write a demo script, let the app click and type through it while recording, then review frames, refine captions/zooms/cuts and export an MP4 or GIF. Use when asked to make a demo, walkthrough, screen recording, tutorial clip or launch video of an app or website.
---

# Making demo videos with Screen Playground

Screen Playground records a window, then edits automatically: zooms follow clicks, the cursor is smoothed,
idle time is cut and captions are added. You drive it with `pgctl` (add `--json` for machine-readable output).

## Workflow

1. **Check the setup** — `pgctl --json status`. Screen Recording and Accessibility must be `true`.
   If not, tell the user exactly which permission to allow in System Settings › Privacy & Security
   (for Screen Playground) and stop; never try to change system settings yourself.
2. **Make sure the thing to demo is ready** — the dev server is running, the page loads, test data exists.
   The demo uses the real screen, so ask the user before starting if they might be mid-task, and tell them
   the cursor will move on its own (Esc or moving the mouse stops it).
3. **Write a script** (`demo.json`, full format: `pgctl help script`):
   ```json
   {
     "target": { "app": "Safari", "url": "http://localhost:3000", "windowSize": [1280, 800] },
     "steps": [
       { "wait": 1, "caption": "Invite your team in seconds" },
       { "click": "Invite", "zoom": 2 },
       { "type": { "into": { "label": "Email" }, "text": "sam@example.com", "speed": 2 } },
       { "click": { "text": "Send invite", "role": "button" }, "caption": "They get a link right away" },
       { "wait": 1.5 }
     ],
     "output": { "file": "~/Movies/invite-demo.mp4", "res": 1080 }
   }
   ```
   Validate first: `pgctl run demo.json --check`.
4. **Run it** — `pgctl --json run demo.json`. It returns `project`, `output`, `duration` and `warnings`.
5. **Review** — `pgctl --json frames <project> --every 1.5` writes PNGs plus `contact-sheet.jpg`.
   Look at the contact sheet: are the captions readable, does each zoom frame the action, is anything
   private on screen?
6. **Refine** without re-recording — `pgctl edit <project> --output-time …` (times in the edited video):
   `--caption 2:4.5:"text"`, `--zoom 5:8:2.2` (or `:x,y` to aim it), `--cut 9:11`, `--speed 3:6:2`,
   `--clear-captions`, `--aspect 9:16`, `--preset "Name"`. Then `pgctl frames` again.
7. **Export** — `pgctl export <project> out.mp4 --res 1080` (`.gif` for a GIF, `--aspect 1:1` for social).
   Give the user the file path. The project also opens in the Screen Playground editor for hand-tuning.

## Writing good demos

- 15–45 seconds, one idea per caption, captions under ~8 words. Start with a `wait` + caption that says
  what the viewer will see.
- Target elements by visible text (`"click": "Save"`) or field label (`{ "label": "Email" }`); add
  `"role": "button"` or `"index": 2` when text repeats. Use `point` only as a last resort.
- Use `"speed": 2` on long typing, `"hold"` after a result you want viewers to see, and `"zoom"` on the
  click that matters most.
- Record a single window at a fixed `windowSize` so nothing else on screen leaks into the video.
- Use made-up example data. Password fields are refused by design — if the app being demoed needs a login,
  ask the user to sign in to it before the run.

## When something goes wrong

| error code | what to do |
|---|---|
| `permission` | Ask the user to allow the named permission for Screen Playground, then retry. |
| `target-not-found` | The message lists visible targets; fix the step's text/label or add a `wait` before it. |
| `target-covered` | A popup (autofill, password manager, notification) is in the way; ask the user to close it or turn it off for that site. |
| `secure-field` | Don't type passwords; ask the user to sign in to the app being demoed first, then skip the login steps. |
| `aborted` | The user pressed Esc or moved the mouse — ask before trying again. |
| `busy` | Another recording is running; `pgctl record status`, then `pgctl record stop` or `cancel`. |
| `app-not-running` / `app-not-installed` | Ask the user to open/install Screen Playground. |

## Free mode (when a script can't drive it)

`pgctl record start --app "Google Chrome" --cut-idle 1.5`, perform the actions with your own tools, drop
`pgctl mark caption "text"` / `pgctl mark zoom 2` at the right moments, then `pgctl --json record stop`.
