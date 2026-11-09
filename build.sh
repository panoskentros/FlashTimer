#!/bin/bash
# Builds FlashTimer.ipa (unsigned) for iPhone. Requires Xcode.
set -e
cd "$(dirname "$0")"
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
rm -rf build FlashTimer.ipa
mkdir -p build/Payload/FlashTimer.app
xcrun -sdk iphoneos swiftc -swift-version 5 -parse-as-library -O \
  -target arm64-apple-ios17.0 -sdk "$SDK" \
  FlashTimer.swift -o build/Payload/FlashTimer.app/FlashTimer
cp Info.plist build/Payload/FlashTimer.app/
cp "Icon/AppIcon60x60@2x.png" "Icon/AppIcon60x60@3x.png" build/Payload/FlashTimer.app/
codesign -s - --force build/Payload/FlashTimer.app
(cd build && zip -qr ../FlashTimer.ipa Payload)
echo "Built FlashTimer.ipa"
