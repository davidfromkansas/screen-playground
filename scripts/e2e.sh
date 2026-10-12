#!/usr/bin/env bash
# Headless end-to-end checks of the persona scenarios (see docs/qa/scenarios.md).
# Each scenario edits a fixture recording with pgctl and must end in a shareable MP4.
set -euo pipefail

PGCTL="${1:-build/DerivedData/Build/Products/Debug/pgctl}"
OUT="${E2E_OUT:-$(mktemp -d)/e2e}"
mkdir -p "$OUT"
pass=0; fail=0

check_mp4() { # file width height fps min_duration max_duration
  local f="$1" w="$2" h="$3" fps="$4" dmin="$5" dmax="$6"
  local probe; probe=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name,width,height,r_frame_rate,color_primaries \
    -show_entries format=duration -of json "$f")
  local codec width height rate dur prim
  codec=$(jq -r '.streams[0].codec_name' <<<"$probe"); width=$(jq -r '.streams[0].width' <<<"$probe")
  height=$(jq -r '.streams[0].height' <<<"$probe"); rate=$(jq -r '.streams[0].r_frame_rate' <<<"$probe")
  prim=$(jq -r '.streams[0].color_primaries' <<<"$probe"); dur=$(jq -r '.format.duration' <<<"$probe")
  local faststart; faststart=$(head -c 200 "$f" | grep -c moov || true)
  local ok=1
  [[ "$codec" == "h264" ]] || { echo "  codec=$codec"; ok=0; }
  [[ "$width" == "$w" && "$height" == "$h" ]] || { echo "  size=${width}x${height} expected ${w}x${h}"; ok=0; }
  [[ "$rate" == "$fps/1" ]] || { echo "  fps=$rate"; ok=0; }
  [[ "$prim" == "bt709" ]] || { echo "  primaries=$prim"; ok=0; }
  [[ "$faststart" -ge 1 ]] || { echo "  not faststart (moov not at front)"; ok=0; }
  awk -v d="$dur" -v a="$dmin" -v b="$dmax" 'BEGIN { exit !(d >= a && d <= b) }' || { echo "  duration=$dur not in [$dmin,$dmax]"; ok=0; }
  return $((1 - ok))
}

run() { # name, command...
  local name="$1"; shift
  if "$@" >/dev/null 2>"$OUT/$name.log"; then echo "✔ $name"; pass=$((pass + 1)); else echo "✘ $name"; cat "$OUT/$name.log"; fail=$((fail + 1)); fi
}

FIX="$OUT/Fixture.screenplayground"
rm -rf "$FIX"
"$PGCTL" make-fixture "$FIX" --duration 8 >/dev/null

# E1 Maya — zero-edit demo: auto zooms, default look, 1080p60 Social.
e1() { "$PGCTL" export "$FIX" "$OUT/E1-demo.mp4" --auto-zoom --res 1080 --fps 60 --quality social && check_mp4 "$OUT/E1-demo.mp4" 1920 1080 60 7.9 8.1; }
run "E1 zero-edit demo (1080p60)" e1

# E2 Maya — vertical cut: 9:16, trim start/end, 2x section.
e2() { "$PGCTL" export "$FIX" "$OUT/E2-vertical.mp4" --auto-zoom --aspect 9:16 --cut 0:1 --cut 7:8 --speed 3:5:2 --res 1080 --fps 30 \
       && check_mp4 "$OUT/E2-vertical.mp4" 1080 1920 30 4.9 5.1; }
run "E2 vertical cut for socials (9:16, trims, 2x)" e2

# E3 Maya — quick share at 720p web quality.
e3() { "$PGCTL" export "$FIX" "$OUT/E3-quick.mp4" --res 720 --fps 30 --quality web && check_mp4 "$OUT/E3-quick.mp4" 1280 720 30 7.9 8.1; }
run "E3 quick share (720p web)" e3

# E6 Leo — small bug repro: ripple-delete a section, Web (Low), 720p.
e6() { "$PGCTL" export "$FIX" "$OUT/E6-bug.mp4" --cut 2:4 --res 720 --fps 30 --quality webLow && check_mp4 "$OUT/E6-bug.mp4" 1280 720 30 5.9 6.1 \
       && [[ $(stat -f%z "$OUT/E6-bug.mp4") -lt 2000000 ]]; }
run "E6 bug repro (cut, small file)" e6

# E8 Priya — square loop + GIF.
e8() { "$PGCTL" export "$FIX" "$OUT/E8-loop.mp4" --aspect 1:1 --cut 6:8 --res 1080 --fps 60 && check_mp4 "$OUT/E8-loop.mp4" 1080 1080 60 5.9 6.1 \
       && "$PGCTL" export "$FIX" "$OUT/E8-loop.gif" --aspect 1:1 --cut 6:8 && [[ -s "$OUT/E8-loop.gif" ]]; }
run "E8 square loop + GIF" e8

# E13 Agent — saved edits from the CLI: captions, zoom, idle cut, then frames to review and an export.
e13() {
  local P="$OUT/E13.screenplayground"; rm -rf "$P"
  "$PGCTL" make-fixture "$P" --duration 8 >/dev/null &&
  "$PGCTL" --json edit "$P" --auto-zoom --caption '1:3:Open the dashboard' --zoom 4:6:2.5:0.7,0.3 --output-time --cut 6.5:7.5 \
    | jq -e '.captions == 1 and .outputDuration > 6.9 and .outputDuration < 7.1' &&
  "$PGCTL" --json info "$P" | jq -e '(.captions | length) == 1 and (.cuts | length) == 1' &&
  "$PGCTL" --json frames "$P" --every 2 --out "$OUT/E13-frames" | jq -e '(.frames | length) >= 3' &&
  [[ -s "$OUT/E13-frames/contact-sheet.jpg" ]] &&
  "$PGCTL" export "$P" "$OUT/E13-agent.mp4" --res 720 --fps 30 && check_mp4 "$OUT/E13-agent.mp4" 1280 720 30 6.9 7.1
}
run "E13 agent edits (captions, zoom, cut, frames)" e13

# JSON errors for agents: a bad edit exits non-zero with a machine-readable code.
ejson() { ! "$PGCTL" --json edit "$FIX" --caption 'oops' > "$OUT/err.json" && jq -e '.error.code == "bad-request"' "$OUT/err.json"; }
run "JSON error output" ejson

# Agent setup — install into a fake home: keeps existing config, backs it up, idempotent; MCP handshake + tools.
einstall() {
  local H="$OUT/home"; rm -rf "$H"; mkdir -p "$H/Library/Application Support/Claude" "$H/.codex"
  echo '{"mcpServers":{"other":{"command":"x"}}}' > "$H/Library/Application Support/Claude/claude_desktop_config.json"
  printf '[mcp_servers.other]\ncommand = "y"\n' > "$H/.codex/config.toml"
  PG_HOME="$H" PG_SKILL_PATH="$(dirname "$0")/../skills/screen-playground-demo/SKILL.md" \
    "$PGCTL" --json install --for claude-code --for claude-desktop --for codex >/dev/null &&
  PG_HOME="$H" PG_SKILL_PATH="$(dirname "$0")/../skills/screen-playground-demo/SKILL.md" "$PGCTL" --json install --for codex >/dev/null &&
  jq -e '.mcpServers.other and .mcpServers["screen-playground"].args == ["mcp"]' "$H/Library/Application Support/Claude/claude_desktop_config.json" &&
  [[ $(grep -c 'mcp_servers.screen-playground' "$H/.codex/config.toml") -eq 1 ]] && grep -q 'mcp_servers.other' "$H/.codex/config.toml" &&
  [[ -s "$H/.claude/skills/screen-playground-demo/SKILL.md" ]] &&
  printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}' \
                 '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' | "$PGCTL" mcp | tail -1 | jq -e '(.result.tools | length) >= 10'
}
run "agent setup + MCP server" einstall

# Frame render sanity.
fr() { "$PGCTL" render-frame "$FIX" 2.0 "$OUT/frame.png" --auto-zoom && [[ -s "$OUT/frame.png" ]]; }
run "render frame" fr

echo "—"
echo "$pass passed, $fail failed. Outputs: $OUT"
[[ $fail -eq 0 ]]
