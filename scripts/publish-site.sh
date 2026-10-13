#!/usr/bin/env bash
# Publishes the landing page (site/) to davidfromkansas.com/screenplayground by copying it into the
# personal website repo (GitHub Pages serves that repo at www.davidfromkansas.com).
#
#   scripts/publish-site.sh            # copy, commit and push if anything changed
#   scripts/publish-site.sh --dry-run  # show what would change
#
# The update feed the app checks stays at davidfromkansas.github.io/screen-playground/updates/latest.json
# (deployed by .github/workflows/pages.yml), so installed apps never depend on the personal site.
set -euo pipefail

SITE_REPO="${SITE_REPO:-davidfromkansas/david_personal_website}"
SUBDIR="${SITE_SUBDIR:-screenplayground}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

gh repo clone "$SITE_REPO" "$WORK/site" -- -q --depth 1
cd "$WORK/site"
git config user.name "David Lietjauw"
git config user.email "16072284+davidfromkansas@users.noreply.github.com"

mkdir -p "$SUBDIR"
rsync -a --delete --exclude '.DS_Store' --exclude 'updates' "$ROOT/site/" "$SUBDIR/"

git add -A "$SUBDIR"
if git diff --cached --quiet; then
  echo "davidfromkansas.com/$SUBDIR is already up to date."
  exit 0
fi
git --no-pager diff --cached --stat
if [[ "${1:-}" == "--dry-run" ]]; then
  echo "(dry run: nothing pushed)"
  exit 0
fi
git commit -q -m "Screen Playground site: $(git -C "$ROOT" log -1 --format=%h -- site)"
git push -q
echo "Published to https://www.davidfromkansas.com/$SUBDIR/"
