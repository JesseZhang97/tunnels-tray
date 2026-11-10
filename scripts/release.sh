#!/usr/bin/env bash
# Build a universal, ad-hoc signed Tunnels.app and package it for a release:
#   dist/Tunnels-<version>.dmg, dist/Tunnels-<version>.zip, dist/SHA256SUMS.txt
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Support/Info.plist)"
./scripts/bundle.sh --universal

rm -rf dist
mkdir -p dist/dmg
cp -R build/Tunnels.app dist/dmg/
ln -s /Applications dist/dmg/Applications
hdiutil create -volname "Tunnels $VERSION" -srcfolder dist/dmg -ov -format UDZO "dist/Tunnels-$VERSION.dmg"
rm -rf dist/dmg

ditto -c -k --norsrc --noextattr --noacl --keepParent build/Tunnels.app "dist/Tunnels-$VERSION.zip"

(cd dist && shasum -a 256 "Tunnels-$VERSION.dmg" "Tunnels-$VERSION.zip" > SHA256SUMS.txt)
echo
cat dist/SHA256SUMS.txt
ls -l dist
