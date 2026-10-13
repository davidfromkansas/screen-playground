#!/usr/bin/env bash
# Builds a notarized, stapled Screen Playground DMG and (optionally) publishes a GitHub Release.
#
#   scripts/release.sh 0.1.0            # build + notarize + staple → dist/ScreenPlayground-0.1.0.dmg
#   scripts/release.sh 0.1.0 --publish  # …and create the GitHub Release with the DMG attached
#
# One-time setup (needs a paid Apple Developer account):
#   1. Xcode › Settings › Accounts: add your Apple ID, then Manage Certificates › + › "Developer ID Application".
#   2. Create an app-specific password at account.apple.com › Sign-In and Security, then run:
#        xcrun notarytool store-credentials screen-playground-notary --apple-id YOU@EXAMPLE.COM --team-id TEAMID
#      (it asks for the app-specific password and keeps it in your keychain).
set -euo pipefail

VERSION="${1:?usage: scripts/release.sh <version> [--publish]}"
PUBLISH="${2:-}"
PROFILE="${NOTARY_PROFILE:-screen-playground-notary}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

IDENTITY_LINE=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 || true)
[[ -n "$IDENTITY_LINE" ]] || { echo "No 'Developer ID Application' certificate found. See setup step 1 at the top of this script."; exit 1; }
IDENTITY=$(sed -E 's/.*"(.*)".*/\1/' <<<"$IDENTITY_LINE")
TEAM=$(sed -E 's/.*\(([A-Z0-9]{10})\)".*/\1/' <<<"$IDENTITY_LINE")
xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1 || { echo "Notary profile '$PROFILE' not found. See setup step 2."; exit 1; }
echo "Signing as: $IDENTITY (team $TEAM)"

# notarytool exits 0 even when Apple rejects the upload, so check the status explicitly.
notarize() {
  local out id
  out=$(xcrun notarytool submit "$1" --keychain-profile "$PROFILE" --wait 2>&1) || true
  echo "$out"
  if ! grep -q "status: Accepted" <<<"$out"; then
    id=$(grep -m1 -oE "id: [0-9a-f-]{36}" <<<"$out" | cut -d' ' -f2)
    [[ -n "$id" ]] && xcrun notarytool log "$id" --keychain-profile "$PROFILE"
    echo "Notarization failed."; exit 1
  fi
}

BUILD="$ROOT/build/ReleaseDevID"
APP="$BUILD/Build/Products/Release/Screen Playground.app"
DMG="$ROOT/dist/ScreenPlayground-$VERSION.dmg"
WORK=$(mktemp -d)

xcodegen generate --quiet
xcodebuild -project ScreenPlayground.xcodeproj -scheme ScreenPlayground -configuration Release -derivedDataPath "$BUILD" \
  -destination 'generic/platform=macOS' ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  MARKETING_VERSION="$VERSION" CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY" DEVELOPMENT_TEAM="$TEAM" \
  ENABLE_HARDENED_RUNTIME=YES CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO OTHER_CODE_SIGN_FLAGS="--timestamp" -quiet build
codesign -d --entitlements - "$APP" 2>/dev/null | grep -q get-task-allow && { echo "Build still has get-task-allow; refusing to notarize."; exit 1; }
codesign --verify --deep --strict --verbose=2 "$APP"

echo "Notarizing the app…"
ditto -c -k --keepParent "$APP" "$WORK/app.zip"
notarize "$WORK/app.zip"
xcrun stapler staple "$APP"

echo "Building the DMG…"
STAGE="$WORK/Screen Playground"
mkdir -p "$STAGE" "$ROOT/dist"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/READ ME FIRST.txt" <<EOF
Screen Playground $VERSION — free screen recorder for Mac (macOS 15 or later)

INSTALL: drag "Screen Playground" onto the Applications folder, then open it.

PERMISSIONS: allow Screen Recording when asked (then quit and reopen the app).
Microphone, Camera, Accessibility and Input Monitoring are optional.

RECORD: press Option-Command-Return anywhere, pick Display / Window / Area, click Record.
Press Option-Command-Return again to stop — the editor opens with zooms already added.
EOF
rm -f "$DMG"
hdiutil create -volname "Screen Playground" -srcfolder "$STAGE" -ov -format UDZO "$DMG" -quiet
codesign --sign "$IDENTITY" --timestamp "$DMG"

echo "Notarizing the DMG…"
notarize "$DMG"
xcrun stapler staple "$DMG"

echo "Gatekeeper check:"
spctl -a -t open --context context:primary-signature -vv "$DMG"
spctl -a -vv "$APP"
shasum -a 256 "$DMG"

# The update feed the app checks (served by GitHub Pages from site/updates/latest.json).
FEED="$ROOT/site/updates/latest.json"
mkdir -p "$(dirname "$FEED")"
python3 - "$VERSION" "$DMG" "$ROOT/docs/release-notes/$VERSION.md" "$FEED" <<'PY'
import hashlib, json, os, re, sys, datetime
version, dmg, notes_file, out = sys.argv[1:5]
notes = []
if os.path.exists(notes_file):
    for line in open(notes_file):
        m = re.match(r"^- \*\*(.+?)\*\*\s*(.*)", line.strip())
        if m and len(notes) < 5:
            text = (m.group(1).rstrip(".") + ". " + m.group(2)).strip()
            text = re.sub(r"\*|`|\[([^\]]+)\]\([^)]+\)", lambda x: x.group(1) or "", text)
            notes.append(text[:160].rstrip() + ("…" if len(text) > 160 else ""))
feed = {
    "version": version,
    "released": datetime.date.today().strftime("%b %-d, %Y"),
    "dmg": f"https://github.com/davidfromkansas/screen-playground/releases/download/v{version}/ScreenPlayground-{version}.dmg",
    "size": os.path.getsize(dmg),
    "sha256": hashlib.sha256(open(dmg, "rb").read()).hexdigest(),
    "notes": notes,
    "notesURL": f"https://github.com/davidfromkansas/screen-playground/releases/tag/v{version}",
    "minimumSystem": "15.0",
}
json.dump(feed, open(out, "w"), indent=2)
print("update feed:", out)
PY

if [[ "$PUBLISH" == "--publish" ]]; then
  gh release create "v$VERSION" "$DMG" --title "Screen Playground $VERSION" --notes-file "$ROOT/docs/release-notes/$VERSION.md"
  # Publishing the feed is what tells installed copies about the new version.
  git -C "$ROOT" add site/updates/latest.json
  git -C "$ROOT" commit -m "Update feed: $VERSION" site/updates/latest.json
  git -C "$ROOT" push
  # Refresh the landing page on davidfromkansas.com/screenplayground.
  "$ROOT/scripts/publish-site.sh"
fi
echo "Done: $DMG"
