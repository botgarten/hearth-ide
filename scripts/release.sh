#!/usr/bin/env bash
# Cuts a Hearth IDE release (Apple Silicon only).
#
#   scripts/release.sh v0.3.0
#
# 1. checks: clean main, in sync with origin, tests green
# 2. CHANGELOG.md: the "Unveröffentlicht" section becomes this version (committed to main)
# 3. annotated tag + push
# 4. GitHub Actions (.github/workflows/ci.yml) builds, tests and publishes the release
#    with the app zip, its SHA-256, latest-version.txt, CHANGELOG.md and install.sh;
#    the app and install.sh read them from
#    https://github.com/<repo>/releases/latest/download/<file>
set -euo pipefail
cd "$(dirname "$0")/.."

REPO="${HEARTH_REPO:-pvanissem/hearth-ide}"

VERSION="${1:-}"
if [[ ! "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Usage: scripts/release.sh vX.Y.Z" >&2
  exit 1
fi

step() { printf '\n\033[1m==>\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

step "Checks"
[[ -z "$(git status --porcelain)" ]] || fail "Working tree not clean – commit first."
[[ "$(git rev-parse --abbrev-ref HEAD)" == "main" ]] || fail "Releases are cut from main."
git fetch --quiet --tags origin
[[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || fail "main is not in sync with origin/main – push or pull first."
git rev-parse -q --verify "refs/tags/$VERSION" >/dev/null && fail "Tag $VERSION already exists."

step "Tests"
scripts/fetch-nono.sh >/dev/null
scripts/fetch-monaco.sh >/dev/null
scripts/test.sh

step "Changelog"
# Notes come from the "## Unveröffentlicht" section of CHANGELOG.md; without one,
# from the commit subjects since the last tag.
UNRELEASED="$(awk '/^## Unveröffentlicht/{on=1;next} /^## /{on=0} on' CHANGELOG.md | sed '/^[[:space:]]*$/d')"
HEADING="## ${VERSION#v} · $(date +%Y-%m-%d)"
if [[ -n "$UNRELEASED" ]]; then
  awk -v h="$HEADING" '/^## Unveröffentlicht/{print h; next} {print}' CHANGELOG.md > CHANGELOG.md.tmp && mv CHANGELOG.md.tmp CHANGELOG.md
else
  PREV="$(git describe --tags --abbrev=0 2>/dev/null || true)"
  NOTES="$(git log --no-merges --format='- %s' ${PREV:+$PREV..}HEAD | head -n 60 || true)"
  { sed -n '1,2p' CHANGELOG.md; printf '%s\n\n%s\n\n' "$HEADING" "${NOTES:--}"; sed '1,2d' CHANGELOG.md; } > CHANGELOG.md.tmp && mv CHANGELOG.md.tmp CHANGELOG.md
fi
sed -n '1,12p' CHANGELOG.md
git add CHANGELOG.md
git commit -q -m "Release $VERSION"

step "Tag and push"
git tag -a "$VERSION" -m "Hearth IDE $VERSION"
git push origin main "$VERSION"
echo "GitHub Actions baut und veröffentlicht jetzt das Release: https://github.com/$REPO/actions"
echo "Danach: https://github.com/$REPO/releases/tag/$VERSION"
