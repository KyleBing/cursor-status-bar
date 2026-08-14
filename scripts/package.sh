#!/usr/bin/env bash
# 编译 Release 并生成 .app zip + .dmg
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

SCHEME="CursorStatusBar"
APP_NAME="CursorStatusBar"
DERIVED="$ROOT/build"
STAGING="$ROOT/dist/dmg-staging"
OUT_DIR="$ROOT/dist"

# 从工程读取 MARKETING_VERSION
VERSION="$(
  grep -m1 'MARKETING_VERSION' "$ROOT/CursorStatusBar.xcodeproj/project.pbxproj" \
    | sed -E 's/.*MARKETING_VERSION = ([^;]+);/\1/' \
    | tr -d ' '
)"
if [[ -z "$VERSION" ]]; then
  echo "无法读取 MARKETING_VERSION" >&2
  exit 1
fi

echo "==> 编译 Release ${APP_NAME} v${VERSION}"
xcodebuild \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination "platform=macOS" \
  -derivedDataPath "$DERIVED" \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO

APP="$DERIVED/Build/Products/Release/${APP_NAME}.app"
if [[ ! -d "$APP" ]]; then
  echo "未找到 $APP" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"
ZIP="$OUT_DIR/${APP_NAME}-${VERSION}.zip"
DMG="$OUT_DIR/${APP_NAME}-${VERSION}.dmg"

echo "==> 打包 zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> 打包 dmg"
rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

hdiutil create \
  -volname "Cursor Status Bar" \
  -srcfolder "$STAGING" \
  -ov -format UDZO \
  "$DMG"

rm -rf "$STAGING"

echo
echo "完成:"
echo "  $ZIP"
echo "  $DMG"
ls -lh "$ZIP" "$DMG"
