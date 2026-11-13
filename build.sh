#!/bin/zsh
# Builds build/NotchPeek.app and signs it inside-out (hardened runtime).
# Usage: ./build.sh [signing identity]   default "Apple Development"; CI passes "Developer ID Application".
# Universal (arm64 + x86_64) when Xcode is present; host arch only with just the command line tools.
set -euo pipefail
cd "${0:A:h}"
ID="${1:-Apple Development}"
APP=build/NotchPeek.app
./scripts/fetch-sparkle.sh

ARCHS=()
xcrun --find xcbuild >/dev/null 2>&1 && ARCHS=(--arch arm64 --arch x86_64)
swift build -c release ${ARCHS[@]+"${ARCHS[@]}"}
BIN="$(swift build -c release ${ARCHS[@]+"${ARCHS[@]}"} --show-bin-path)/NotchPeek"

rm -rf build && mkdir -p $APP/Contents/MacOS $APP/Contents/Resources $APP/Contents/Frameworks
cp "$BIN" $APP/Contents/MacOS/NotchPeek
ditto vendor/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework $APP/Contents/Frameworks/Sparkle.framework
otool -l $APP/Contents/MacOS/NotchPeek | grep -q "@executable_path/../Frameworks" \
  || install_name_tool -add_rpath "@executable_path/../Frameworks" $APP/Contents/MacOS/NotchPeek
cp Info.plist $APP/Contents/
cp AppIcon.icns $APP/Contents/Resources/

TS="--timestamp=none"; [[ "$ID" == Developer\ ID* ]] && TS="--timestamp"
sign() { codesign --force --options runtime $TS -s "$ID" "$@"; }
FWV=$APP/Contents/Frameworks/Sparkle.framework/Versions/B
for p in XPCServices/Installer.xpc XPCServices/Downloader.xpc Autoupdate Updater.app; do
  [ -e "$FWV/$p" ] || { echo "Sparkle layout changed: no $p"; exit 1; }
done
# Sparkle's documented order for a non-sandboxed app; Downloader.xpc keeps its own entitlements.
sign "$FWV/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$FWV/XPCServices/Downloader.xpc"
sign "$FWV/Autoupdate"
sign "$FWV/Updater.app"
sign $APP/Contents/Frameworks/Sparkle.framework
sign $APP
codesign --verify --strict --deep $APP && echo "built $APP ($(lipo -archs $APP/Contents/MacOS/NotchPeek))"
