#!/bin/zsh
# Builds NetWidget.app with the Command Line Tools only (no Xcode), ad-hoc signed.
set -euo pipefail
cd "${0:A:h}"
APP=build/NetWidget.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"
swiftc -O -swift-version 5 -target arm64-apple-macos26.0 \
  -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
  -o "$APP/Contents/MacOS/NetWidget" Sources/*.swift
codesign --force --sign - --timestamp=none "$APP"
echo "built $APP"
