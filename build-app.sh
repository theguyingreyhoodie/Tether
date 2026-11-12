#!/bin/bash
# Builds Tether.app. Pass --install to also copy it to /Applications and launch it.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Tether"
APP_BUNDLE="$APP_NAME.app"

echo "Building release binary..."
swift build -c release

echo "Assembling $APP_BUNDLE..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp ".build/release/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp Info.plist "$APP_BUNDLE/Contents/Info.plist"

echo "Drawing icon..."
ICONSET="$(mktemp -d)/AppIcon.iconset"
swift Scripts/make-icon.swift "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

echo "Signing $APP_BUNDLE..."
codesign --force -s - "$APP_BUNDLE"

if [[ "${1:-}" == "--install" ]]; then
    echo "Installing to /Applications..."
    pkill -x "$APP_NAME" 2>/dev/null || true
    rm -rf "/Applications/$APP_BUNDLE"
    cp -R "$APP_BUNDLE" "/Applications/$APP_BUNDLE"
    open "/Applications/$APP_BUNDLE"
fi

echo "Done: $APP_BUNDLE"
