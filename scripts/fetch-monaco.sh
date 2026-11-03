#!/usr/bin/env bash
# Downloads the pinned monaco-editor release (the editor of VS Code) from the npm registry,
# verifies its integrity hash and keeps only what Hearth loads in Vendor/monaco/<version>/vs:
# the AMD loader, the editor core, the workers, the German UI strings, the syntax
# definitions of the supported languages and the TypeScript/JavaScript language service.
# scripts/bundle.sh copies the result into "Hearth IDE.app/Contents/Resources/monaco/vs".
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="0.52.2"
INTEGRITY="sha512-GEQWEZmfkOGLdd3XK8ryrfWz3AIP8YymVXiPHEdewrUq7mh0qrKrfHLNCXcbB6sTnMLnOZ3ztSiKcciFUkIJwQ=="
URL="https://registry.npmjs.org/monaco-editor/-/monaco-editor-${VERSION}.tgz"
DEST="Vendor/monaco/${VERSION}"
LANGUAGES="go java javascript typescript python rust kotlin swift csharp cpp shell yaml xml html css scss less markdown sql dockerfile ini ruby scala php lua powershell"

if [[ -f "$DEST/vs/loader.js" ]]; then echo "$DEST"; exit 0; fi
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
curl -fsSL -o "$TMP/monaco.tgz" "$URL"
ACTUAL="sha512-$(openssl dgst -sha512 -binary "$TMP/monaco.tgz" | openssl base64 -A)"
[[ "$ACTUAL" == "$INTEGRITY" ]] || { echo "Integrity mismatch for monaco-editor ${VERSION}" >&2; exit 1; }
tar -xzf "$TMP/monaco.tgz" -C "$TMP"
SRC="$TMP/package/min/vs"
OUT="$TMP/out/vs"
mkdir -p "$OUT/editor" "$OUT/base/worker" "$OUT/basic-languages" "$OUT/language"
cp "$SRC/loader.js" "$OUT/"
cp "$SRC/editor/editor.main.js" "$SRC/editor/editor.main.css" "$OUT/editor/"
cp "$SRC/base/worker/workerMain.js" "$OUT/base/worker/"
cp "$SRC/nls.messages.de.js" "$OUT/"
mkdir -p "$OUT/base/browser/ui/codicons/codicon"
cp "$SRC/base/browser/ui/codicons/codicon/codicon.ttf" "$OUT/base/browser/ui/codicons/codicon/"
for l in $LANGUAGES; do [[ -d "$SRC/basic-languages/$l" ]] && cp -R "$SRC/basic-languages/$l" "$OUT/basic-languages/"; done
for l in typescript json; do cp -R "$SRC/language/$l" "$OUT/language/"; done
cp "$TMP/package/LICENSE" "$TMP/package/ThirdPartyNotices.txt" "$TMP/out/" 2>/dev/null || true
mkdir -p "$DEST" && cp -R "$TMP/out/." "$DEST/"
echo "$DEST"
