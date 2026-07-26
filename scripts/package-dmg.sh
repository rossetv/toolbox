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
# Optional version/build overrides (set by CI: VERSION from the release tag, BUILD_NUMBER
# from the run number). Empty = keep project.yml's values. Their expansions below are left
# unquoted as a whole so they vanish when empty — quoting would hand xcodebuild an empty
# argument; the inner quotes keep each value one word.
VERSION="${VERSION:-}"
BUILD_NUMBER="${BUILD_NUMBER:-}"

echo "==> Ensuring bundled Ghostscript is present"
if [ ! -x "Resources/ghostscript/bin/gs" ]; then
  scripts/build-ghostscript.sh
fi
"Resources/ghostscript/bin/gs" --version >/dev/null

echo "==> Generating Xcode project"
xcodegen generate

echo "==> Building $CONFIG"
rm -rf "$BUILD_DIR" "$DIST_DIR"
mkdir -p "$BUILD_DIR"
# Full build output goes to a log, not /dev/null: a CI failure with the detail discarded
# is undebuggable (an asset-catalog error cost a round trip to learn exactly this).
if ! xcodebuild -project "$NAME.xcodeproj" -scheme "$NAME" \
  -configuration "$CONFIG" -derivedDataPath "$BUILD_DIR" \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  ${VERSION:+MARKETING_VERSION="$VERSION"} \
  ${BUILD_NUMBER:+CURRENT_PROJECT_VERSION="$BUILD_NUMBER"} \
  build > "$BUILD_DIR/xcodebuild.log" 2>&1; then
  echo "build failed — last 80 lines of $BUILD_DIR/xcodebuild.log:" >&2
  tail -80 "$BUILD_DIR/xcodebuild.log" >&2
  exit 1
fi

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
