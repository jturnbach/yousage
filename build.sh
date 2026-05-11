#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="YouSage"
BUILD_CONFIG="release"
BUILD_OUT="build/${APP_NAME}.app"
ARCH="$(uname -m)"

echo "==> Cleaning previous bundle"
rm -rf "build"
mkdir -p "build"

echo "==> Compiling Swift package ($BUILD_CONFIG, arch=$ARCH)"
swift build -c "$BUILD_CONFIG"

BIN_PATH="$(swift build -c "$BUILD_CONFIG" --show-bin-path)/$APP_NAME"
if [ ! -x "$BIN_PATH" ]; then
    echo "ERROR: built binary not found at $BIN_PATH"
    exit 1
fi

echo "==> Assembling app bundle at $BUILD_OUT"
mkdir -p "$BUILD_OUT/Contents/MacOS"
mkdir -p "$BUILD_OUT/Contents/Resources"
cp "$BIN_PATH" "$BUILD_OUT/Contents/MacOS/$APP_NAME"
cp "Resources/Info.plist" "$BUILD_OUT/Contents/Info.plist"

# Optional icon if you drop an AppIcon.icns into Resources/
if [ -f "Resources/AppIcon.icns" ]; then
    cp "Resources/AppIcon.icns" "$BUILD_OUT/Contents/Resources/AppIcon.icns"
fi

echo "==> Ad-hoc code signing"
codesign --force --deep --sign - "$BUILD_OUT"

echo
echo "Build complete:"
echo "  $BUILD_OUT"
echo
echo "Run:      open '$BUILD_OUT'"
echo "Install:  cp -R '$BUILD_OUT' /Applications/"
