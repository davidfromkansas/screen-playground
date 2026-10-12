/// `pgctl help script`: the demo script reference (kept short enough for an agent to read in one go).
enum ScriptHelp {
    static let text = #"""
    DEMO SCRIPTS — `pgctl run demo.json`

    Screen Playground opens the target, records its window, performs each step with a real (smoothly
    animated) cursor and keyboard, then finalizes: auto-zoom on clicks, your captions, idle time cut.
    Press Esc (or move the mouse) to stop; the partial recording is kept.

    {
      "target":  { "app": "Safari", "url": "http://localhost:3000", "title": "optional", "windowSize": [1280, 800] },
      "style":   { "preset": "My Preset", "aspect": "16:9" },
      "options": { "preRoll": 1.5, "cutIdle": 1.5, "settle": 0.5, "typingSpeed": 14, "maxDuration": 180 },
      "steps": [
        { "click": "Sign up", "caption": "Create an account in seconds" },
        { "type": { "into": { "label": "Email" }, "text": "maya@example.com", "speed": 2 } },
        { "click": { "text": "Create account", "role": "button" }, "zoom": 2.2 },
        { "wait": 1.5, "caption": "You're in" }
      ],
      "output":  { "file": "~/Movies/signup-demo.mp4", "res": 1080, "fps": 60, "quality": "social" }
    }

    target   app: name or bundle ID. url: opened in that app first. windowSize: resize before recording.
    steps    exactly one action each:
               click / doubleClick / rightClick / hover: a target (see below)
               type:   "text"  or  { "text", "into": target, "replace": true, "submit": true, "speed": 2 }
               key:    "cmd+k", "return", "esc", "shift+tab", "down", "f5"
               scroll: "down"  or  { "direction": "up|down|left|right", "amount": 5, "at": target }
               wait:   seconds (0–30), kept in the video
             optional on any step: "caption": "text" (shows until the next caption),
             "zoom": 1.1–4 (zoom level for this click), "hold": seconds (pause that is never cut)
    targets  "Sign up"                          visible text (button, link, menu item, heading…)
             { "label": "Email" }              a field by its label or placeholder
             { "text": "Save", "role": "button", "index": 2 }   roles: button link field checkbox tab text heading
             { "point": [x, y] }               window coordinates, last resort
    style    preset: a preset saved in the editor. aspect: auto 16:9 9:16 1:1 4:3 3:4 4:5
    options  cutIdle 0 keeps idle time. typingSpeed in characters/second.
    output   file .mp4/.gif/.mov (optional — the project is always saved and can be exported later)

    Tips: check the script with `pgctl run demo.json --check`; keep demos 15–45 s with one idea per caption;
    use test data only (password fields are refused); review with `pgctl frames <project>` and refine with
    `pgctl edit`, then `pgctl export`. If a target isn't found, the error lists what is visible.
    """#
}
