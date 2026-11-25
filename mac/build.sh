#!/bin/bash
# Builds "Elite Studio.app" in this folder.  Usage: ./build.sh
set -euo pipefail
cd "$(dirname "$0")"
# No build cache is kept anywhere: compile in a temporary folder and delete it when done (even on error).
# Every build starts from scratch (~20 s) and nothing is left on disk.
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/elitestudio-build.XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT
rm -rf .build                     # leftovers from a plain `swift build` or the code index
swift build -c release --arch arm64 --scratch-path "$SCRATCH" 2>&1 | grep -E "error|warning: unre|Compiling|Build" || true
BIN="$(swift build -c release --arch arm64 --scratch-path "$SCRATCH" --show-bin-path)/EliteStudio"
[ -f "$BIN" ] || { echo "build failed"; exit 1; }

APP="Elite Studio.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/EliteStudio"
cp Resources/*.woff Resources/coppa-elite-logo.png "$APP/Contents/Resources/"

# Keep the compact app icon when rebuilding; the tournament logo remains a media asset.
if [[ -f Resources/AppIcon.icns ]]; then
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
else
# icon from the logo
ICONSET="$SCRATCH/AppIcon.iconset"
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s Resources/coppa-elite-logo.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) Resources/coppa-elite-logo.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Elite Studio</string>
  <key>CFBundleDisplayName</key><string>Elite Studio</string>
  <key>CFBundleIdentifier</key><string>com.coppaelite.studio</string>
  <key>CFBundleExecutable</key><string>EliteStudio</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>CFBundleDocumentTypes</key><array><dict>
    <key>CFBundleTypeName</key><string>Elite Studio Project</string>
    <key>CFBundleTypeRole</key><string>Editor</string>
    <key>LSHandlerRank</key><string>Owner</string>
    <key>LSItemContentTypes</key><array><string>com.coppaelite.studio.project</string></array>
  </dict></array>
  <key>UTExportedTypeDeclarations</key><array><dict>
    <key>UTTypeIdentifier</key><string>com.coppaelite.studio.project</string>
    <key>UTTypeDescription</key><string>Elite Studio Project</string>
    <key>UTTypeConformsTo</key><array><string>public.json</string></array>
    <key>UTTypeTagSpecification</key><dict>
      <key>public.filename-extension</key><array><string>elitestudio</string></array>
    </dict>
  </dict></array>
</dict></plist>
PLIST

codesign --force --sign - "$APP" >/dev/null 2>&1
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" >/dev/null 2>&1 || true
echo "built: $(pwd)/$APP"
