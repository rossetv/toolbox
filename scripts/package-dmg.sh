#!/bin/bash
# Build Toolbox as a Release .app, sign it, and wrap it in a distributable DMG.
#
# Signing: this script ad-hoc signs (`--sign -`) because that is all an unprovisioned machine
# can do. Ad-hoc signing is enough to RUN a locally built app, but it is NOT enough for
# distribution — Gatekeeper rejects a downloaded ad-hoc app. To ship, set DEVELOPER_ID to a
# "Developer ID Application: ..." identity and the same script produces a signable, notarisable
# bundle (then run `xcrun notarytool submit` + `xcrun stapler staple`).
set -euo pipefail

cd "$(dirname "$0")/.."
CONFIG="${CONFIG:-Release}"
# The Xcode project/scheme, the built .app, the DMG filename and the mounted volume all share
# this one name. It is kept space-free so URLs, CI globs and Finder paths stay simple — and
# because a space in the bundle path breaks TEST_HOST, the scheme and these scripts.
NAME="Toolbox"
BUILD_DIR="build"
DIST_DIR="dist"
SIGN_ID="${DEVELOPER_ID:--}"          # "-" = ad-hoc

echo "==> Ensuring bundled Ghostscript is present"
if [ ! -x "Resources/ghostscript/bin/gs" ]; then
  scripts/build-ghostscript.sh
fi
"Resources/ghostscript/bin/gs" --version >/dev/null

echo "==> Generating Xcode project"
xcodegen generate

echo "==> Building $CONFIG"
rm -rf "$BUILD_DIR" "$DIST_DIR"
xcodebuild -project "$NAME.xcodeproj" -scheme "$NAME" \
  -configuration "$CONFIG" -derivedDataPath "$BUILD_DIR" \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  build >/dev/null

APP="$BUILD_DIR/Build/Products/$CONFIG/$NAME.app"
[ -d "$APP" ] || { echo "build produced no app at $APP"; exit 1; }

echo "==> Signing (identity: $SIGN_ID) — nested code first, then the bundle"
# Sign inside-out: the bundled gs helper must be signed before the enclosing bundle, or the
# app's seal will not cover a valid nested signature.
codesign --force --options runtime --timestamp=none --sign "$SIGN_ID" \
  "$APP/Contents/Resources/ghostscript/bin/gs"
codesign --force --options runtime --timestamp=none --sign "$SIGN_ID" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "==> Staging DMG contents"
mkdir -p "$DIST_DIR/stage"
cp -R "$APP" "$DIST_DIR/stage/"
ln -s /Applications "$DIST_DIR/stage/Applications"

echo "==> Creating DMG"
hdiutil create -volname "$NAME" -srcfolder "$DIST_DIR/stage" \
  -ov -format UDZO "$DIST_DIR/$NAME.dmg" >/dev/null
rm -rf "$DIST_DIR/stage"

echo "==> Done: $DIST_DIR/$NAME.dmg"
ls -lh "$DIST_DIR/$NAME.dmg" | awk '{print "    size:", $5}'
