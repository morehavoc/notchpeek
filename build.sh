#!/bin/zsh
# Builds NotchPeek.app (universal) into build/. Usage: ./build.sh [signing identity]
set -euo pipefail
cd "${0:A:h}"
ID="${1:-Apple Development}"
APP=build/NotchPeek.app
rm -rf build && mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
for a in arm64 x86_64; do
  swiftc -O -target $a-apple-macos14.0 Sources/main.swift -o build/NotchPeek-$a
done
lipo -create build/NotchPeek-arm64 build/NotchPeek-x86_64 -output $APP/Contents/MacOS/NotchPeek
rm build/NotchPeek-*
cp Info.plist $APP/Contents/
[ -f AppIcon.icns ] && cp AppIcon.icns $APP/Contents/Resources/
codesign --force --options runtime --timestamp=none -s "$ID" $APP
codesign -v $APP && echo "built $APP"
