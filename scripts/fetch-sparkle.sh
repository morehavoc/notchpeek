#!/bin/zsh
# Puts Sparkle.xcframework in vendor/ and the Sparkle tools (generate_appcast, sign_update) in vendor/sparkle-tools/.
set -euo pipefail
cd "${0:A:h}/.."
V=2.10.0
SPM_SHA=17e28312b8e18ab7cdbbe09a6fb28cc55a5479ec6c371dbc07cdecd2a14fd959
TOOLS_SHA=c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c
mkdir -p vendor
if [ ! -d vendor/Sparkle.xcframework ]; then
  curl -fsSL --max-time 300 -o vendor/spm.zip "https://github.com/sparkle-project/Sparkle/releases/download/$V/Sparkle-for-Swift-Package-Manager.zip"
  [ "$(shasum -a 256 vendor/spm.zip | awk '{print $1}')" = "$SPM_SHA" ] || { echo "Sparkle SPM zip checksum mismatch"; exit 1; }
  ditto -x -k vendor/spm.zip vendor/ && rm vendor/spm.zip
fi
if [ ! -x vendor/sparkle-tools/bin/generate_appcast ]; then
  curl -fsSL --max-time 300 -o vendor/tools.tar.xz "https://github.com/sparkle-project/Sparkle/releases/download/$V/Sparkle-$V.tar.xz"
  [ "$(shasum -a 256 vendor/tools.tar.xz | awk '{print $1}')" = "$TOOLS_SHA" ] || { echo "Sparkle tools checksum mismatch"; exit 1; }
  mkdir -p vendor/sparkle-tools && tar -xf vendor/tools.tar.xz -C vendor/sparkle-tools && rm vendor/tools.tar.xz
fi
