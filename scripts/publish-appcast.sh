#!/bin/zsh
# After CI publishes a release: sign its zip with the Sparkle update key and upload appcast.xml to it.
# Usage: scripts/publish-appcast.sh v0.3.0
# Key: ~/.notchpeek-secrets/sparkle_ed25519_private.txt (also login keychain account "notchpeek").
# Installed copies only accept updates signed with the key whose public half is SUPublicEDKey in Info.plist.
set -euo pipefail
cd "${0:A:h}/.."
TAG="${1:?usage: publish-appcast.sh vX.Y.Z}"
REPO=morehavoc/notchpeek
KEY=~/.notchpeek-secrets/sparkle_ed25519_private.txt
./scripts/fetch-sparkle.sh
T=vendor/sparkle-tools/bin

PUB_PLIST=$(plutil -extract SUPublicEDKey raw Info.plist)
PUB_KEY=$({ printf '302e020100300506032b657004220420' | xxd -r -p; base64 -d < $KEY; } | openssl pkey -inform DER -pubout -outform DER | tail -c 32 | base64)
[ "$PUB_PLIST" = "$PUB_KEY" ] || { echo "update key ($PUB_KEY) is not SUPublicEDKey ($PUB_PLIST)"; exit 1; }

WORK=$(mktemp -d); trap 'rm -rf $WORK' EXIT
mkdir $WORK/feed
gh release download "$TAG" -R $REPO -p 'NotchPeek-*.zip' -D $WORK/feed
ZIP=$(ls $WORK/feed/*.zip | head -1)
ditto -x -k "$ZIP" $WORK/check
/usr/sbin/spctl -a -t exec -vv $WORK/check/NotchPeek.app   # must be Developer ID + notarized
$T/generate_appcast --ed-key-file $KEY --download-url-prefix "https://github.com/$REPO/releases/download/$TAG/" -o $WORK/appcast.xml $WORK/feed
sig=$(sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' $WORK/appcast.xml | head -1)
$T/sign_update --verify --ed-key-file $KEY "$ZIP" "$sig"
gh release upload "$TAG" $WORK/appcast.xml -R $REPO --clobber
echo "appcast for $TAG uploaded; feed: https://github.com/$REPO/releases/latest/download/appcast.xml"
