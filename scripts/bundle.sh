#!/usr/bin/env bash
# Build Tunnels in release mode and assemble build/Tunnels.app (ad-hoc signed).
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product Tunnels
BIN_DIR="$(swift build -c release --show-bin-path)"

APP="build/Tunnels.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Tunnels" "$APP/Contents/MacOS/Tunnels"
cp Support/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"

echo "Built $(pwd)/$APP"
