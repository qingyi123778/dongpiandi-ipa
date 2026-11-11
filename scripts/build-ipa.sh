#!/bin/bash
# 在 macOS 上本地构建未签名 IPA。
# 依赖: Xcode 15+ / xcodegen (brew install xcodegen)
# 用法: ./scripts/build-ipa.sh [输出目录]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${1:-$ROOT/build}"
ARCHIVE="$OUT_DIR/App.xcarchive"
IPA="$OUT_DIR/DongPianDi.ipa"

command -v xcodebuild >/dev/null || { echo "缺少 xcodebuild，先装 Xcode"; exit 1; }
if ! command -v xcodegen >/dev/null; then
  echo "缺少 xcodegen，执行: brew install xcodegen"
  exit 1
fi

mkdir -p "$OUT_DIR"
cd "$ROOT"

echo "[1/4] 生成工程"
xcodegen generate

echo "[2/4] 编译 archive（不签名）"
rm -rf "$ARCHIVE"
xcodebuild \
  -project DongPianDi.xcodeproj \
  -scheme DongPianDi \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGN_ENTITLEMENTS="" \
  build

APP="$ARCHIVE/Products/Applications/DongPianDi.app"
test -d "$APP" || { echo "找不到产物: $APP"; exit 1; }

echo "[3/4] 打包 Payload"
STAGE="$OUT_DIR/Payload"
rm -rf "$STAGE" "$IPA"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
(cd "$OUT_DIR" && zip -qry "$(basename "$IPA")" Payload)

echo "[4/4] 完成"
ls -lh "$IPA"
shasum -a 256 "$IPA"
