#!/bin/bash
# Builds dist/Beam.app from the release binary. Ad-hoc signed by default;
# real signing/notarization scaffolding behind env vars (PLAN.md §3.2):
#   BEAM_SIGN_IDENTITY   codesign identity (default: "-" ad-hoc)
#   BEAM_NOTARIZE_PROFILE  notarytool keychain profile; if set, submits.
set -euo pipefail
cd "$(dirname "$0")/.."

scripts/build.sh
APP=dist/Beam.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/bin/beam "$APP/Contents/MacOS/Beam"
cp resources/Beam.icns "$APP/Contents/Resources/Beam.icns"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>Beam</string>
    <key>CFBundleIdentifier</key><string>com.jugalm.beam</string>
    <key>CFBundleName</key><string>Beam</string>
    <key>CFBundleIconFile</key><string>Beam</string>
    <key>CFBundleDisplayName</key><string>Beam</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSLocalNetworkUsageDescription</key>
    <string>Beam finds collaborators on your local network so you can connect instantly. Nothing ever leaves the network.</string>
    <key>NSBonjourServices</key>
    <array><string>_beam._tcp</string></array>
</dict>
</plist>
EOF

codesign --force --sign "${BEAM_SIGN_IDENTITY:--}" "$APP"

if [ -n "${BEAM_NOTARIZE_PROFILE:-}" ]; then
  ditto -c -k --keepParent "$APP" dist/Beam.zip
  xcrun notarytool submit dist/Beam.zip --keychain-profile "$BEAM_NOTARIZE_PROFILE" --wait
  xcrun stapler staple "$APP"
fi

# **A .dmg, because it is the format a Mac user already knows how to install.**
# Drag to Applications, eject, done — no Terminal, no `xattr`, no unarchiver
# that leaves the app in ~/Downloads where the next update cannot find it.
# `BEAM_DMG=0` skips it for the CI path that only wants to verify the binary.
if [ "${BEAM_DMG:-1}" = 1 ] && command -v hdiutil >/dev/null; then
  STAGE=dist/dmg
  rm -rf "$STAGE" dist/Beam.dmg
  mkdir -p "$STAGE"
  cp -R "$APP" "$STAGE/Beam.app"
  ln -s /Applications "$STAGE/Applications"
  hdiutil create -volname "Beam" -srcfolder "$STAGE" -ov -format UDZO dist/Beam.dmg >/dev/null
  rm -rf "$STAGE"
  echo "packaged dist/Beam.dmg"
fi

echo "packaged $APP"
