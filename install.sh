#!/usr/bin/env bash
# Hearth IDE installer / updater (Apple Silicon).
#
#   curl -fsSL https://github.com/botgarten/hearth-ide/releases/latest/download/install.sh | bash
#
# Downloads the latest release from GitHub Releases, verifies its SHA-256,
# installs "Hearth IDE.app" into /Applications (or ~/Applications without write
# access) and starts it. Run again to update.
set -euo pipefail

BASE_URL="${HEARTH_BASE_URL:-https://github.com/botgarten/hearth-ide/releases/latest/download}"
ASSET="hearth-macos-arm64.zip"
APP_NAME="Hearth IDE.app"
NO_OPEN=false

for arg in "$@"; do
  case "$arg" in
    --no-open) NO_OPEN=true ;;
    *) echo "Unknown argument: $arg" >&2; exit 1 ;;
  esac
done

info()    { printf '\033[0;34m[INFO]\033[0m  %s\n' "$*"; }
success() { printf '\033[0;32m[OK]\033[0m    %s\n' "$*"; }
fail()    { printf '\033[0;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || fail "Hearth IDE is a macOS app."
[[ "$(uname -m)" == "arm64" ]] || fail "Hearth IDE is built for Apple Silicon only."
[[ "$(sw_vers -productVersion | cut -d. -f1)" -ge 14 ]] || fail "Hearth IDE needs macOS 14 or newer."

VERSION="$(curl -fsSL "$BASE_URL/latest-version.txt" | tr -d '[:space:]')" \
  || fail "Could not reach $BASE_URL"
info "Installing Hearth IDE $VERSION"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
curl -fsSL -o "$TMP/$ASSET" "$BASE_URL/$ASSET"
curl -fsSL -o "$TMP/$ASSET.sha256" "$BASE_URL/$ASSET.sha256"
(cd "$TMP" && shasum -a 256 -c "$ASSET.sha256" >/dev/null) || fail "Checksum mismatch – download corrupted or tampered."
success "Checksum verified"

ditto -x -k "$TMP/$ASSET" "$TMP/unpacked"
SRC="$(find "$TMP/unpacked" -maxdepth 1 -name '*.app' | head -n1)"
[[ -n "$SRC" ]] || fail "Archive contains no app bundle."

DEST_DIR="${HEARTH_INSTALL_DIR:-/Applications}"
[[ -w "$DEST_DIR" ]] || DEST_DIR="$HOME/Applications"
mkdir -p "$DEST_DIR"
DEST="$DEST_DIR/$APP_NAME"

# Quit a running instance so the bundle can be replaced.
if [[ -z "${HEARTH_INSTALL_DIR:-}" ]] && pgrep -x Hearth >/dev/null; then
  info "Quitting running Hearth IDE"
  osascript -e 'tell application id "io.github.pvanissem.hearth" to quit' >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x Hearth >/dev/null || break; sleep 0.5; done
  if pgrep -x Hearth >/dev/null; then
    fail "Hearth IDE läuft noch (Beenden abgebrochen oder Dialog offen). Update abgebrochen – keine App-Dateien ersetzt. Bitte regulär beenden und erneut versuchen."
  fi
fi

rm -rf "$DEST"
ditto "$SRC" "$DEST"
# The app is ad-hoc signed (not notarized); curl downloads carry no quarantine
# flag, this only clears one should a proxy or browser have added it.
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
success "Installed to $DEST"

$NO_OPEN || open "$DEST"
