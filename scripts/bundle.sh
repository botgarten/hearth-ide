#!/usr/bin/env bash
# Builds "Hearth IDE.app" from the SwiftPM executable (no Xcode required).
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Hearth"

APP="build/Hearth IDE.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Hearth"
cp Resources/mermaid.min.js Resources/AppIcon.icns "$APP/Contents/Resources/"
# Monaco, the editor of VS Code (pinned, integrity-checked; see scripts/fetch-monaco.sh), and its host page script.
MONACO="$(scripts/fetch-monaco.sh | tail -n1)"
mkdir -p "$APP/Contents/Resources/monaco"
cp -R "$MONACO/." "$APP/Contents/Resources/monaco/"
cp Resources/monaco-host.js "$APP/Contents/Resources/"
# Translations: English is the development language, German in de.lproj.
cp -R Resources/en.lproj Resources/de.lproj "$APP/Contents/Resources/"
# The sandbox runtime: pinned, checksum-verified nono release (see scripts/fetch-nono.sh).
NONO="$(scripts/fetch-nono.sh | tail -n1)"
mkdir -p "$APP/Contents/Helpers"
cp "$NONO" "$APP/Contents/Helpers/nono"

# Release builds pass VERSION=vX.Y.Z; dev builds use git describe.
BUILD_CHANNEL=release
if [[ -z "${VERSION:-}" ]]; then
  BUILD_CHANNEL=development
  VERSION="$(git describe --tags --always --dirty 2>/dev/null || echo development)"
fi
VERSION="${VERSION#v}"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Hearth IDE</string>
  <key>CFBundleDisplayName</key><string>Hearth IDE</string>
  <key>CFBundleIdentifier</key><string>io.github.pvanissem.hearth</string>
  <key>CFBundleExecutable</key><string>Hearth</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>de</string></array>
  <key>UTExportedTypeDeclarations</key>
  <array><dict>
    <key>UTTypeIdentifier</key><string>io.github.pvanissem.hearth.workspace-file</string>
    <key>UTTypeDescription</key><string>Hearth IDE workspace file move</string>
    <key>UTTypeConformsTo</key><array><string>public.data</string></array>
  </dict></array>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>HearthBuildChannel</key><string>${BUILD_CHANNEL}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>Hearth IDE opens a folder in your terminal app when you ask it to.</string>
  <key>NSAppTransportSecurity</key>
  <dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null
echo "Built $APP"
