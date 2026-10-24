#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$PROJECT_DIR/dist}"
APP="$BUILD_DIR/OpenRGB Volume.app"
ARCH="${ARCH:-$(uname -m)}"
case "$ARCH" in x86_64|arm64) ;; *) echo 'ARCH must be x86_64 or arm64' >&2; exit 1 ;; esac
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
xcrun --sdk macosx swiftc -O -target "$ARCH-apple-macosx12.0" \
  "$PROJECT_DIR/Sources/DeviceConfiguration.swift" \
  "$PROJECT_DIR/Sources/Audio.swift" "$PROJECT_DIR/Sources/ManagerCore.swift" \
  "$PROJECT_DIR/Sources/main.swift" \
  -framework Cocoa -framework CoreAudio -framework ApplicationServices \
  -o "$APP/Contents/MacOS/OpenRGBVolume"
cp "$PROJECT_DIR/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$PROJECT_DIR/Resources/Manager.icns" "$APP/Contents/Resources/Manager.icns"
plutil -lint "$APP/Contents/Info.plist"
codesign --force --sign "${SIGN_IDENTITY:--}" "$APP"
codesign --verify --strict "$APP"
echo "Built: $APP ($ARCH)"
